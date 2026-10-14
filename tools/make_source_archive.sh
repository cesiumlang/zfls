#!/usr/bin/env bash
# Writes zfls-v<version>-src.tar.gz for the checked-out tree, submodules
# included (GitHub's own source archives leave vendor/rstd out), into the
# directory given (default: dist). The conda-forge recipe builds from it.
# Needs GNU tar. The archive is reproducible: same tree, same bytes.
set -euo pipefail

out=${1:-dist}
cd "$(dirname "$0")/.."
version=$(sed -nE 's/^\s*\.version = "([^"]+)",/\1/p' build.zig.zon)
name="zfls-v$version-src"
mkdir -p "$out"
# the working tree's files, so a version set in build.zig.zon for this build
# is the one archived
git ls-files -z --recurse-submodules \
    | tar --null --files-from=- --transform "s,^,$name/," \
        --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime="@$(git log -1 --format=%ct)" --format=gnu -cf - \
    | gzip -9n > "$out/$name.tar.gz"
echo "$out/$name.tar.gz"
