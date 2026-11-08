# zfls roadmap

What we are working on, in order. Issue references point to the upstream
projects zfls replaces:

- **FL:** [fortran-lang/fortls](https://github.com/fortran-lang/fortls)
- **HS:** [hansec/fortran-language-server](https://github.com/hansec/fortran-language-server)
- **MF:** [fortran-lang/vscode-fortran-support](https://github.com/fortran-lang/vscode-fortran-support)
  (Modern Fortran)
- **FB:** [ekibun/FortranBreaker](https://github.com/ekibun/FortranBreaker)
  (Fortran Breakpoint Support)

`[ ]` to do, `[~]` in progress, `[x]` done (merged into `dev`). Done items
stay until the release that ships them; after that, the release's notes on
GitHub and the git history record them.

## Now

- [ ] conda-forge: the staged-recipes pull request takes the recipe the
  release attaches (`zfls-v0.4.0-conda-recipe.yaml`); once the
  `zfls-feedstock` exists, CI's `conda-forge` job (switched off for now)
  opens each release's pull request to it
- [ ] Translations, as they are asked for (MF #616)

## On hold: LFortran

Found with LFortran 0.68.0 (the latest release, 2026-10-25, from
conda-forge) on Windows, and in LFortran's source. On hold until LFortran
has a more stable Windows build. zfls's LFortran support so far is a parser
of its messages, unit-tested; it has not been run against a real LFortran.

Compiler diagnostics (`compiler_diagnostics: lfortran`):

- [ ] The modules a file uses are compiled with `--semantics-only`, which
  writes no `.mod` file, so every file that uses a module of the workspace
  gets "Module 'm' modfile was not found", and the module counts as stale
  on every check. Compile the dependencies with `--symtab-only -c -o
  <mod dir>/zfls-lint.o -J <mod dir>` instead (it writes the `.mod` file
  and skips the executable statements; enough for the users of type-bound
  procedures, defined operators and pure functions), and keep
  `--semantics-only` for the file checked. Look at whether two workers can
  write the same object file at once (nvfortran's `-c` already does this)
- [ ] Implicit typing: LFortran's own dialect, its default (`--std=lf`),
  rejects implicit typing and implicit interfaces, so standard code without
  IMPLICIT NONE, and most fixed form, gets false "Variable 'i' is not
  declared" errors. Pass `--implicit-typing --implicit-interface`, unless
  `compiler_args` has an option of its own about them or a `--std`
  (`--disable-implicit-typing` together with `--implicit-typing` is an
  error). Not `--std=f23`: it also turns on implicit argument casting,
  which hides arguments of the wrong type (`call s(1)` for a `real` dummy)
- [ ] Every error, not only the first: `--continue-compilation`
- [ ] Output that is not `file:lines:columns: severity: message`, dropped
  today: command-line errors (`The following argument was not expected:
  --bogus`, ``The option `--std=f77` is not supported``, `Cannot use
  --disable-implicit-typing and --implicit-typing at the same time`),
  `error: no such file or directory: ...`, internal compiler errors.
  Publish them as errors without a location, as the other compilers' are
- [ ] A test against a real compiler: zfls driven by `tests/lsp_client.zig`
  with `compiler_diagnostics` on fixtures (a module and a program that
  uses it, implicit typing, fixed form, the preprocessor and `-D`, an
  include directory, an unsaved edit), in CI with LFortran from
  conda-forge. No compiler has one yet; gfortran's would be next

Running (**Run Fortran File**):

- [ ] `-g`, the extension's default arguments for LFortran, fails on
  Windows ("The `runtime stacktrace` is not enabled"):
  `src/lfortran/pipeline.cpp` refuses `-g` unless LFortran was built with
  `WITH_RUNTIME_STACKTRACE`, which its `CMakeLists.txt` ties to libunwind
  and ELF's `link.h` (Mach-O on macOS), and conda-forge's Windows build
  leaves out. No arguments by default on Windows, and the README saying why
- [ ] Linking on Windows without Visual Studio: LFortran's Windows build
  links with MSVC's `link` and its `lfortran_runtime_static.lib` (in a
  shell where Git's `/usr/bin/link` comes first, that `link` runs and
  fails). Whether `--linker=clang` with lld, or zfls's ifx kit
  (`zfls setup-ifx`), can link LFortran's programs

Debugging:

- [ ] LFortran's programs in `zfls dap` as gfortran's are, with gdb on Linux
  and macOS: its runtime-error and ERROR STOP functions among the stops
  (`src/dap/fortran.zig`), its array descriptors, derived types, CHARACTER
  lengths and module variables in the Variables view
  (`src/dap/values.zig`, `src/dap/gdb_variables.zig`), and a `dap_gdb`
  test of an LFortran program in CI on Linux
- [ ] On Windows, as ifx's are (dbgeng): waits for LFortran. Besides `-g`
  above, its debug information is DWARF only (LLVM's `DIBuilder` in
  `src/libasr/codegen/asr_to_llvm.cpp`, no CodeView), which Windows's
  debuggers do not read

## Proposed

Ideas not scheduled yet go here; there are none at the moment.

## Watching upstream

- FL #438: fortls plans an option listing diagnostics to suppress. When it
  lands, zfls will accept its name alongside `diagnostic_severity`.
- FL PR #504: telling modules with the same name apart by their `-J`
  directory; with it, perhaps a recursive search for
  `compile_commands.json`.
- FL PRs #570 and #571 (fixes zfls already has): when they merge, zfls's
  tests will move to the new fortls (`FORTLS_REF` in CI, the issue table in
  the README, the differential test).
- LFortran on Windows: a build that takes `-g` (`WITH_RUNTIME_STACKTRACE`
  without ELF) and writes CodeView, and links without Visual Studio. When
  it comes, the "On hold: LFortran" items resume.
