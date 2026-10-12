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

The executable is `zig-out/bin/zfls` (`zfls.exe` on Windows).

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
| `zig build test-differential` | every request type against Python fortls (slow) |
| `zig build test-all` | all of the above except the differential run |

The parity and differential tests need a fortls checkout, `../fortls` by
default or `-Dfortls=PATH`, and Python 3 (`-Dpython=EXE`); no third-party
Python packages are required. The oracle test needs `gfortran` on the `PATH`
or in the MSYS2 UCRT64 installation; it is skipped when gfortran is missing.

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

## Licenses

zfls is distributed under the MIT license, see `LICENSE`. It is derived from
fortls and its predecessor fortran-language-server; their licenses are in
`licenses/`. The intrinsic procedure documentation comes from the
[M_intrinsics](https://github.com/urbanjost/M_intrinsics) project via fortls.
