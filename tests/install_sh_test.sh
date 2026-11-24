#!/bin/sh
# Tests packaging/install.sh against a fake release: curl and uname are
# replaced on the PATH, so nothing is downloaded. Its failure paths (no
# SHA256SUMS, a checksum that does not match or is not listed, no tool to
# compute it, a URL that is not https) must stop before anything is
# unpacked. Run: sh tests/install_sh_test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script=${INSTALL_SH:-$here/../packaging/install.sh}
work=$(mktemp -d 2>/dev/null || mktemp -d -t zfls-install-test)
trap 'rm -rf "$work"' EXIT
fail=0

name=zfls-v9.9.9-x86_64-linux
mkdir -p "$work/rel/$name" "$work/shims" "$work/bare"
printf '#!/bin/sh\necho zfls 9.9.9\n' > "$work/rel/$name/zfls"
chmod +x "$work/rel/$name/zfls"
(cd "$work/rel" && tar -czf "$name.tar.gz" "$name")
if command -v sha256sum >/dev/null 2>&1; then
    good=$(sha256sum "$work/rel/$name.tar.gz" | cut -d ' ' -f 1)
else
    good=$(shasum -a 256 "$work/rel/$name.tar.gz" | cut -d ' ' -f 1)
fi

# serves $SERVE/<file name of the URL>, and refuses what install.sh must not ask for
cat > "$work/shims/curl" <<'SHIM'
#!/bin/sh
url= out= proto=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        --proto) proto=$2; shift ;;
        https://*) url=$1 ;;
        http://*) echo "curl shim: not https: $1" >&2; exit 1 ;;
    esac
    shift
done
echo "${proto:-none}" >> "$SERVE/../protos"
f=$SERVE/${url##*/}
[ -f "$f" ] || exit 22
cp "$f" "$out"
SHIM
printf '#!/bin/sh\n[ "$1" = -m ] && echo x86_64 || echo Linux\n' > "$work/shims/uname"
chmod +x "$work/shims/curl" "$work/shims/uname"

# a PATH with what install.sh needs but no checksum tool
for t in sh tar awk sed cat cut head mktemp rm mkdir dirname tr date cp gzip; do
    p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" > "$work/bare/$t" && chmod +x "$work/bare/$t"
done
cp "$work/shims/curl" "$work/shims/uname" "$work/bare/"

serve() {
    rm -rf "$work/serve"
    mkdir -p "$work/serve"
    cp "$work/rel/$name.tar.gz" "$work/serve/"
}

# check TITLE EXPECT PATH [args]: install.sh with the fake release; EXPECT is ok or fail
check() {
    title=$1 expect=$2 path=$3
    shift 3
    rm -rf "$work/dest"
    if env PATH="$path" SERVE="$work/serve" /bin/sh "$script" --dir "$work/dest" --version 9.9.9 "$@" > "$work/out" 2>&1; then got=ok; else got=fail; fi
    if [ "$got" != "$expect" ]; then
        echo "FAIL $title: expected $expect, got $got"
        cat "$work/out"
        fail=1
    elif [ "$expect" = fail ] && [ -e "$work/dest/$name" ]; then
        echo "FAIL $title: failed but unpacked the archive"
        fail=1
    else
        echo "ok   $title"
    fi
}

with_shims="$work/shims:$PATH"

serve
printf '%s  %s.tar.gz\n' "$good" "$name" > "$work/serve/SHA256SUMS"
check "a matching checksum installs" ok "$with_shims"

check "no checksum tool" fail "$work/bare"

serve
check "no SHA256SUMS" fail "$with_shims"

printf '%s  %s.tar.gz\n' "$(printf '%064d' 0)" "$name" > "$work/serve/SHA256SUMS"
check "a checksum that does not match" fail "$with_shims"

printf '%s  other.tar.gz\n' "$good" > "$work/serve/SHA256SUMS"
check "an archive that is not listed" fail "$with_shims"

# every download asked for https only
if [ -s "$work/protos" ] && ! grep -qv '^=https$' "$work/protos"; then
    echo "ok   every download is limited to https"
else
    echo "FAIL a download was not limited to https:"
    cat "$work/protos"
    fail=1
fi

exit "$fail"
