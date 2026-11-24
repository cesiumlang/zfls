#!/bin/sh
# Starts zfls under valgrind, for the drivers that take a server command
# (`--zfls tests/memcheck/zfls-valgrind.sh`): .github/workflows/memcheck.yml.
# ZFLS_REAL is the server, MEMCHECK_LOGS the directory of the logs (one file
# per process), MEMCHECK_TOOL memcheck (the default), helgrind or drd.
tool="${MEMCHECK_TOOL:-memcheck}"
here="$(cd "$(dirname "$0")" && pwd)"
exec valgrind --tool="$tool" -q --error-exitcode=99 \
    --suppressions="$here/zfls.supp" \
    --log-file="${MEMCHECK_LOGS:-.}/$tool-%p.log" \
    --max-stackframe=268435456 --num-callers=40 \
    "$ZFLS_REAL" "$@"
