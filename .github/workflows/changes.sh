# shellcheck shell=bash
# Which changed files can change the shipped binaries. Sourced (in bash,
# from the repository root) by ci.yml's "Version" job, which decides
# whether a push to main makes a release, and by its "Version is
# unreleased" job, which decides whether a pull request to main needs a new
# version: so that both decide alike.

# patterns LIST...: the globs of the lists (one bash `case` glob per line;
# lines starting with # and blank lines are ignored)
patterns() { cat "$@" | grep -v '^\s*#' | grep -v '^\s*$'; }

# matches FILE GLOB...: whether FILE matches one of the globs
matches() {
    local f=$1 pat
    shift
    for pat in "$@"; do
        # shellcheck disable=SC2254
        case "$f" in $pat) return 0 ;; esac
    done
    return 1
}

# The files whose changes alone skip CI, and the files that cannot change
# the shipped binaries (no_ci is used where this is sourced)
# shellcheck disable=SC2034
mapfile -t no_ci < <(patterns .github/workflows/no-ci.txt)
mapfile -t exempt < <(patterns .github/workflows/no-ci.txt .github/workflows/ci-only.txt)

# keeps_binaries FILE REV: whether the change to FILE from REV to HEAD
# leaves the shipped binaries as they were. It does when FILE is listed in
# no-ci.txt or ci-only.txt, when FILE is again as it was at REV (changed and
# changed back, such as a version set back), and when FILE is Zig source in
# which only whole-line comments and blank lines changed.
keeps_binaries() {
    local f=$1 rev=$2
    matches "$f" "${exempt[@]}" && return 0
    git diff --quiet "$rev" HEAD -- "$f" && return 0
    case "$f" in *.zig) ;; *) return 1 ;; esac
    # the lines added and removed (from the first hunk on, past the file
    # headers): none may be other than blank or a comment
    ! git diff -U0 "$rev" HEAD -- "$f" | sed -n '/^@@/,$p' | grep '^[-+]' |
        grep -qvE '^[-+][[:space:]]*(//.*)?$'
}
