#!/bin/sh
# Starts zfls under callgrind (instruction counts, deterministic), for the
# benchmark driver: .github/workflows/profile.yml. ZFLS_REAL is the server,
# PROFILE_OUT the directory of the profiles (one file per process).
exec valgrind --tool=callgrind -q --max-stackframe=268435456 \
    --callgrind-out-file="${PROFILE_OUT:-.}/callgrind-$(date +%s%N)-$$.out" \
    "$ZFLS_REAL" "$@"
