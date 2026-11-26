#!/bin/sh
# Tests packaging/install.sh against a fake release: curl and uname are
# replaced on the PATH, so nothing is downloaded. Its failure paths (no
# SHA256SUMS, a checksum that does not match or is not listed, no tool to
# compute it, a URL that is not https, a signature that does not verify or
# is missing) must stop before anything is unpacked; gpg is a shim too.
# Run: sh tests/install_sh_test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script=${INSTALL_SH:-$here/../packaging/install.sh}
work=$(mktemp -d 2>/dev/null || mktemp -d -t zfls-install-test)
trap 'rm -rf "$work"' EXIT
fail=0

name=zfls-v9.9.9-x86_64-linux
old=zfls-v0.4.9-x86_64-linux
mkdir -p "$work/shims" "$work/bare" "$work/nogpg"
for n in "$name" "$old"; do
    mkdir -p "$work/rel/$n"
    printf '#!/bin/sh\necho zfls\n' > "$work/rel/$n/zfls"
    chmod +x "$work/rel/$n/zfls"
    (cd "$work/rel" && tar -czf "$n.tar.gz" "$n")
done
sum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}
good=$(sum "$work/rel/$name.tar.gz")
fpr=9431367798CCD8E28BC0E589BB30DEF734E5F690

# gpg: imports anything; GPG_MODE good, bad or other says what --verify finds
cat > "$work/shims/gpg" <<'SHIM'
#!/bin/sh
for a in "$@"; do [ "$a" = --import ] && exit 0; done
case "${GPG_MODE:-good}" in
    good) echo "[GNUPG:] VALIDSIG $FPR 2026-11-25 0 4 0 22 8 00 $FPR" ;;
    other) echo "[GNUPG:] VALIDSIG 0000000000000000000000000000000000000000 2026-11-25 0 4 0 22 8 00 0000000000000000000000000000000000000000" ;;
    *) echo "[GNUPG:] BADSIG x"; exit 1 ;;
esac
SHIM

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
chmod +x "$work/shims/curl" "$work/shims/uname" "$work/shims/gpg"

# a PATH with what install.sh needs but no checksum tool
for t in sh tar awk sed cat cut head mktemp rm mkdir dirname tr date cp gzip; do
    p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" > "$work/bare/$t" && chmod +x "$work/bare/$t"
done
cp "$work/shims/curl" "$work/shims/uname" "$work/bare/"
# and with a checksum tool, but neither gpg nor gh
cp "$work/bare/"* "$work/nogpg/"
for t in sha256sum shasum; do
    p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" > "$work/nogpg/$t" && chmod +x "$work/nogpg/$t"
done

serve() {
    rm -rf "$work/serve"
    mkdir -p "$work/serve"
    cp "$work/rel/$name.tar.gz" "$work/rel/$old.tar.gz" "$work/serve/"
    echo key > "$work/serve/SIGNING-KEY.asc"
    echo sig > "$work/serve/SHA256SUMS.asc"
}

# check TITLE EXPECT PATH [args]: install.sh with the fake release; EXPECT is ok or fail;
# $mode is gpg's answer and $version the release (set them as statements:
# an assignment before a function call stays set after it in some shells)
check() {
    title=$1 expect=$2 path=$3
    shift 3
    rm -rf "$work/dest"
    if env PATH="$path" SERVE="$work/serve" FPR="$fpr" GPG_MODE="${mode:-good}" /bin/sh "$script" --dir "$work/dest" --version "${version:-9.9.9}" "$@" > "$work/out" 2>&1; then got=ok; else got=fail; fi
    if [ "$got" != "$expect" ]; then
        echo "FAIL $title: expected $expect, got $got"
        cat "$work/out"
        fail=1
    elif [ "$expect" = fail ] && [ -n "$(ls "$work/dest" 2>/dev/null)" ]; then
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

serve
printf '%s  %s.tar.gz\n' "$good" "$name" > "$work/serve/SHA256SUMS"
mode=bad
check "a signature that does not verify" fail "$with_shims"
grep -q "does not match its signature" "$work/out" || { echo "FAIL a bad signature: wrong reason"; cat "$work/out"; fail=1; }
mode=other
check "a signature by another key" fail "$with_shims"
grep -q "is not signed by the release key" "$work/out" || { echo "FAIL another key: wrong reason"; cat "$work/out"; fail=1; }
mode=good
check "a signed release, checked with gpg" ok "$with_shims"
if grep -q "Verified the signature of SHA256SUMS" "$work/out"; then echo "ok   it says the signature was checked"; else echo "FAIL no word of the signature"; cat "$work/out"; fail=1; fi
check "neither gpg nor gh: only the checksum" ok "$work/nogpg"
if grep -q "only the SHA-256 was checked" "$work/out"; then echo "ok   it says only the checksum was checked"; else echo "FAIL no note without gpg"; cat "$work/out"; fail=1; fi
rm "$work/serve/SHA256SUMS.asc"
check "a release of 0.5.0 on without SHA256SUMS.asc" fail "$with_shims"
printf '%s  %s.tar.gz\n' "$(sum "$work/rel/$old.tar.gz")" "$old" > "$work/serve/SHA256SUMS"
version=0.4.9
check "a release before 0.5.0, which has no signature" ok "$with_shims"
version=

# every download asked for https only
if [ -s "$work/protos" ] && ! grep -qv '^=https$' "$work/protos"; then
    echo "ok   every download is limited to https"
else
    echo "FAIL a download was not limited to https:"
    cat "$work/protos"
    fail=1
fi

exit "$fail"
