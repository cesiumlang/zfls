# zfls for VS Code

Fortran language support powered by
[zfls](https://github.com/cesiumlang/zfls), a fast native reimplementation
of the [fortls](https://github.com/fortran-lang/fortls) language server:

- completion, hover, signature help
- go to definition and implementation, find references, rename
- document and workspace symbols
- diagnostics
- syntax highlighting for free-form and fixed-form Fortran, with OpenMP and
  OpenACC directives
- snippets for program units and constructs (see [Snippets](#snippets))
- breakpoints in Fortran files, for debuggers such as C/C++ (cppdbg,
  cppvsdbg) and CodeLLDB
- a Fortran file icon, in file icon themes that use the language's icon

The extension includes the `zfls` executable for Windows, Linux and macOS
(x64 and ARM64). Nothing else needs to be installed.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.path` | empty | A `zfls` to run instead of the bundled one |
| `zfls.arguments` | `["--incremental_sync", "--use_signature_help", "--enable_code_actions", "--hover_signature"]` | Command-line arguments; zfls accepts the same options as fortls (`zfls --help`). The default turns on signature help, code actions and signatures in hover, as Modern Fortran does |
| `zfls.disableModernFortranCheck` | `false` | Do not recommend disabling Modern Fortran when both are enabled |
| `zfls.trace.server` | `off` | Log the language server messages in the `zfls` output channel |

As with fortls, a `.fortlsrc`, `.fortls.json` or `.fortls` file in the
workspace root configures source directories, preprocessor definitions and
other options.
VS Code opens these files as JSON with comments and checks them against a
schema of the options zfls reads from them, with their descriptions and
defaults in completion and hover. The schema is generated from zfls's option
table (`tools/gen_config_schema.py`).

With a TOML extension that supports `tomlValidation`, such as
[Even Better TOML](https://marketplace.visualstudio.com/items?itemName=tamasfe.even-better-toml),
`fpm.toml` files are checked against the
[fpm manifest schema](https://github.com/fortran-lang/fpm-metadata) too.

## Using it with Modern Fortran

zfls replaces the
[Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran)
extension: it registers the same Fortran language IDs, grammars and
snippets, and its own language server instead of fortls. With both enabled
they compete for Fortran files, so when Modern Fortran is enabled zfls
recommends disabling it and opens its page in the Extensions view (an
extension cannot disable another one). zfls does not yet have Modern
Fortran's compiler linting, formatting and run/debug commands; to keep those
for now, choose "Keep it, turn off its fortls", which only stops Modern
Fortran's language server (`fortran.fortls.disabled`).

## Snippets

Type a prefix and pick the snippet from the completion list:

| Prefix | Inserts |
| --- | --- |
| `program`, `module`, `submodule` | A program unit with `implicit none` |
| `fun`, `sub` | A function with a result variable, a subroutine |
| `interface`, `abstract` | An interface block, an abstract interface |
| `typ`, `typc`, `proc` | A derived type with `contains`, a type with a type-bound procedure, a type-bound procedure binding |
| `if`, `ife`, `el`, `else` | A one-line `if`, an `if` block, an `if`/`else` block, `else if` and `else` branches |
| `do`, `dow`, `doc` | `do`, `do while` and `do concurrent` loops |
| `selc`, `selt` | `select case`, `select type` |
| `block`, `associate`, `where`, `enum` | Those constructs |
| `imp` | `implicit none` |
| `modoc` | A module documentation header |

The fixed-form snippets indent with spaces and keep every line at the
column where the prefix was typed, so type the prefix at column 7 or later.
Most snippets are adapted from those of Modern Fortran.

## Commands

- **zfls: Restart Language Server**
- **zfls: Show Output**
