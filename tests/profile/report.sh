#!/bin/sh
# Text reports of the recordings under DIR: perf report (exclusive and
# inclusive), folded stacks, callgrind_annotate (exclusive and inclusive).
#   report.sh DIR
find "$1" -name 'perf-*.data' | while read -r f; do
    b="${f%.data}"
    perf report -i "$f" --stdio --no-children --percent-limit 0.3 -g none > "$b.excl.txt" 2>/dev/null
    perf report -i "$f" --stdio --children --percent-limit 0.5 -g none > "$b.incl.txt" 2>/dev/null
    perf script -i "$f" -F ip,sym 2>/dev/null | awk '
        /^$/ { if (n) { s = ""; for (i = n; i >= 1; i--) s = s (s == "" ? "" : ";") st[i]; c[s]++ } n = 0; next }
        { n++; st[n] = $2 }
        END { for (s in c) print s, c[s] }' | sort -k2 -n -r -t' ' > "$b.folded.txt"
done
find "$1" -name 'callgrind-*.out' | while read -r f; do
    b="${f%.out}"
    callgrind_annotate "$f" > "$b.excl.txt" 2>/dev/null
    callgrind_annotate --inclusive=yes "$f" > "$b.incl.txt" 2>/dev/null
done
