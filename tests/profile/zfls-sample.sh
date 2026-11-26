#!/bin/sh
# Starts zfls under macOS's `sample` (no root needed), for the benchmark
# driver (`--zfls tests/profile/zfls-sample.sh`). ZFLS_REAL is the server,
# PROFILE_OUT the directory of the samples (one file per process),
# PROFILE_MS the sampling interval, PROFILE_SECONDS the longest sample.
out="${PROFILE_OUT:-.}/sample-$(date +%s)-$$.txt"
"$ZFLS_REAL" "$@" <&0 &
pid=$!
sample "$pid" "${PROFILE_SECONDS:-3000}" "${PROFILE_MS:-5}" -mayDie -file "$out" > /dev/null 2>&1 &
sampler=$!
wait "$pid"
status=$?
wait "$sampler"
exit "$status"
