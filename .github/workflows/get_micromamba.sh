#!/bin/sh
# get_micromamba.sh PLATFORM DIR: the pinned micromamba release for PLATFORM
# (linux-64, osx-64 or win-64), checked against its SHA-256, as
# DIR/bin/micromamba (DIR/Library/bin/micromamba.exe on Windows, where the
# conda package puts it). Releases: https://github.com/mamba-org/micromamba-releases
set -eu
[ $# -eq 2 ] || { echo "usage: get_micromamba.sh PLATFORM DIR" >&2; exit 2; }
version=2.10.0-0
dir=$2
here=$(dirname "$0")
case "$1" in
    linux-64) asset=micromamba-linux-64 dest=$dir/bin/micromamba sha=701f39c06f8e6a670a0e186c8479b9e5c0502a2f0cda6cef65d83bdd2875e8bd ;;
    osx-64) asset=micromamba-osx-64 dest=$dir/bin/micromamba sha=8421462a1ef1df9f7acd114f9e2a24c1332ce4f4e29f44465b4acb44e2755172 ;;
    win-64) asset=micromamba-win-64.exe dest=$dir/Library/bin/micromamba.exe sha=f8b4284bd4eb1134122eaf93b3ea6c7be567e596de5829e1a6f478e34e41974a ;;
    *) echo "get_micromamba.sh: no micromamba for $1" >&2; exit 2 ;;
esac
sh "$here/download_pinned.sh" "https://github.com/mamba-org/micromamba-releases/releases/download/$version/$asset" "$sha" "$dest"
