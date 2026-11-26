#!/bin/sh
# Starts zfls under perf record, for the benchmark driver
# (`--zfls tests/profile/zfls-perf.sh`): .github/workflows/profile.yml.
# ZFLS_REAL is the server, PROFILE_OUT the directory of the recordings (one
# file per process, named by start time), PROFILE_FREQ the sampling rate.
exec perf record -q -F "${PROFILE_FREQ:-999}" -g \
    -o "${PROFILE_OUT:-.}/perf-$(date +%s%N)-$$.data" "$ZFLS_REAL" "$@"
