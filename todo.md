# zfls roadmap

What we are working on, in order. Issue references point to the upstream
projects zfls replaces:

- **FL:** [fortran-lang/fortls](https://github.com/fortran-lang/fortls)
- **HS:** [hansec/fortran-language-server](https://github.com/hansec/fortran-language-server)
- **MF:** [fortran-lang/vscode-fortran-support](https://github.com/fortran-lang/vscode-fortran-support)
  (Modern Fortran)
- **FB:** [ekibun/FortranBreaker](https://github.com/ekibun/FortranBreaker)
  (Fortran Breakpoint Support)

`[ ]` to do, `[~]` in progress, `[x]` done (merged into `dev`).

## Now

- [x] Submodule procedures: with `prefer_implementation`, hover and go to
  definition use the implementation in the submodule (its documentation and
  location) instead of the interface in the parent module. FL #501, FL #502,
  HS #168
- [x] Keyword-argument completion: inside a call, offer `name=` for each
  dummy argument with its type and intent. HS #133
- [x] Auto-`use` completion: complete public names from modules the scope
  does not use yet, adding the `use` statement; an "add use" quick fix for
  undefined names. HS #62
- [x] Smaller LSP features:
  - [x] `textDocument/prepareRename` (reject intrinsics and keywords before
    the user types a new name)
  - [x] `textDocument/selectionRange` (expand selection by expression,
    statement, block, scope)
  - [x] `textDocument/documentLink` (`include` and `#include` files)
  - [x] `completionItem/resolve` (documentation on demand): not needed,
    completion with documentation takes 0.3 ms (median, json-fortran)
  - [x] Fuzzy workspace symbol search. HS #195
  - [x] `$/cancelRequest`
  - [x] Indexing progress (`workDoneProgress`). FL #417, MF #757
- [x] Benchmark find-references across a large multi-file workspace:
  json-fortran (61 files, 12k-line `json_value_module.F90`, ReleaseSafe),
  references median 1.5 ms, p95 12 ms; initialization 58 ms; 55 MiB
- [~] Split the largest source files into smaller modules: `server.zig`
  (done: request handlers in `src/server/`), `objects.zig` (done:
  `src/objects/`), `parser.zig`, `regex.zig`

## Next

- [ ] Implicit typing rules, an undeclared-variable diagnostic and a "declare
  variable" quick fix. HS #129, HS #201, FL #264
- [ ] Vendor extensions: DEC `STRUCTURE`/`RECORD`/`UNION`/`MAP`, `.` as the
  component separator, CUDA Fortran. FL #171, HS #230, HS #45, MF #571
- [ ] fypp: tolerate or preprocess fypp directives when parsing; syntax
  highlighting. MF #215, MF #617, MF #715, MF #615
- [ ] Fixed form: configurable code column limit (72/80/132), paste and
  indentation behavior. MF #87, MF #199, MF #254, MF #168, MF #177

## Later

- [ ] Pull diagnostics (`textDocument/diagnostic`) with workspace
  diagnostics: problems in files that are not open
- [ ] Unused variables, arguments and `use` names (faded, with a quick fix)
- [ ] Inlay hints: argument names, `associate` types, implicit types,
  parameter values
- [ ] Call hierarchy
- [ ] Type hierarchy (`extends`, overrides); parent components in completion.
  HS #121
- [ ] Module dependency graph: cycles and compile order
- [ ] Argument checking: count, unknown keywords, missing required arguments,
  assigning an `intent(in)` argument; later type, kind and rank
- [ ] More quick fixes: add `implicit none`, interface and submodule stubs,
  `.eq.` to `==`, `real*8` to a kind, keyword case. HS #226, MF #234, FL #28
- [ ] Richer hover: statements and keywords (FL #547), case preference
  (FL #28), code blocks in documentation (FL #209), OpenMP/OpenACC
  directives, literals (FL #125)
- [ ] Stubs for MPI (`mpi`, `mpi_f08`), `omp_lib` and `openacc`
- [ ] Large projects: summaries for unopened files (FL #563), an on-disk index
  cache (HS #39)
- [ ] Linters: fortitude (MF #1165), Codee
- [ ] Namelist (`.nml`) files (MF #1296, MF #153); pFUnit `.pf` files (MF #185)
- [ ] Walkthroughs (MF #472); translations (MF #616)
- [ ] Test explorer (pFUnit, test-drive, `fpm test`); fpm tasks
- [ ] Navigation between C headers and `bind(C)` procedures. HS #115
- [ ] References to user-defined operators and assignment. HS #95
- [ ] Coarrays: codimensions in hover, `sync` and `critical`
- [ ] Fixed form: toggle `C` comments (MF #535); custom comment patterns
  (MF #197)
- [ ] Optional exact diagnostics from a compiler (lfortran, gfortran). FL #85,
  HS #205
- [ ] Debugging with the generated launch configurations: conditional
  breakpoints set before launch (FB #7); Fortran variable and array values
  in the variables view (FB #10)

## Watching upstream

- FL #438: fortls plans an option listing diagnostics to suppress. When it
  lands, zfls will accept its name alongside `diagnostic_severity`.
- FL PR #504: telling modules with the same name apart by their `-J`
  directory.
- FL PRs #570 and #571 (fixes zfls already has): when they merge, zfls's
  tests will move to the new fortls.

## Done in 0.4.0

- [x] Outline tree (breadcrumbs, sticky scroll) and folding ranges. MF #135,
  MF #647, HS #166, FL #413
- [x] Semantic highlighting; inactive `#if` code grayed out. FL #56, FL #496,
  MF #245, MF #401, HS #78, FL #309
- [x] Diagnostic codes, per-code severity, `! zfls: disable` comments, an
  allowlist of external modules. FL #438, MF #981, MF #1306, HS #150
- [x] Include directories and macros from `compile_commands.json` and
  `fpm.toml`. FL #512, HS #40, MF #471
- [x] Generic interfaces: signature help for each specific procedure, go to
  the specific a call resolves to. FL #6, FL #423, HS #135
- [x] Construct names and statement labels: definition, references, rename,
  completion. FL #424, HS #157
- [x] Files changed outside the editor; restart when `.fortlsrc`, `fpm.toml`
  or `compile_commands.json` change. FL #114, MF #296
- [x] Untitled files
