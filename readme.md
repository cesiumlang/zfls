# zfls

A Fortran language server written in Zig. zfls is a native port of
[fortls](https://github.com/fortran-lang/fortls), the Python Fortran language
server, and speaks the same Language Server Protocol subset with the same
command line options and configuration files.

## Features

- Completion, hover, signature help, go to definition and implementation,
  references, document highlights, rename, document and workspace symbols
- Diagnostics: declarations, scopes, `CONTAINS`, `IMPLICIT`, `USE`/`IMPORT`
  checks, line length limits
- Code action implementing deferred type-bound procedures
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
Marketplace for the platforms without their own. No stored token is needed:
Open VSX accepts the workflow's OIDC token (trusted publishing), and for the
Marketplace the workflow signs in with it as a Microsoft Entra managed
identity that is a member of the publisher (the `AZURE_*` repository
variables; the "Marketplace identity" workflow shows the ID to add). The
job falls back to `vsce` trusted publishing and then to the `VSCE_PAT`
repository secret, with a warning.

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

## Testing

| Command | Checks |
| --- | --- |
| `zig build test` | Zig unit tests |
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
every pull request and every push to `main` once, and tests them as release
candidates on Linux, Windows and macOS, each on x86_64 and ARM64: the
suites above, longer stress runs and the differential test.

When a push to `main` passes on every platform, the same archives are
published on the GitHub releases page, the tested commit is tagged, and
CI commits the next patch version to `build.zig.zon`. For a minor or major
release, set the version in `build.zig.zon` by hand. A pull request to
`main` fails its "Version is unreleased" check when it changes anything
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

## Licenses

zfls is distributed under the MIT license, see `LICENSE`. It is derived from
fortls and its predecessor fortran-language-server, also MIT licensed, whose
copyright notices `LICENSE` includes. The intrinsic procedure documentation
comes from the
[M_intrinsics](https://github.com/urbanjost/M_intrinsics) project via fortls.
