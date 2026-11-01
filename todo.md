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

## Next

- [ ] fpm: pFUnit's tests in the Testing view
- [ ] A smarter index: the parsed symbols cached too (they take half a
  second to build for 3,870 files), summaries for unopened files to save
  memory (400 MiB for OpenBLAS). FL #563, HS #39
- [ ] Fortran and C: references across the languages; zfls asking clangd
  itself (for editors without a C server attached to C files); C to Fortran
  in VS Code before a Fortran file is opened
- [ ] Debugging: Fortran values in the variables view (module variables,
  which the C debuggers do not list; arrays of assumed shape and derived
  types; FB #10), then a Fortran debug adapter of zfls's own behind the
  `fortran` debug type
- [ ] Translations of the messages the extension shows while it runs
  (`vscode.l10n`), and translations and walkthroughs as they are asked for
  (MF #616, MF #472)

## Watching upstream

- FL #438: fortls plans an option listing diagnostics to suppress. When it
  lands, zfls will accept its name alongside `diagnostic_severity`.
- FL PR #504: telling modules with the same name apart by their `-J`
  directory.
- FL PRs #570 and #571 (fixes zfls already has): when they merge, zfls's
  tests will move to the new fortls.

## Done in 0.4.0

Editor features:

- [x] Outline tree (breadcrumbs, sticky scroll) and folding ranges. MF #135,
  MF #647, HS #166, FL #413
- [x] Semantic highlighting; inactive `#if` code grayed out. FL #56, FL #496,
  MF #245, MF #401, HS #78, FL #309
- [x] Selection ranges, document links on `include` and `#include` files,
  `prepareRename`
- [x] Call hierarchy; type hierarchy (`extends`)
- [x] Inlay hints: dummy argument names of positional arguments, `associate`
  types, implicit types, values of named constants
- [x] Fixed form: Toggle Line Comment with `C`, `c` or `*` in column 1
  (`zfls.fixedFormCommentCharacter`). MF #535
- [x] Fortran code blocks in documentation comments highlighted. FL #209
- [x] Comment markers of a dialect (`comment_markers`, `zfls.commentMarkers`:
  `;*`): read as comments by zfls and highlighted as comments. MF #197
- [x] fortitude linting, with its fixes as quick fixes and a fix-all source
  action. MF #1165
- [x] fpm projects: tasks (`build`, `run`, `test`, `install`, `clean`) with
  problem matchers, running and debugging their targets, Run and Debug
  Fortran File on a target's program, and the Testing view (each test
  target, and test-drive's suites and tests with their results)
- [x] The `fortran` debug type: launch configurations of a program or an
  fpm target, resolved into the debugger installed (C/C++, CodeLLDB, CDT
  GDB); F5 debugs the current file; a configuration per fpm target.
  Conditional breakpoints set before launch work (FB #7)
- [x] Hooks for translations (every string of `package.json` in
  `package.nls.json`, `tools/package_nls.py`) and walkthroughs; English only
- [x] Codee's checks (`zfls.codee.*`), best-effort: from its documented JSON
  output, not tested until a license is available
- [x] Namelist files (`.nml`): highlighting, folding, outline. MF #1296,
  MF #153; pFUnit `.pf` files are free-form Fortran. MF #185
- [x] Fuzzy workspace symbol search. HS #195
- [x] Untitled files

Navigation and hover:

- [x] Construct names and statement labels: definition, references, rename,
  completion. FL #424, HS #157
- [x] Generic interfaces: signature help for each specific procedure, go to
  the specific a call resolves to. FL #6, FL #423, HS #135
- [x] Submodule procedures: with `prefer_implementation`, hover and go to
  definition use the implementation in the submodule. FL #501, FL #502,
  HS #168
- [x] Hover on a name that is not declared shows its implicit type. HS #201
- [x] Hover on statements and keywords (FL #547), and on the words of
  OpenMP and OpenACC directives
- [x] Coarrays: codimensions in hover (`x[*]`, `codimension[2,*]`)
- [x] Hover on literals: kinds (`REAL(dp)`, `INTEGER(8)`), `DOUBLE
  PRECISION`, BOZ values. FL #125
- [x] `lowercase_hover`: keywords in hover in lowercase. FL #28
- [x] Fortran and C: go to definition of a `BIND(C)` procedure gives its C
  declarations (in VS Code from clangd or Microsoft's C/C++, else zfls's
  search of the workspace's C files), and from a C file the Fortran
  procedures (`zfls/bindC`, `zfls/bindCTargets`). HS #115
- [x] User-defined operators (`.ord.`) and defined assignment
  (`assignment(=)`): definition, hover, references. HS #95

Completion:

- [x] Keyword arguments (`name=`) inside a call. HS #133
- [x] Names of modules not used yet, adding the `use` statement. HS #62
- [x] Parent components of an extended type. HS #121

Diagnostics and code actions:

- [x] Diagnostic codes, per-code severity, `! zfls: disable` comments, an
  allowlist of external modules. FL #438, MF #981, MF #1306, HS #150
- [x] Names not declared under IMPLICIT NONE, with a "declare" quick fix.
  HS #129
- [x] Unused local variables and `use` names (faded, with a quick fix)
- [x] Workspace diagnostics: problems in files that are not open
  (`workspace_diagnostics`)
- [x] Compiler diagnostics from the server, for every editor
  (`compiler_diagnostics`: gfortran, ifx, ifort, flang, nvfortran, nagfor,
  lfortran), after compiling the modules a file uses; in VS Code with
  `zfls.linter.runner` set to `server`. FL #85, HS #205
- [x] Argument checking: count, unknown keywords, missing required arguments,
  assigning an `intent(in)` argument; the type, rank and kind of variables
  and literals (`argument-kind`), the type and rank of expressions
- [x] Module dependency graph: cycles (`circular-use`) and compile order
  (`zfls/compileOrder`, "zfls: Show Module Compile Order")
- [x] Quick fixes: add `implicit none` and `use` statements, `.eq.` to `==`,
  `real*8` to a kind, keyword case (upper, lower, title). HS #226, MF #234
- [x] Stubs: an interface block for an external procedure, the `module
  procedure` of a separate module procedure in a submodule

Projects and languages:

- [x] Include directories and macros from `compile_commands.json` and
  `fpm.toml`. FL #512, HS #40, MF #471
- [x] Files changed outside the editor; restart when `.fortlsrc`, `fpm.toml`
  or `compile_commands.json` change. FL #114, MF #296
- [x] DEC `STRUCTURE`/`RECORD`/`UNION`/`MAP`, `.` as the component separator.
  FL #171, HS #230, HS #45, MF #571
- [x] CUDA Fortran: `attributes(global|device)` procedures, `<<<...>>>`
  kernel launches, `.cuf` files, the CUDA modules
- [x] fypp: no Fortran names in its syntax, highlighting of its directives.
  MF #617, MF #715
- [x] Fixed form: configurable code column limit (72/80/132), paste and
  indentation behavior. MF #87, MF #199, MF #254, MF #168, MF #177
- [x] Stubs of the MPI modules (`mpi`, `mpi_f08`)

Server:

- [x] `$/cancelRequest`; indexing progress (`workDoneProgress`). FL #417,
  MF #757
- [x] Index cache: the texts of a large workspace's files in one file of
  zfls's cache, so that a cold start reads one file instead of thousands
  (`disable_index_cache`). HS #39
- [x] Benchmark on json-fortran (61 files, 12k-line `json_value_module.F90`,
  ReleaseSafe): references median 1.5 ms, p95 12 ms; initialization 58 ms;
  55 MiB. `completionItem/resolve` not needed (completion 0.3 ms)
- [x] Source files split into smaller modules (`src/server/`,
  `src/objects/`, `src/parser/`, `src/regex/`); none over 900 lines
