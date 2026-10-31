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
- Code action implementing deferred type-bound procedures
- Include directories and preprocessor definitions from the project's
  `compile_commands.json` (CMake, Meson, Bear) and `fpm.toml` (see
  [Build files](#build-files))
- Fixed and free source form, line continuations, Doxygen and FORD style
  documentation comments
- C preprocessor support (`#if`/`#ifdef`/`#elif`, object and function-like
  macros, `#include`)
- Documentation for intrinsic procedures, statements, keywords and the
  intrinsic modules (`iso_fortran_env`, OpenMP, OpenACC, ...)

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

### Diagnostics

Each diagnostic has a code (shown by editors, e.g. in the VS Code Problems
panel): `line-too-long`, `comment-too-long`, `statement-without-scope`,
`multiple-contains`, `unexpected-end`, `invalid-parent`,
`procedure-before-contains`, `declared-twice`, `masks-parent`,
`import-outside-interface`, `module-not-found`, `use-after-implicit`,
`deferred-not-implemented`, `intent-not-in-arguments`,
`argument-not-declared`, `not-imported` and `object-not-found`.

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
