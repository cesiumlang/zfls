#!/bin/sh
# summary.sh LOGDIR: prints the valgrind logs of LOGDIR that report errors
# and fails when there is one. A log of a process that ended cleanly is
# empty with `-q`, but for the warnings of valgrind's reader of the debug
# information Zig writes (they are not about the program).
status=0
noise='DWARF2 reader|Can.t handle line info entry|this message is only shown once'
for f in "$1"/*.log; do
    [ -e "$f" ] || continue
    if ! grep -vqE "$noise" "$f"; then continue; fi
    echo "::group::$(basename "$f")"
    grep -vE "$noise" "$f"
    echo "::endgroup::"
    status=1
done
if [ "$status" = 0 ]; then echo "no errors reported"; fi
exit "$status"
