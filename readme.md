# zfls

A Fortran language server written in Zig. zfls is a native port of
[fortls](https://github.com/fortran-lang/fortls), the Python Fortran language
server, and speaks the same Language Server Protocol subset with the same
command line options and configuration files.

## Features

- Completion, hover, signature help, go to definition and implementation,
  references, document highlights, rename, document and workspace symbols
- Beyond fortls: an outline tree of document symbols (for clients that take
  one: breadcrumbs, sticky scroll); folding of program units, constructs
  and their branches, preprocessor conditionals and comment blocks; semantic
  highlighting of modules, types, procedures, dummy arguments, components
  and variables by what they are (a variable named `if` is a variable), with
  the lines that preprocessor conditionals leave out shown inactive
- Diagnostics: declarations, scopes, `CONTAINS`, `IMPLICIT`, `USE`/`IMPORT`
  checks, line length limits; each with a code that settings and comments
  can turn off (see [Diagnostics](#diagnostics))
- Construct names (`outer: do` ... `exit outer`) and statement labels
  (`go to 10`, `read (5, 100)`): go to definition, references, rename, and
  completion after `exit` and `cycle`
- Completion of keyword arguments inside a call (`call move(p, dx=`): the
  dummy arguments of the procedure, of each procedure of a generic
  interface, of an intrinsic, or the components of a structure constructor
- Completion of the public names of modules not used yet, adding the
  `use module, only: name` statement, and a quick fix adding it for a type
  that is not found
- Call hierarchy: the procedures that call a procedure, and those it calls
- Type hierarchy: the type a derived type extends, and the types that
  extend it; completion offers the parent components of an extended type
- Inlay hints: the dummy argument each positional argument of a call goes
  to (`call move(p, dx: 1.0)`), the type of each `ASSOCIATE` name, the
  implicit type of a name that is not declared, and the value of a named
  constant where it is used
- Selection ranges (expand the selection from a name to its parentheses,
  statement, constructs, procedure, module and file), links on the files of
  `#include` and `INCLUDE`, and a rename check that refuses intrinsics and
  keywords before a new name is typed
- Code actions: implementing deferred type-bound procedures, adding
  `IMPLICIT NONE`, writing `.eq.` ... `.ge.` as `==` ... `>=` and `real*8` as
  `real(8)`, and (Source Actions) the keywords of a file in upper, lower or
  title case
- Include directories and preprocessor definitions from the project's
  `compile_commands.json` (CMake, Meson, Bear) and `fpm.toml` (see
  [Build files](#build-files))
- Fixed and free source form, line continuations, Doxygen and FORD style
  documentation comments
- DEC extensions: `STRUCTURE` (nested too), `RECORD`, `UNION`/`MAP`, and
  `.` between a variable and its component (`rec.field`)
- CUDA Fortran: `attributes(global)` and `attributes(device)` procedures,
  signature help in a kernel launch (`call k<<<grid, block>>>(...)`), `.cuf`
  files
- C preprocessor support (`#if`/`#ifdef`/`#elif`, object and function-like
  macros, `#include`)
- Documentation for intrinsic procedures, statements, keywords and the
  intrinsic modules (`iso_fortran_env`, OpenMP, OpenACC, ...); stubs of the
  MPI modules `mpi` and `mpi_f08`

## Building

zfls needs Zig 0.17.0.

```sh
git clone --recurse-submodules <repository>
cd zfls
zig build -Doptimize=ReleaseFast
```

The executable is `zig-out/bin/zfls` (`zfls.exe` on Windows). `zig build`
also generates the API documentation in `zig-out/docs`; `zig build bin`
installs only the executable.

Each release also publishes `zfls-v<version>-src.tar.gz`, the sources with
the `vendor/rstd` submodule included (`tools/make_source_archive.sh`), which
the conda-forge recipe in `packaging/conda-forge` builds from. CI builds and
tests that recipe on Linux, macOS and Windows for every change.

### VS Code extension

`editors/vscode` is a VS Code extension that runs zfls for Fortran files and
adds syntax highlighting. Each release publishes it as
`zfls-vscode-v<version>-<platform>.vsix`, one per VS Code platform with that
platform's zfls inside (`tools/package_vscode.sh`), plus a `universal` one
that runs `zfls` from the `PATH`. To install one, use "Extensions: Install
from VSIX..." in VS Code. The release also publishes the platform packages,
as `cesiumlang.zfls`, to the Visual Studio Marketplace and to Open VSX
(VSCodium and other VS Code derivatives), and the universal one to the
Marketplace for the platforms without their own. Each registry has its own
workflow, which the release job starts and which takes the packages from the
release: "Publish to the Marketplace" (`.github/workflows/marketplace.yml`)
uses Marketplace Trusted Publishing (`vsce publish --oidc`: the publisher's
Trusted Publishing policy names this repository and that workflow file), and
falls back, with a warning, to a Microsoft Entra managed identity that is a
member of the publisher (the `AZURE_*` repository variables; the
"Marketplace identity" workflow shows the ID to add); and "Publish to Open
VSX" (`.github/workflows/open-vsx.yml`) is the workflow whose OIDC token
Open VSX trusts for the `cesiumlang` namespace (trusted publishing; the
`OVSX_PAT` repository secret is used only if that is refused, with a
warning). No stored token is needed. Either workflow can be run by hand, on
`main`, for any released version; versions already published are skipped,
so a failed run can simply be run again.

The extension replaces the Modern Fortran extension (it registers the same
Fortran languages, grammars and snippets, with zfls instead of fortls) and
recommends disabling Modern Fortran when both are enabled; see its
[README](editors/vscode/README.md#replacing-modern-fortran).

To work on it (Node.js 20 or later):

```sh
cd editors/vscode
npm ci
npm run typecheck
ZFLS_PATH=../../zig-out/bin/zfls npm test   # in a downloaded VS Code
```

## Usage

Configure the editor's language client to start `zfls`; it communicates over
standard input and output. All fortls options are accepted, for example:

```sh
zfls --incremental_sync --hover_signature --use_signature_help
zfls --help
```

Options can also be set in a JSON or JSON5 configuration file in the project
root, `.fortlsrc`, `.fortls.json` or `.fortls` by default (or the file named
with `-c`/`--config`). The option names are those of the
[fortls documentation](https://fortls.fortran-lang.org/options.html).

The fortls debug options work as well, for instance
`zfls --debug_parser --debug_filepath file.f90` prints the parser trace and
the resulting object tree, and `--debug_hover --debug_filepath file.f90
--debug_line 10 --debug_char 5` runs a single hover request.

### Build files

zfls adds to the `include_dirs` and `pp_defs` options what the project's
build files say:

- `compile_commands.json`, in the root, `build/` or `builddir/` (or the
  file, or directory, that the `compile_commands` option names; `""` or
  `disable_compile_commands` for none, as in fortls's pending PR #504): the
  `-I`, `-isystem` and `-D` flags (`/I` and `/D` too) of its Fortran entries.
  Definitions apply to every file, the first value of a name winning.
- `fpm.toml` in the root: the `include-dir` of `[library]` (`include` by
  default, when it exists) and the `macros` of `[preprocess.cpp]`.

A definition from the options or the configuration file is kept over one
from a build file.

### Fortran and C

For a procedure with `BIND(C)`, whose C name is its `NAME=` or else its
name in lowercase, go to definition gives its C declarations too: zfls looks
for them in the workspace's C and C++ files (`.h`, `.c`, `.cpp`, `.cu`, ...),
in lines where the name follows a type and an opening parenthesis follows
it, without parsing C. Find references gives the C calls too (the name
followed by an opening parenthesis, outside comments and strings), and the
references of the other Fortran procedures of the same C name (interfaces
of the C function in other modules). `disable_bind_c_search` turns that
search off.

The other way, an editor that attaches zfls to C files too (in Neovim, with
`c` and `cpp` among its filetypes) gets, on a C name, the Fortran procedures
that bind it (go to definition) and their Fortran references with the C
calls (find references). zfls only keeps the text of a C document: it
neither parses nor diagnoses it, and answers nothing else there.

Three requests of zfls's own let an editor ask its C language server
instead: `zfls/bindC` (a position) gives the procedure there and its C name,
or null; `zfls/bindCTargets` (`{"name": ...}`) gives the locations of the
Fortran procedures of a C name, and `zfls/bindCReferences` (`{"name":
...}`) their Fortran references. The VS Code extension uses them with
clangd or Microsoft's C/C++.

### Index cache

A workspace of 200 files or more has its files' texts kept in one file of
zfls's cache directory (`index/` in `%LOCALAPPDATA%\zfls` on Windows,
`~/Library/Caches/zfls` on macOS, `$XDG_CACHE_HOME/zfls` or `~/.cache/zfls`
elsewhere), each with its size and modification time. A start reads a file
whose size and time have not changed from there, instead of opening it:
reading one file instead of thousands is what makes the first start after a
reboot slow, on Windows above all, where an antivirus scans each file
opened. zfls parses the texts as it parses the files, so what it knows of
the workspace is the same. The cache is written again, on a thread of its
own, when files were added, changed or removed; those of other workspaces
are deleted after 60 days without use. `disable_index_cache` turns it off.

### Comment markers

Some codebases are written in a dialect that a preprocessor turns into
Fortran, with comments that start with something other than `!`, such as
`;*` (`go to 110  ;* it's done`). `comment_markers` lists such markers:
outside strings, zfls reads what follows one as a comment, so that its words
are not names and a quote in it does not start a string.

```json
{ "comment_markers": [";*"] }
```

In VS Code, `zfls.commentMarkers` sets it, and the extension highlights
those comments too, after a window reload.

### Diagnostics

Each diagnostic has a code (shown by editors, e.g. in the VS Code Problems
panel): `line-too-long`, `comment-too-long`, `statement-without-scope`,
`multiple-contains`, `unexpected-end`, `invalid-parent`,
`procedure-before-contains`, `declared-twice`, `masks-parent`,
`import-outside-interface`, `module-not-found`, `use-after-implicit`,
`deferred-not-implemented`, `intent-not-in-arguments`,
`argument-not-declared`, `not-imported`, `object-not-found`,
`undeclared-name`, `unused-name`, `circular-use`, `argument-mismatch`,
`argument-kind` and `intent-in-assigned`.

- `diagnostic_severity` (option or configuration file) sets the severity of
  a code, or hides it: `{"masks-parent": "off", "declared-twice": "warning"}`;
  the severities are `off`, `error`, `warning`, `information` and `hint`.
- `external_modules` names modules from outside the project (glob patterns,
  case-insensitive) that `USE` statements may name without a
  `module-not-found` diagnostic, e.g. `["mpi", "petsc*"]`.
- In the code, a comment `! zfls: disable=masks-parent, declared-twice`
  hides those codes on its line (`! zfls: disable` hides every code),
  `! zfls: disable-next-line=...` on the next line and
  `! zfls: disable-file=...` in the whole file.

These are zfls's own options: fortls does not have them.

### Compiler diagnostics

With `compiler_diagnostics` set to a compiler (`gfortran`, `ifx`, `ifort`,
`flang`, `nvfortran`, `nagfor` or `lfortran`), zfls has it check each file
when the file is opened and saved, and publishes the compiler's errors and
warnings with its own diagnostics of the file, labelled with the compiler's
name. This works in every editor, not only VS Code.

The compiler runs on a thread of its own, in syntax-only mode, one file at a
time (a newer save of a file replaces a run that has not started). First it
compiles the workspace modules that the file uses, and those they use,
whose `.mod` files are missing or older than their sources, in compile order
from zfls's module graph.

```json
{
  "compiler_diagnostics": "gfortran",
  "compiler_path": "/opt/gcc/bin",
  "compiler_args": ["-Wall", "-std=f2018"],
  "compiler_mod_dir": "build/zfls-mod"
}
```

- `compiler_path`: the executable, or the directory that holds it (by
  default the compiler on the `PATH`).
- `compiler_args`: the compiler's own options; by default its warnings
  (`-Wall` for gfortran, `-warn all` for Intel, `-Minform=warn` for
  nvfortran). zfls adds the syntax-only, form, preprocessor and module
  directory options, the file's directory and `include_dirs` (`-I`), and,
  for files it preprocesses, `pp_defs` (`-D`). On the command line it is one
  string, split at spaces: `--compiler_args="-Wall -std=f2018"`.
- `compiler_mod_dir`: where the `.mod` files go, relative to the root; by
  default a directory per project and compiler in zfls's cache
  (`%LOCALAPPDATA%\zfls` on Windows, `~/Library/Caches/zfls` on macOS,
  `$XDG_CACHE_HOME/zfls` or `~/.cache/zfls` elsewhere).

`.fypp` files are not checked: no compiler reads fypp's directives.

## Testing

| Command | Checks |
| --- | --- |
| `zig build test` | Zig unit tests, and the tests of upstream fortls issues |
| `zig build test-issues` | only the tests of the open issues of upstream fortls (see `tests/issues/README.md`) |
| `zig build test-fuzz` | mutated programs thrown at an in-process server (crashes, leaks); `--fuzz` runs the fuzzer |
| `zig build test-parity` | fortls's server test suite, replayed against zfls |
| `zig build test-oracle` | symbols of `tests/fortran` against gfortran parse trees |
| `zig build test-stress` | long randomized editing sessions (crashes, leaks, stale state) |
| `zig build test-differential` | every request type against Python fortls (slow) |
| `zig build test-all` | all of the above except the differential run |

The stress test edits a copy of fortls's test sources thousands of times,
with saves, close/reopen and requests mixed in, and then checks that every
edited file's symbols and diagnostics match a fresh server's. Run it on a
Debug build so memory errors and leaks are caught; for longer runs call
`python tests/stress_edit.py --seeds N --steps M` (see `--help`).

The parity, differential and stress tests need a fortls checkout, `../fortls` by
default or `-Dfortls=PATH`, and Python 3 (`-Dpython=EXE`); no third-party
Python packages are required. The oracle test needs `gfortran` on the `PATH`
or in the MSYS2 UCRT64 installation; it is skipped when gfortran is missing.

`tools/bench_workspace.py` compares zfls with fortls on a large workspace
(workspace initialization, request latency, edits, memory), for example a
checkout of [json-fortran](https://github.com/jacobwilliams/json-fortran):

```sh
zig build bin -Doptimize=ReleaseSafe
python tools/bench_workspace.py ../json-fortran
```

## Releases

`zfls --version` reports the version in `build.zig.zon`, which is the
version of the next release: with `-dev` in Debug builds, and with `-rc` in
release builds while the `zfls.prerelease` file that `zig build` installs
sits next to the executable. Release archives leave that file out, so a
released binary reports the plain version.

GitHub Actions (`.github/workflows/ci.yml`) builds the release binaries for
every pull request and every push to `main` or `dev` once, and tests them as release
candidates on Linux, Windows and macOS, each on x86_64 and ARM64: the
suites above, longer stress runs and the differential test.

Changes are collected on the `dev` branch, which pull requests target, and
released together by merging `dev` into `main`. Both branches take a change
only when its checks pass (an administrator can override that when merging a
pull request); `main` also takes changes only through pull requests, while
`dev` takes pushes from maintainers. CI's own push to `dev` after a release
uses a deploy key, the `DEV_DEPLOY_KEY` secret, which the ruleset of `dev`
lets bypass the checks. A separate ruleset keeps `dev` from being deleted,
with no exceptions, so merging the release pull request does not remove it.

The release notes are generated from the pull requests merged since the last
release, in sections by label (`.github/release.yml`): `fix`, `feature`,
`performance`, `tests`, `refactor` and `ci`. `skip-changelog` leaves a pull
request out, for example the `dev` to `main` pull request of a release.

When a push to `main` passes on every platform, the same archives are
published on the GitHub releases page and the tested commit is tagged. CI
then merges `main` back into `dev` and commits the next patch version to
`build.zig.zon` there. For a minor or major release, set the version in
`build.zig.zon` on `dev` by hand. A pull request to `main` fails its "Version is unreleased" check when it changes anything
beyond the exempt files while `build.zig.zon` holds an already released (or
older) version. Pushes that only change
files listed in `.github/workflows/exempt.txt` (documentation, tests,
editor settings) are tested but not released.

A merged pull request is not built again: when a passed run of the pull
request built exactly the code that lands on `main` (the same git tree and
version), the release publishes that run's archives. Otherwise, for example
when `main` changed after the pull request was tested, the push to `main`
builds and tests the release binaries itself first.

## Differences from fortls

zfls deliberately differs from fortls in a few places:

- Positions are UTF-16 code units, as the LSP specifies; fortls counts code
  points.
- Inserting text that ends with a newline through an incremental change does
  not add a spurious empty line.
- Several requests on which fortls raises an internal error (for example
  implementation requests on module names, or completion inside an
  `IMPORT` statement outside an interface) return `null` or an empty result.
- Line length diagnostics are not duplicated when a file is checked again.
- On a call of a generic interface, signature help shows the signature of
  each of its procedures, the one the arguments so far fit active (fortls
  #6), and go to definition goes to that procedure (hansec #135); fortls
  shows no signature and goes to the interface.
- Inside a call, completion also offers `name=` for each argument the call
  can name and has not named yet (hansec #133), first in the list; fortls
  offers only the names in scope.
- Completion also offers the public names of the workspace's and the
  intrinsic modules that the program unit does not use, after the others;
  choosing one adds `use module, only: name` after the unit's last USE
  statement (hansec #62, `autocomplete_no_auto_use` turns it off). A type
  that is not found has a quick fix adding that statement.
- A local variable of a procedure or program, or a name of a `USE ONLY`
  list, that its scope never uses gets an `unused-name` hint, shown faded,
  with a quick fix removing a declaration of that name only. A name counts
  as used when it appears anywhere else in the scope, contained procedures
  and inactive preprocessor branches included; dummy arguments, function
  results and module names are not reported. fortls has no such check.
- `workspace_diagnostics` publishes the diagnostics of every workspace file
  after initialization, and again when a saved or changed file changes
  them, so that editors list the problems of files that are not open; a
  deleted file's are cleared. fortls only checks open files.
- Under IMPLICIT NONE, a name that is not declared gets an
  `undeclared-name` warning with a quick fix declaring it (hansec #129);
  fortls only checks the types named in declarations. It is left out where
  a USE statement names a module that is not in the workspace or an
  INCLUDE file is not found, as the name could come from those.
- `fixed_line_length` (as gfortran's `-ffixed-line-length-n`: 72, 80, 132)
  makes the columns past it of a fixed-form line a comment: a `comment`
  semantic token, and no names there. The VS Code extension passes 72 by
  default (`zfls.fixedFormLineLength`), as its grammar no longer stops the
  code at column 72 itself (Modern Fortran #87). fortls has no such option.
- Typing `#` first on an indented line moves it to the first column
  (`textDocument/onTypeFormatting`, Modern Fortran #177); fortls has no
  on-type formatting.
- fypp: the words of inline expressions (`${...}$`), eval lines (`$:`) and
  macro calls (`@:`) are no Fortran names, and a file with fypp directives
  gets no `undeclared-name` warnings, as fypp's loops and macros make names.
- `use mpi` and `use mpi_f08` find stubs of the MPI modules (the
  procedures and constants used most, with their arguments): hover,
  signature help and completion work for them, and the names the stubs
  leave out are not reported as undeclared. fortls reports the modules as
  not found.
- CUDA Fortran: a procedure with `attributes(...)` is a procedure,
  signature help reads past a kernel's `<<<grid, block>>>`, `.cuf` and `.CUF`
  files are Fortran sources, and the modules of NVIDIA's compiler (`cudafor`,
  `cublas`, `cufft`, `curand`, `cusparse`, ...) are external modules, never
  "not found". fortls reads none of these.
- DEC structures are read (fortls #171): `STRUCTURE /name/` is a derived
  type, `RECORD /name/ a, b` declares variables of it, the fields of
  `UNION`/`MAP` blocks are fields of the structure, and a nested structure
  declares the fields its name list gives. `.` separates a component when it
  follows a name or `)` and does not start an operator (`a.and.b`), as in
  `rec.field` or `arr(i).field` (hansec #45). fortls reads none of these.
- A user-defined operator (`.ord.`) has a definition (its `interface
  operator (.ord.)`), a hover (the procedures of that interface) and
  references (its uses in the workspace) (hansec #95); fortls has none. So
  has the `=` of an assignment to a variable whose type has a defined
  assignment (`generic :: assignment(=) => p` in the type or a type it
  extends, else an `interface assignment(=)` for it): its references are
  the binding and the assignments to variables of the types that use it.
- Hover on a coarray shows its codimension (`REAL, CODIMENSION[*] :: x`),
  written after its name or as an attribute; fortls drops it.
- Hover on a statement or attribute keyword (`ALLOCATE`, `CALL`, `INTENT`,
  ...) shows its documentation (fortls #547), and so does hover on a word of
  an OpenMP or OpenACC directive (`!$omp parallel do`, `reduction`,
  `!$acc data`); fortls has no hover there.
- Hover on a literal constant shows its type with its kind: `3.0_dp` is
  `REAL(dp)`, `7_8` `INTEGER(8)`, `1d0` `DOUBLE PRECISION`, `.false._1`
  `LOGICAL(1)`, `dp_'x'` `CHARACTER(LEN=1, KIND=dp)`, and `z'ff'` a BOZ
  constant of value 255 (fortls #125). fortls shows the type without its
  kind, and nothing on `1d0`, `7_8` or BOZ constants.
- Hover on a name that is not declared shows the type that the IMPLICIT
  statements of its scope and the surrounding scopes, or the default rules
  (I to N INTEGER, other letters REAL), give it (hansec #201); fortls has
  no hover there. Under IMPLICIT NONE there is none.
- Workspace symbol search also finds the names the query matches fuzzily
  (`tar` finds `this_amazing_routine`), after those that contain it
  (hansec #195); fortls finds only the latter.
- A request that the client cancels (`$/cancelRequest`) while it waits
  behind others is answered with `RequestCancelled` instead of being worked
  on; fortls ignores cancellations.
- With the `workDoneToken` of the initialize request, indexing reports its
  progress (`$/progress`, files parsed); fortls reports none.
- Stub actions: on a call of a procedure defined outside any module, an
  interface block for it in the calling unit; on a separate module procedure
  without implementation, its `module procedure` stub in a submodule of its
  module (a new one at the end of the file when there is none).
- More code actions: "Add IMPLICIT NONE" on the first line of a program
  unit without IMPLICIT statement, the relational operators `.eq.` ...
  `.ge.` as `==` ... `>=` and the kinds written with `*` (`real*8`,
  `character*10`) as kind parameters on the selected lines, and Source
  Actions putting the keywords of a file in upper, lower or title case
  (hansec #226, Modern Fortran #234), names spelled like keywords excepted.
  fortls only implements deferred procedures.
- Calls of workspace procedures are checked (`argument-mismatch`): too
  many arguments, a keyword the procedure does not have, an argument given
  twice, a required (not OPTIONAL) argument missing, and the kind of type
  (integer, real, complex, logical, character, derived) of an argument, an
  array for a scalar, a scalar that is no variable or element for an array
  (not for elemental or assumed-rank). An argument is typed when it is a
  literal, a variable or a part of one (`a(i)` a scalar, `a(:)` or `a(v)`
  with an array `v` an array, `p%c`, a substring), or an expression of
  these with intrinsic operators; one with a function, an intrinsic, a
  user-defined operator or a derived type in an expression is not checked. Generic interfaces,
  intrinsics, procedure pointers, alternate returns and procedures whose
  argument list has preprocessor lines are not checked. When the type is
  right but its kind differs (`1.0` for a `REAL(dp)` argument), that is an
  `argument-kind` error, a code of its own, as a compiler option such as
  gfortran's `-fdefault-real-8` changes the default kinds. Kinds are
  numbered as gfortran does on x86-64, from kind numbers, `*8`, `DOUBLE
  PRECISION`, literals (`1d0`, `1_8`), the constants of `ISO_FORTRAN_ENV`
  and `ISO_C_BINDING`, `KIND()`, `SELECTED_REAL_KIND()`,
  `SELECTED_INT_KIND()` and the PARAMETERs set from them; a kind none of
  these gives is not checked. Assigning to an INTENT(IN) dummy argument (not
  a pointer) is an `intent-in-assigned` error. fortls checks none of these.
- The modules and submodules of the workspace form a dependency graph: a
  USE that closes a cycle of modules using each other is a `circular-use`
  error, and the `zfls/compileOrder` request (the VS Code command "zfls: Show
  Module Compile Order") lists them in an order to compile them, each after
  those it uses, with the cycles. fortls has neither.
- The type hierarchy is answered (`textDocument/prepareTypeHierarchy`,
  `typeHierarchy/supertypes` and `subtypes`), and completion of a component
  offers the parent components of an extended type (`x%feature_base`,
  hansec #121); fortls has neither.
- The call hierarchy is answered (`textDocument/prepareCallHierarchy`,
  `callHierarchy/incomingCalls` and `outgoingCalls`): callers are the
  procedures around the references in call position (after CALL or before
  `(`), callees the procedures that the body's names in call position
  resolve to (the specific of a generic call, the implementation of a
  separate module procedure); fortls has none.
- `textDocument/inlayHint` is answered: the names of the dummy arguments
  that positional arguments of calls to workspace procedures go to (not
  when the argument is that name already, not for intrinsics, not past the
  first keyword argument), and the types of ASSOCIATE names; fortls has
  none.
- `textDocument/selectionRange`, `textDocument/documentLink` and
  `textDocument/prepareRename` (for clients that announce `prepareSupport`)
  are answered; fortls has none of them.
- Construct names and statement labels have definitions, references and
  renames (fortls #424), and `exit`/`cycle` complete the names of the open
  constructs (hansec #157); fortls has no answer on them.
- `workspace/didChangeWatchedFiles` is read: Fortran files created, changed
  or deleted outside the editor (a checkout, generated code) are parsed
  again or dropped, except those open in the editor; fortls ignores it.
- A document that is not a file (an untitled one, `untitled:Untitled-1`) is
  served from the text the client sends with `didOpen` and its changes;
  fortls reads every document from disk.
- `compile_commands.json` and `fpm.toml` add include directories and
  preprocessor definitions (see [Build files](#build-files)).
- Diagnostics have a `code` and the `source` `zfls`, and can be configured
  and suppressed by code (see [Diagnostics](#diagnostics)).
- There is no automatic update from PyPI; `--disable_autoupdate` is accepted
  and ignored.
- The intrinsic documentation in `src/data/intrinsics` is formatted to pass
  markdownlint, so hover texts differ slightly in whitespace.
- `--recursion_limit` limits the nesting depth of scopes, emulating the
  recursion error fortls reports for deeply nested code.
- When several files define the same module, program or procedure name,
  code in one of those files sees its own definition, and other files see
  one definition chosen however the files were loaded or edited: a
  workspace file over an intrinsic module, then the file with the lowest
  path. fortls uses whichever file it parsed last, and parsing either file
  again loses the name until the other is saved again.
- Links that would loop (for example type-bound procedures or `ASSOCIATE`
  names that refer to each other while code is being edited) are left
  unresolved; fortls hits a recursion error on them.
- Go to definition on a preprocessor `#include "file"`, or on a Fortran
  `INCLUDE 'file'` whose file is not in the workspace, opens the file
  (searched next to the including file and in `include_dirs`); fortls has no
  answer.
- An `INCLUDE 'file'` statement is also searched in `include_dirs`, as
  `#include` is; fortls only looks next to the including file.
- A file that another file `#include`s into a scope sees the names of that scope
  (as for `INCLUDE` statements, but also for files that hold whole procedures);
  fortls reports them as unknown in the included file.
- Hover shows the whole value of a parameter. fortls cuts it at the first
  parenthesis or bracket, so `selected_real_kind(6)` shows as
  `selected_real_kind`.
- The `PARAMETER` statement (`parameter (n = 5)`) makes the variables it
  names constants, with their values; fortls ignores it.
- An `ASSOCIATE` name bound to an array element or section shows the
  dimensions of that element or section; fortls shows those of the whole
  array.
- A variable that is declared with a type and then called, `real fff` and
  `fff(1.2, 3.3)`, shows the signature of the global function of that name in
  hover, and an `EXTERNAL` name shows the interface of its procedure and
  has it as its implementation.
- A `!>` documentation comment is dropped at an assignment, a `CALL`, `IMPLICIT`,
  `CONTAINS` or an `END` statement, instead of waiting for the next object.
- A blank line follows a parameter whose documentation ends in a Markdown
  list in hover, so the next parameter is not shown as part of the list.
- References to (and renames of) a separate module procedure include both
  its interface and its implementation in a submodule; fortls does not
  relate the two. With the `prefer_implementation` option, hover shows the
  documentation of that implementation (the interface's when it has none)
  and go to definition goes to it (fortls #501, #502); fortls always uses the
  interface.
- With the `lowercase_hover` option, the keywords of hover are in lowercase
  (`real, intent(in) :: x`), names and strings as written (fortls #28);
  fortls's are always uppercase.
- A rename without `ONLY` (`use m, local => original`) is read: the local
  name is the module's entity and the original name is not visible under
  that name. On the USE line, hover, definition and references on either
  name reach the module's entity (hansec #137); fortls only reads renames
  after `ONLY:` and has no answer on the original name.
- `SUBMODULE (ancestor:parent) name` is named `name` and extends its parent
  submodule (and through it the ancestor module); fortls names it `parent`.
- Of several scopes that open on one line (`do i = 1, n; associate (p => a(i))`),
  the last is the innermost, so the names it declares are found; fortls uses
  the first.
- The lines of an inactive preprocessor branch inside a continued statement
  (`REAL &` / `#ifdef X` / `, POINTER &` / `#endif`) are left out of it; fortls
  joins them, so the declaration gets the attributes of every branch.

## Licenses

zfls is distributed under the MIT license, see `LICENSE`. It is derived from
fortls and its predecessor fortran-language-server, also MIT licensed, whose
copyright notices `LICENSE` includes. The intrinsic procedure documentation
comes from the
[M_intrinsics](https://github.com/urbanjost/M_intrinsics) project via fortls.
