#!/bin/sh
# Installs a zfls release on macOS, Linux or Windows (in Git Bash, MSYS2 or
# Cygwin; install.ps1 does the same in PowerShell): downloads the release
# archive for this computer from GitHub, checks it against the release's SHA256SUMS
# (and SHA256SUMS against its GPG signature with gpg, or the archive's build
# attestation with gh, when either is installed) and unpacks it, by default into the current directory (a portable install:
# nothing is written anywhere else).
#
#   curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh -s -- --dir ~/tools --version 0.4.0
#
# On macOS, a release archive downloaded in a web browser is quarantined, and
# Finder warns when the zfls unpacked from it by Archive Utility is
# double-clicked, as for any downloaded command-line program (run it from a
# terminal instead). Files downloaded with curl or wget are not quarantined
# (nor, on Windows, marked as downloaded from the internet).

set -eu

repo=cesiumlang/zfls
# the release signing key (SIGNING-KEY.asc in the repository) and its fingerprint
key_url=https://raw.githubusercontent.com/$repo/main/SIGNING-KEY.asc
key_fpr=9431367798CCD8E28BC0E589BB30DEF734E5F690

usage() {
    cat <<EOF
Usage: install.sh [--dir DIR] [--version VERSION]

Downloads the zfls release for this computer and unpacks it into DIR, as
DIR/zfls-v<version>-<target>/zfls (zfls.exe on Windows).

  -d, --dir DIR          where to unpack the release (default: the current
                         directory)
  -v, --version VERSION  the release to install, such as 0.4.0 (default: the
                         latest)
  -h, --help             show this help
EOF
}

die() {
    echo "install.sh: $*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# download URL FILE: over https only, also across redirects
download() {
    case "$1" in https://*) ;; *) die "not an https URL: $1" ;; esac
    if have curl; then
        curl -fsSL --proto =https --proto-redir =https --tlsv1.2 --retry 3 -o "$2" "$1"
    elif have wget; then
        # busybox's wget has no option to stay on https; its URLs are https
        if wget --help 2>&1 | grep -q -- --https-only; then
            wget -q --https-only --secure-protocol=TLSv1_2 -O "$2" "$1"
        else
            wget -q -O "$2" "$1"
        fi
    else
        die "needs curl or wget"
    fi
}

# The version of the latest release that has an archive for TARGET, without
# the leading v. It is read from the names in the release's SHA256SUMS,
# which releases/latest/download/ serves without GitHub's API and its rate
# limit (60 requests an hour from one address, which CI runners share).
latest_version() {
    download "https://github.com/$repo/releases/latest/download/SHA256SUMS" "$tmp/latest" ||
        die "cannot reach github.com"
    v=$(sed -n "s/.*zfls-v\(.*\)-$1\..*/\1/p" "$tmp/latest" | head -n 1)
    [ -n "$v" ] || die "the latest release of $repo has no archive for $1"
    echo "$v"
}

# The release target of this computer, such as aarch64-macos
detect_target() {
    case "$(uname -s)" in
        Darwin) os=macos ;;
        Linux) os=linux ;;
        MINGW* | MSYS* | CYGWIN*) os=windows ;;
        *) die "there is no zfls release for $(uname -s); build it from source (see https://github.com/$repo#building)" ;;
    esac
    case "$(uname -m)" in
        arm64 | aarch64) arch=aarch64 ;;
        x86_64 | amd64) arch=x86_64 ;;
        *) die "there is no zfls release for $(uname -m); build it from source (see https://github.com/$repo#building)" ;;
    esac
    # A shell under Rosetta 2 reports x86_64 on an Arm Mac. (On Windows on
    # Arm, an x86_64 shell gets the x86_64 zfls, which runs there too.)
    if [ "$os" = macos ] && [ "$arch" = x86_64 ] &&
        [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
        arch=aarch64
    fi
    echo "$arch-$os"
}

# unpack ARCHIVE DIR
unpack() {
    case "$1" in
        *.tar.gz) tar -xzf "$1" -C "$2" ;;
        *.zip)
            if have unzip; then
                unzip -q -o "$1" -d "$2"
            elif have cygpath && [ -x "$(cygpath -u "${SYSTEMROOT:-C:/Windows}")/System32/tar.exe" ]; then
                # Windows's own tar (bsdtar) reads zip archives
                "$(cygpath -u "${SYSTEMROOT:-C:/Windows}")/System32/tar.exe" -xf "$(cygpath -w "$1")" -C "$(cygpath -w "$2")"
            else
                die "needs unzip to unpack $1"
            fi
            ;;
    esac
}

