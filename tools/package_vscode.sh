#!/usr/bin/env bash
# Packages the VS Code extension (editors/vscode) once per VS Code platform,
# each with the matching zfls release binary in bin/, plus a universal VSIX
# without one (it runs zfls.path or zfls from the PATH):
#
#     tools/package_vscode.sh DIST VERSION
#
# DIST holds the release archives (zfls-v<VERSION>-<target>.tar.gz/.zip);
# the VSIX files are written there too, as zfls-vscode-v<VERSION>-<platform>.vsix.
set -euo pipefail

dist=$(cd "$1" && pwd)
version=$2
ext="$(cd "$(dirname "$0")/.." && pwd)/editors/vscode"

# VS Code platform -> zfls release target (the Linux binaries are static, so
# they also run on Alpine)
targets=(
    "win32-x64 x86_64-windows"
    "win32-arm64 aarch64-windows"
    "linux-x64 x86_64-linux"
    "linux-arm64 aarch64-linux"
    "alpine-x64 x86_64-linux"
    "alpine-arm64 aarch64-linux"
    "darwin-x64 x86_64-macos"
    "darwin-arm64 aarch64-macos"
)

cd "$ext"
npm ci --no-audit --no-fund
npm run build
tmp=$(mktemp -d)
# the version is set for packaging only
cp package.json "$tmp/package.json"
trap 'cp "$tmp/package.json" package.json; rm -rf "$tmp" bin' EXIT
npm pkg set version="$version"
cp ../../LICENSE LICENSE

for pair in "${targets[@]}"; do
    read -r platform target <<< "$pair"
    name="zfls-v$version-$target"
    rm -rf bin "$tmp/$name"
    mkdir -p bin
    case "$target" in
        *windows)
            unzip -q "$dist/$name.zip" -d "$tmp"
            cp "$tmp/$name/zfls.exe" bin/
            ;;
        *)
            tar -xzf "$dist/$name.tar.gz" -C "$tmp"
            cp "$tmp/$name/zfls" bin/
            chmod +x bin/zfls
            ;;
    esac
    npx vsce package --no-dependencies --target "$platform" \
        --out "$dist/zfls-vscode-v$version-$platform.vsix"
done

rm -rf bin
npx vsce package --no-dependencies --out "$dist/zfls-vscode-v$version-universal.vsix"
ls -l "$dist"/*.vsix
