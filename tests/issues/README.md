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
| [#534](https://github.com/fortran-lang/fortls/issues/534) | fixed-form documentation comments keep the indentation of the code (closed) | hover | fixed | fixed (upstream #535) |
| [#481](https://github.com/fortran-lang/fortls/issues/481) | `#include` path with slashes (closed) | hover | fixed | fixed (upstream #527); no definition on the `#include` (#498) |
| [#532](https://github.com/fortran-lang/fortls/issues/532) | identifiers starting with `block` parse as BLOCK | parsing | fixed (patched) | fails, same cause |
| [#478](https://github.com/fortran-lang/fortls/issues/478) | Markdown list in a parameter's docs indents the next parameter (fixture rebuilt from the screenshot) | hover | fixed (patched) | fails, same cause |
| [#498](https://github.com/fortran-lang/fortls/issues/498) | go to definition on `#include` | hover | fixed (patched) | fails, same cause |
| [#6](https://github.com/fortran-lang/fortls/issues/6) | signature help on a generic interface: a signature per procedure, the matching one active | hover | fixed (feature) | no signature help |
| [#424](https://github.com/fortran-lang/fortls/issues/424) | construct names: go to definition, references, rename | constructs | fixed (feature) | no answer |
| [#512](https://github.com/fortran-lang/fortls/issues/512) | include directories and definitions from `compile_commands.json` | project | fixed (feature) | not read |
| [#438](https://github.com/fortran-lang/fortls/issues/438) | diagnostics have codes; `diagnostic_severity` turns a code off or changes its severity | diagnostics | fixed (feature) | no codes, only `disable_diagnostics` |
| [#171](https://github.com/fortran-lang/fortls/issues/171) | DEC `STRUCTURE`, `RECORD`, `UNION` and `MAP`, with `.` between components | parsing | fixed (feature) | not parsed |
| [#496](https://github.com/fortran-lang/fortls/issues/496) | user-defined functions highlighted where they are called (semantic tokens) | highlighting | fixed (feature) | no semantic tokens |
| [#501](https://github.com/fortran-lang/fortls/issues/501) | `prefer_implementation`: hover shows the documentation of a separate module procedure's body in a submodule | hover | fixed (feature) | the interface only |
| [#502](https://github.com/fortran-lang/fortls/issues/502) | `prefer_implementation`: go to definition goes to the body in the submodule | hover | fixed (feature) | the interface only |
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
  #563, #547, #423, #417, #348, #309,
  #209, #171, #126, #125, #96, #85, #56 and #28.

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
| [#137](https://github.com/hansec/fortran-language-server/issues/137) | the original name on a USE rename line resolves to a local variable of that name | hover | fixed (patched) | fails, same cause |
| [#178](https://github.com/hansec/fortran-language-server/issues/178) | signature help counts the commas inside an array constructor or a nested call | hover | fixed | fails, same cause |
| [#229](https://github.com/hansec/fortran-language-server/issues/229) | "Unexpected end of scope" for `end associate; end do` | diagnostics | fixed | fixed |
| [#229](https://github.com/hansec/fortran-language-server/issues/229) | names of an `ASSOCIATE` opened on the line of its `DO` (`do ...; associate (...)`) are not found | hover | fixed (patched) | fails, same cause |
| [#203](https://github.com/hansec/fortran-language-server/issues/203) | preprocessor conditional inside a continued declaration: the inactive branch adds its attributes | hover | fixed (patched) | fails, same cause |
| [#129](https://github.com/hansec/fortran-language-server/issues/129) | a warning for names that are not declared under IMPLICIT NONE, with a quick fix declaring them | diagnostics | fixed (feature) | not reported |
| [#201](https://github.com/hansec/fortran-language-server/issues/201) | hover on a name that is not declared shows the type its IMPLICIT rules (or the default ones) give it | hover | fixed (feature) | no hover |
| [#135](https://github.com/hansec/fortran-language-server/issues/135) | go to definition on a call of a generic interface goes to the procedure the arguments fit | hover | fixed (feature) | goes to the interface |
| [#62](https://github.com/hansec/fortran-language-server/issues/62) | completion of names from modules not used yet adds the `use` statement; a quick fix for a type not found | completion | fixed (feature) | names in scope only |
| [#133](https://github.com/hansec/fortran-language-server/issues/133) | completion of keyword arguments (`name=`) inside a call | completion | fixed (feature) | names in scope only |
| [#195](https://github.com/hansec/fortran-language-server/issues/195) | fuzzy workspace symbol search (`tar` finds `this_amazing_routine`) | navigation | fixed (feature) | names containing the query only |
| [#45](https://github.com/hansec/fortran-language-server/issues/45) | `.` between a derived-type variable and its component (`inst.member`) | parsing | fixed (feature) | not resolved |
| [#157](https://github.com/hansec/fortran-language-server/issues/157) | completion of construct names after `exit` and `cycle` | constructs | fixed (feature) | no completion |
| [#166](https://github.com/hansec/fortran-language-server/issues/166) | folding by program units, constructs and their branches, preprocessor conditionals and comment blocks | outline | fixed (feature) | no folding ranges |

## Issues of fortran-lang/vscode-fortran-support

Feature requests of the Modern Fortran extension that the server answers.
Their tests use `h.checkIn(.modern_fortran, ...)`.

| Issue | Behavior | Test file | zfls | fortls |
| --- | --- | --- | --- | --- |
| [#981](https://github.com/fortran-lang/vscode-fortran-support/issues/981) | a `! zfls: disable=masks-parent` comment hides the "masks variable in parent scope" warning | diagnostics | fixed (feature) | cannot be hidden |
| [#1306](https://github.com/fortran-lang/vscode-fortran-support/issues/1306) | `external_modules` stops `use mpi` (and other library modules) being reported as not found | diagnostics | fixed (feature) | always reported |
| [#401](https://github.com/fortran-lang/vscode-fortran-support/issues/401) | variables and functions named like keywords (`if`, `module`, `format`) highlighted as keywords | highlighting | fixed (feature) | no semantic tokens |
| [#245](https://github.com/fortran-lang/vscode-fortran-support/issues/245) | type-bound procedures not highlighted at their calls | highlighting | fixed (feature) | no semantic tokens |
| [#471](https://github.com/fortran-lang/vscode-fortran-support/issues/471) | `fpm.toml`: its include directory and preprocessor macros | project | fixed (feature) | not read |
| [#571](https://github.com/fortran-lang/vscode-fortran-support/issues/571) | a file of DEC structures has no diagnostics | parsing | fixed (feature) | diagnostics |
| [#617](https://github.com/fortran-lang/vscode-fortran-support/issues/617) | fypp: inline `${...}$`, `$:` and `@:` are no Fortran names (no warnings, no tokens); the extension highlights them | highlighting | fixed (feature) | read as Fortran |
| [#647](https://github.com/fortran-lang/vscode-fortran-support/issues/647) | an outline tree (breadcrumbs, sticky scroll), for clients with `hierarchicalDocumentSymbolSupport` | outline | fixed (feature) | flat symbol list only |
