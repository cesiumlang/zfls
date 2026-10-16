# Tests of the open issues of upstream fortls

These tests state, for the open bugs of
[fortran-lang/fortls](https://github.com/fortran-lang/fortls/issues), what a
user would expect, and record whether zfls gets it right. A bug that zfls
still has is not hidden: its test is the oracle for the patch.

Run them with `zig build test-issues` (they are also part of `zig build
test`). Each test builds a small workspace from the fixture in the issue,
starts a `Server` in-process (`harness.zig`) and sends it LSP requests.

A test ends in `h.check(issue, status, result)`:

- `.fixed`: zfls behaves correctly. A failure is a regression.
- `.known_failure`: the bug is still there, so the expectations must fail.
  When a patch makes them pass the test fails until the marker is changed to
  `.fixed`, so the table below does not go stale.

Every run writes what each test found, with the reason a known failure fails,
to `.zig-cache/issue-tests.txt`.

`upstream_check.py` runs the same fixtures through Python fortls (a checkout,
at the commit the issues cite) and through zfls, using their debug command
line options, to check the "fortls" column:

```sh
python tests/issues/upstream_check.py --zfls zig-out/bin/zfls --fortls ../fortls 406
```

## Results

The status of fortls is for its commit `0392beb`. "Same" means both servers
give the same answer, and the test fails for the reason in the issue.

| Issue | Behavior | Test file | zfls | fortls |
| --- | --- | --- | --- | --- |
| [#568](https://github.com/fortran-lang/fortls/issues/568) | plain `USE` after a `USE ONLY` through a re-exporting module | diagnostics | fixed (patched) | fails, same cause |
| [#536](https://github.com/fortran-lang/fortls/issues/536) | config file drops `--pp_defs` | workspace | fixed (patched) | fails, same cause |
| [#536](https://github.com/fortran-lang/fortls/issues/536) | broken symlink under the workspace | workspace | fixed | crashes (per the issue) |
| [#558](https://github.com/fortran-lang/fortls/issues/558) | unreadable directory under a `source_dirs` glob (POSIX only; skipped on Windows and as root) | workspace | fixed | crashes (per the issue) |
| [#532](https://github.com/fortran-lang/fortls/issues/532) | identifiers starting with `block` parse as BLOCK | parsing | fixed (patched) | fails, same cause |
| [#478](https://github.com/fortran-lang/fortls/issues/478) | Markdown list in a parameter's docs indents the next parameter (fixture rebuilt from the screenshot) | hover | fixed (patched) | fails, same cause |
| [#498](https://github.com/fortran-lang/fortls/issues/498) | go to definition on `#include` | hover | fixed (patched) | fails, same cause |
| [#495](https://github.com/fortran-lang/fortls/issues/495) | definition inside a file `#include`d into a module | parsing | fixed (patched) | fails, same cause |
| [#489](https://github.com/fortran-lang/fortls/issues/489) | `!` comment after code held to `max_line_length` | diagnostics | fixed (patched) | fails, same cause |
| [#483](https://github.com/fortran-lang/fortls/issues/483) | hover on an `external` procedure | hover | fixed (patched) | fails, same cause |
| [#470](https://github.com/fortran-lang/fortls/issues/470) | definitions after `BLOCK DATA` | diagnostics | fixed (patched) | fails, same cause |
| [#411](https://github.com/fortran-lang/fortls/issues/411) | `;` in a fixed-form comment | parsing | fixed (patched) | fails, same cause |
| [#406](https://github.com/fortran-lang/fortls/issues/406) | `external` declared in two subroutines | diagnostics | fixed (patched) | fails, same cause |
| [#322](https://github.com/fortran-lang/fortls/issues/322) | rename a function, result variable not renamed | rename | fixed (patched) | fails, same cause |
| [#301](https://github.com/fortran-lang/fortls/issues/301) | `INCLUDE` statement searched in `include_dirs`, go to definition on it | workspace | fixed (patched) | fails, same cause |
| [#292](https://github.com/fortran-lang/fortls/issues/292) | label or variable named `block` | parsing | fixed (patched) | fails, same cause |
| [#237](https://github.com/fortran-lang/fortls/issues/237) | `!>` above an expression documents a later procedure | hover | fixed (patched) | fails, same cause |
| [#203](https://github.com/fortran-lang/fortls/issues/203) | `PARAMETER` statement | hover | fixed (patched) | fails, same cause |
| [#172](https://github.com/fortran-lang/fortls/issues/172) | coarray dummy argument | diagnostics | fixed (patched) | fails, same cause |
| [#124](https://github.com/fortran-lang/fortls/issues/124) | parameter value that is a function call | hover | fixed (patched) | fails, same cause |
| [#118](https://github.com/fortran-lang/fortls/issues/118) | fixed-form function declared with a type in the caller | hover | fixed (patched) | fails, same cause |
| [#108](https://github.com/fortran-lang/fortls/issues/108) | `ASSOCIATE` name bound to an array slice | hover | fixed (patched) | fails, same cause |
| [#87](https://github.com/fortran-lang/fortls/issues/87) | signature help with commas inside an argument | hover | fixed (patched) | fails, same cause |
| [#52](https://github.com/fortran-lang/fortls/issues/52) | rename of a name renamed on import | rename | fixed (patched) | fails, same cause |
| [#23](https://github.com/fortran-lang/fortls/issues/23) | go to implementation from `EXTERNAL` | hover | fixed (patched) | fails, same cause |
| [#565](https://github.com/fortran-lang/fortls/issues/565) | edit a file included by an include file | workspace | fixed | `AttributeError` (as reported; not run here) |
| [#486](https://github.com/fortran-lang/fortls/issues/486) | function-like macro with empty parentheses | parsing | fixed | fails (`re.error: invalid group reference`) |
| [#433](https://github.com/fortran-lang/fortls/issues/433) | `ASSOCIATE` name that refers to itself | parsing | fixed | `RecursionError` |
| [#519](https://github.com/fortran-lang/fortls/issues/519) | `IMPORT` in an abstract interface | diagnostics | fixed | fine (cannot reproduce) |
| [#485](https://github.com/fortran-lang/fortls/issues/485) | private names of a used module | diagnostics | fixed | fine (diagnostics only) |
| [#281](https://github.com/fortran-lang/fortls/issues/281) | docs of a function with a type prefix | hover | fixed | fine |
| [#264](https://github.com/fortran-lang/fortls/issues/264) | `IMPLICIT NONE` in `BLOCKDATA` | diagnostics | fixed | fine |
| [#236](https://github.com/fortran-lang/fortls/issues/236) | continued line into an `#include` | parsing | fixed | fine |
| [#86](https://github.com/fortran-lang/fortls/issues/86) | rename an argument of a function with a continued header | rename | fixed | fine |
| [#72](https://github.com/fortran-lang/fortls/issues/72) | single `TYPE IS` with an associated selector | diagnostics | fixed | fine |

Notes:

- The fixture of #470 is built from its description (the report only has
  screenshots), and the one of #485 checks the diagnostics only.
- Where the table says "same" for #489, fortls reports each warning twice;
  zfls does not (see "Differences from fortls" in the main README).

### Not tested

- [#499](https://github.com/fortran-lang/fortls/issues/499) fails fortls's own
  test suite on Python 3.14; it does not apply to zfls.
- The feature requests and discussions have no behavior to test yet:
  #563, #547, #512, #502, #501, #496, #438, #424, #423, #417, #348, #309,
  #209, #171, #126, #125, #96, #85, #56, #28 and #6.

## Issues of hansec/fortran-language-server

fortls was forked from
[hansec/fortran-language-server](https://github.com/hansec/fortran-language-server);
some of its bugs were never reported again to fortls. Their tests use
`h.checkIn(.hansec, ...)`.

| Issue | Behavior | Test file | zfls | fortls |
| --- | --- | --- | --- | --- |
| [#202](https://github.com/hansec/fortran-language-server/issues/202) | `!` comment inside a continued fixed-form declaration hides the names after it | parsing | fixed (patched) | fails, same cause |
| [#155](https://github.com/hansec/fortran-language-server/issues/155) | `!` comment inside a continued fixed-form `IF` loses its `THEN` | parsing | fixed (patched) | fails, same cause |
| [#200](https://github.com/hansec/fortran-language-server/issues/200) | "masks variable" warning for a variable of a dummy procedure's interface body | diagnostics | fixed (patched) | fails, same cause |
| [#168](https://github.com/hansec/fortran-language-server/issues/168) | references to a separate module procedure miss its implementation in a submodule | hover | fixed (patched) | fails, same cause |
