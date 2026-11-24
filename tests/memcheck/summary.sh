#!/bin/sh
# summary.sh LOGDIR: prints the valgrind logs of LOGDIR that report errors
# and fails when there is one. A log of a process that ended cleanly is
# empty with `-q`.
status=0
for f in "$1"/*.log; do
    [ -s "$f" ] || continue
    echo "::group::$(basename "$f")"
    cat "$f"
    echo "::endgroup::"
    status=1
done
if [ "$status" = 0 ]; then echo "no errors reported"; fi
exit "$status"
