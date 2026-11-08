#!/bin/sh
# Installs a zfls release on macOS, Linux or Windows (in Git Bash, MSYS2 or
# Cygwin; install.ps1 does the same in PowerShell): downloads the release
# archive for this computer from GitHub, checks it against the release's SHA256SUMS
# and unpacks it, by default into the current directory (a portable install:
# nothing is written anywhere else).
#
#   curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh -s -- --dir ~/tools --version 0.4.0
#
# On macOS, a release archive downloaded in a web browser is quarantined,
# and Gatekeeper refuses to run the zfls unpacked from it, since the binary
# is not notarized. Files downloaded with curl or wget are not quarantined
# (nor, on Windows, marked as downloaded from the internet).

set -eu

repo=cesiumlang/zfls

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

# download URL FILE
download() {
    if have curl; then
        curl -fsSL --retry 3 -o "$2" "$1"
    elif have wget; then
        wget -q -O "$2" "$1"
    else
        die "needs curl or wget"
    fi
}

# The version of the latest release, without the leading v
latest_version() {
    if have curl; then
        # releases/latest redirects to releases/tag/v<version>
        url=$(curl -fsSLI --retry 3 -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
            die "cannot reach github.com"
        tag=${url##*/}
    else
        download "https://api.github.com/repos/$repo/releases/latest" "$tmp/latest.json" ||
            die "cannot reach api.github.com"
        tag=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$tmp/latest.json" | head -n 1)
    fi
    case "$tag" in
        v[0-9]*) echo "${tag#v}" ;;
        *) die "cannot find the latest release of $repo" ;;
    esac
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
    [ -n "$version" ] || version=$(latest_version)
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

    if download "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null; then
        expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
        [ -n "$expected" ] || die "SHA256SUMS of v$version does not list $archive"
        if actual=$(sha256 "$tmp/$archive"); then
            [ "$actual" = "$expected" ] || die "$archive does not match its SHA-256 in SHA256SUMS"
        else
            echo "warning: neither sha256sum nor shasum found; the archive is not verified" >&2
        fi
    else
        echo "warning: v$version has no SHA256SUMS; the archive is not verified" >&2
    fi

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