# sha256 FILE: the SHA-256 of FILE, in hex
sha256() {
    if have sha256sum; then
        sha256sum "$1" | cut -d ' ' -f 1
    elif have shasum; then
        shasum -a 256 "$1" | cut -d ' ' -f 1
    else
        return 1
    fi
}

# Checks SHA256SUMS against its signature with the release key (gpg), else
# the archive's build attestation (an authenticated gh); stops on a failure.
# Releases before 0.5.0 have neither.
verify_release() {
    case "$version" in
        0.[0-4].*)
            echo "Note: v$version is older than 0.5.0 and not signed; only its SHA-256 was checked"
            return 0
            ;;
    esac
    if have gpg; then
        download "$base/SHA256SUMS.asc" "$tmp/SHA256SUMS.asc" ||
            die "cannot download $base/SHA256SUMS.asc; the release is not verified, so it is not installed"
        download "$key_url" "$tmp/key.asc" || die "cannot download the release signing key $key_url"
        # a keyring of its own: the user's is not touched
        GNUPGHOME="$tmp/gnupg"
        export GNUPGHOME
        mkdir "$GNUPGHOME" && chmod 700 "$GNUPGHOME" 2>/dev/null || true
        gpg --batch --quiet --import "$tmp/key.asc" >/dev/null 2>&1 || die "cannot import the release signing key"
        gpg --batch --status-fd 1 --verify "$tmp/SHA256SUMS.asc" "$tmp/SHA256SUMS" > "$tmp/gpg.status" 2>/dev/null ||
            die "SHA256SUMS of v$version does not match its signature"
        grep -q "^\[GNUPG:\] VALIDSIG .*$key_fpr" "$tmp/gpg.status" ||
            die "SHA256SUMS of v$version is not signed by the release key ($key_fpr)"
        echo "Verified the signature of SHA256SUMS (release key $key_fpr)"
    elif have gh && gh auth status >/dev/null 2>&1; then
        gh attestation verify "$tmp/$archive" --repo "$repo" >/dev/null 2>&1 ||
            die "$archive has no valid build attestation of $repo"
        echo "Verified the build attestation of $archive"
    else
        echo "Note: neither gpg nor a signed-in gh is installed, so only the SHA-256 was checked, not the release's signature or attestation"
    fi
}

main() {
    dir=.
    version=
    while [ $# -gt 0 ]; do
        case "$1" in
            -d | --dir)
                [ $# -ge 2 ] || die "$1 needs a directory"
                dir=$2
                shift 2
                ;;
            --dir=*)
                dir=${1#*=}
                shift
                ;;
            -v | --version)
                [ $# -ge 2 ] || die "$1 needs a version"
                version=$2
                shift 2
                ;;
            --version=*)
                version=${1#*=}
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
    done

    tmp=$(mktemp -d 2>/dev/null || mktemp -d -t zfls)
    trap 'rm -rf "$tmp"' EXIT

    target=$(detect_target)
    [ -n "$version" ] || version=$(latest_version "$target")
    version=${version#v}
    name="zfls-v$version-$target"
    case "$target" in
        *windows) archive="$name.zip" exe=zfls.exe ;;
        *) archive="$name.tar.gz" exe=zfls ;;
    esac
    base="https://github.com/$repo/releases/download/v$version"

    echo "Downloading $archive"
    download "$base/$archive" "$tmp/$archive" ||
        die "cannot download $base/$archive (is $version a release of zfls?)"

    # an archive that cannot be verified is not unpacked
    download "$base/SHA256SUMS" "$tmp/SHA256SUMS" ||
        die "cannot download $base/SHA256SUMS; the archive is not verified, so it is not installed"
    expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || die "SHA256SUMS of v$version does not list $archive"
    actual=$(sha256 "$tmp/$archive") ||
        die "needs sha256sum or shasum to verify $archive"
    [ "$actual" = "$expected" ] || die "$archive does not match its SHA-256 in SHA256SUMS"
    verify_release

    mkdir -p "$dir"
    unpack "$tmp/$archive" "$dir"
    install_dir=$(cd "$dir/$name" && pwd)
    "$install_dir/$exe" --version >/dev/null 2>&1 ||
        die "$install_dir/$exe was unpacked but does not run"

    echo "Installed zfls $version in $install_dir"
    echo "To run it as zfls, add that directory to your PATH, for example:"
    echo "  export PATH=\"$install_dir:\$PATH\""
}

# Everything is in functions, so a download cut short runs nothing
main "$@"
