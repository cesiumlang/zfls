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

It replaces the Modern Fortran extension rather than working alongside it:
disable Modern Fortran when you install zfls (see
[Replacing Modern Fortran](#replacing-modern-fortran)).

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

## Replacing Modern Fortran

zfls is a replacement for the
[Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran)
extension, not a companion to it. Both register the same Fortran language
IDs, grammars and snippets, and Modern Fortran starts its own language
server (fortls), so with both enabled they compete for Fortran files and
you get duplicate completions, hovers and diagnostics.

When Modern Fortran is enabled, zfls recommends disabling it and opens its
page in the Extensions view, where you select **Disable** (an extension
cannot disable another one), then reload the window.

zfls does not have Modern Fortran's compiler linting, formatting
(findent/fprettify) and run/debug commands yet. If you rely on those, you
can choose **Keep it, turn off its fortls** instead: that stops only Modern
Fortran's language server (`fortran.fortls.disabled`), so zfls answers the
language requests while Modern Fortran keeps its other commands. Its
grammars still apply alongside zfls's in that case.

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
