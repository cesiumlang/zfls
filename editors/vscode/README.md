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

The extension includes the `zfls` executable for Windows, Linux and macOS
(x64 and ARM64). Nothing else needs to be installed.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.path` | empty | A `zfls` to run instead of the bundled one |
| `zfls.arguments` | `["--incremental_sync", "--use_signature_help", "--enable_code_actions", "--hover_signature"]` | Command-line arguments; zfls accepts the same options as fortls (`zfls --help`). The default turns on signature help, code actions and signatures in hover, as Modern Fortran does |
| `zfls.disableModernFortranCheck` | `false` | Do not offer to turn off Modern Fortran's fortls |
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

zfls registers the same Fortran language IDs as the
[Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran)
extension, so the two work together. Modern Fortran also starts fortls,
though; when both are installed, zfls offers to turn that off
(`fortran.fortls.disabled`), leaving Modern Fortran's other features, such
as linting with a compiler, in place.

## Commands

- **zfls: Restart Language Server**
- **zfls: Show Output**
