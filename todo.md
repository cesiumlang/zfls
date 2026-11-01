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

## Later

- [ ] Argument checking of kinds, and of the types and ranks of expressions
- [ ] Richer hover: case preference (FL #28), code blocks in documentation
  (FL #209), literals (FL #125)
- [ ] Large projects: summaries for unopened files (FL #563), an on-disk index
  cache (HS #39)
- [ ] Linters: fortitude (MF #1165), Codee
- [ ] Namelist (`.nml`) files (MF #1296, MF #153); pFUnit `.pf` files (MF #185)
- [ ] Walkthroughs (MF #472); translations (MF #616)
- [ ] Test explorer (pFUnit, test-drive, `fpm test`); fpm tasks
- [ ] Navigation between C headers and `bind(C)` procedures. HS #115
- [ ] References to defined assignment (`assignment(=)`)
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
- [x] User-defined operators (`.ord.`): definition, hover, references.
  HS #95

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
- [x] Argument checking: count, unknown keywords, missing required arguments,
  assigning an `intent(in)` argument; the type and rank of variables and
  literals
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
- [x] Benchmark on json-fortran (61 files, 12k-line `json_value_module.F90`,
  ReleaseSafe): references median 1.5 ms, p95 12 ms; initialization 58 ms;
  55 MiB. `completionItem/resolve` not needed (completion 0.3 ms)
- [x] Source files split into smaller modules (`src/server/`,
  `src/objects/`, `src/parser/`, `src/regex/`); none over 900 lines
