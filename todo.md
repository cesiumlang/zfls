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

## Now (0.4.0)

Nothing left: 0.4.0 is ready for its release.

## After 0.4.0

- [ ] Translations, as they are asked for (MF #616)

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
- [x] pFUnit's tests in the Testing view, in CMake projects
  (`add_pfunit_ctest`): each `@test` of a `.pf` file run and reported one by
  one, a failed assertion at its line
- [x] The `fortran` debug type: launch configurations of a program or an
  fpm target, resolved into the debugger installed (C/C++, CodeLLDB, CDT
  GDB); F5 debugs the current file; a configuration per fpm target.
  Conditional breakpoints set before launch work (FB #7)
- [x] The Fortran Module Variables view while debugging: the module
  variables the selected frame's line sees (its module's, and those of its
  USE statements, under their local names; `zfls/moduleVariables`), with
  their values from the debugger, which lists only a procedure's own.
  FB #10
- [x] A debugger of zfls's own behind the `fortran` debug type, in front of
  gdb's Debug Adapter Protocol (`gdb -i=dap`, gdb 14+ with Python), the
  default when there is one: Fortran values in the Variables view itself
  (array elements by their subscripts and bounds, large arrays in
  sections, previews of arrays and derived types, unallocated arrays,
  polymorphic objects by their dynamic type, hidden CHARACTER lengths left
  out), the module variables as a scope, Fortran expressions for watches
  and setting values, a stop at Fortran runtime errors and ERROR STOP,
  the program in a terminal for its input, attaching to a process or a
  gdbserver. FB #10. lldb has no Fortran (no type system for it), so
  macOS on Arm and MSVC-ABI programs keep the debugger extensions
- [x] Hooks for translations (every string of `package.json` in
  `package.nls.json`, `tools/package_nls.py`; the messages shown while the
  extension runs through `vscode.l10n`, in `l10n/bundle.l10n.json`,
  `tools/l10n_bundle.py`) and walkthroughs; English only
- [x] A Getting Started walkthrough (**zfls: Get Started**, and Help >
  Welcome): opening a project, configuring it, compiler diagnostics,
  running and debugging, fpm and pFUnit tests, formatting, the output.
  MF #472
- [x] ifx without Visual Studio (Windows x64): `zfls setup-ifx` and **zfls:
  Set Up ifx** unpack ifx from Intel's offline installer (downloaded from
  Intel) without running it, once Intel's license is accepted, and set it
  up to link with its own lld-link and zfls's ifx kit (a startup object,
  MIT-0, and import libraries from MinGW-w64's definition files, made by
  `zig build ifx-kit`) instead of Visual Studio's
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
  procedures (`zfls/bindC`, `zfls/bindCTargets`); find references across
  the languages (`zfls/bindCReferences`), in VS Code from a C file before
  any Fortran file is opened. HS #115
- [x] zfls asking clangd itself (`bind_c_clangd`), in editors with no C
  language server to ask, for the C declarations and calls of `BIND(C)`
  procedures, added to its own search: those of headers outside the source
  directories and of names a macro makes
- [x] User-defined operators (`.ord.`) and defined assignment
  (`assignment(=)`): definition, hover, references. HS #95
- [x] Intrinsic procedure documentation: the latest M_intrinsics, fetched
  by the build as upstream wrote it, its links to other procedures opening
  the pages M_intrinsics publishes; a weekly workflow proposes each upstream
  update as a patch release

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
  (`disable_index_cache`), and the symbols parsed from them, so that a
  start parses only the files that changed: OpenBLAS (3,936 files) starts
  in 0.3 s instead of 0.65 s. FL #563, HS #39
- [x] Less memory: 302 MiB after indexing OpenBLAS (3,936 files, 52 MiB of
  sources; 366 MiB before), each symbol 256 bytes instead of 544
- [x] Benchmark on json-fortran (61 files, 12k-line `json_value_module.F90`,
  ReleaseSafe): references median 1.5 ms, p95 12 ms; initialization 58 ms;
  55 MiB. `completionItem/resolve` not needed (completion 0.3 ms)
- [x] Source files split into smaller modules (`src/server/`,
  `src/objects/`, `src/parser/`, `src/regex/`); none over 900 lines
