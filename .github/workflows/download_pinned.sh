#!/bin/sh
# download_pinned.sh URL SHA256 DEST: downloads URL (https only) to DEST and
# stops unless its SHA-256 is the given one; for the tools CI installs from
# a release, which are pinned by version and checksum.
set -eu
[ $# -eq 3 ] || { echo "usage: download_pinned.sh URL SHA256 DEST" >&2; exit 2; }
url=$1
want=$2
dest=$3
case "$url" in https://*) ;; *) echo "download_pinned.sh: not an https URL: $url" >&2; exit 1 ;; esac
mkdir -p "$(dirname "$dest")"
curl -fsSL --proto =https --tlsv1.2 --retry 5 -o "$dest" "$url"
if command -v sha256sum >/dev/null 2>&1; then
    # from stdin: sha256sum writes a name with backslashes (Windows) with a \ before the sum
    got=$(sha256sum < "$dest" | cut -d ' ' -f 1)
else
    got=$(shasum -a 256 < "$dest" | cut -d ' ' -f 1)
fi
if [ "$got" != "$want" ]; then
    rm -f "$dest"
    echo "download_pinned.sh: $url has SHA-256 $got, not $want" >&2
    exit 1
fi
chmod +x "$dest"
