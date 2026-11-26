#!/bin/sh
# Profiles the server on one workspace through the benchmark driver, one
# scenario at a time, so the hot spots of a phase show by comparing runs.
#   run.sh perf|callgrind|sample WORKSPACE OUT_DIR [SCALE]
# SCALE (default 1) multiplies the request, edit and save counts. perf,
# callgrind and sample (macOS) are the tools. Needs
# zig-out/bin/bench_workspace and zig-out/bin/zfls built with -Dprofile=true.
tool="$1"
ws="$2"
out="$3"
scale="${4:-1}"
here="$(cd "$(dirname "$0")" && pwd)"
export ZFLS_REAL="$PWD/zig-out/bin/zfls"
export PROFILE_OUT
mkdir -p "$out"
run() {
    name="$1"
    shift
    PROFILE_OUT="$out/$name"
    mkdir -p "$PROFILE_OUT"
    echo "::group::$name"
    "$PWD/zig-out/bin/bench_workspace" "$ws" --zfls "$here/zfls-$tool.sh" --timeout 6000 "$@" \
        | tee "$PROFILE_OUT/bench.txt"
    echo "::endgroup::"
}
# each run is two server processes, the first on a cold index and the
# second from the index cache the first wrote
run init --requests 0 --edits 0 --saves 0
run requests --requests $((60 * scale)) --edits 0 --saves 0
run edits --requests 0 --edits $((15 * scale)) --saves 0
run saves --requests 0 --edits 0 --saves $((5 * scale))
