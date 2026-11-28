#!/usr/bin/env bash
# Writes the documentation site's icons from the logo (logo.svg) into
# site/assets/: favicon.ico (16, 32 and 48 pixels), icon-192.png and
# apple-touch-icon.png (180). They are generated: change the logo and run
# this again, never edit them. From skein's tools/favicon.sh.
#
#   tools/favicon.sh
#
# Needs ImageMagick 7 (`magick`). Run from the repository's root.
set -euo pipefail

logo=logo.svg
render() { magick -background none -density 1200 "$logo" -resize "$1x$1" -depth 8 "$2"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for n in 16 32 48; do render "$n" "$tmp/$n.png"; done
magick "$tmp/16.png" "$tmp/32.png" "$tmp/48.png" site/assets/favicon.ico
render 192 site/assets/icon-192.png
# iOS shows no transparency: the logo on the site's light background
magick -background "#fbfafc" -density 1200 "$logo" -resize 180x180 -flatten -depth 8 site/assets/apple-touch-icon.png
echo "site/assets/: favicon.ico, icon-192.png, apple-touch-icon.png from $logo"
