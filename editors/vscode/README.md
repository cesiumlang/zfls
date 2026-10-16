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
| `zfls.incrementalSync` | `true` | Send document changes incrementally |
| `zfls.signatureHelp` | `true` | Signature help while typing arguments, instead of argument snippets |
| `zfls.codeActions` | `true` | Code actions, such as implementing deferred type-bound procedures |
| `zfls.hoverSignature` | `true` | Procedure signatures in hover |
| `zfls.lowercaseIntrinsics` | `true` | Complete intrinsics and keywords in lowercase |
| `zfls.autocompleteNameOnly` | `false` | Complete procedure names without their arguments |
| `zfls.autocompleteNoSnippets` | `false` | No placeholders in completions |
| `zfls.sortKeywords` | `false` | Sort variable keywords in hover |
| `zfls.symbolSkipMembers` | `false` | Leave type members out of document symbols |
| `zfls.disableDiagnostics` | `false` | Turn off zfls's diagnostics |
| `zfls.notifyInit` | `false` | Notify when the workspace has been indexed |
| `zfls.nthreads` | zfls's (4) | Threads used for indexing |
| `zfls.maxLineLength` | `-1` (off) | Warn about longer code lines |
| `zfls.maxCommentLineLength` | `-1` (off) | Warn about longer comment lines |
| `zfls.configFile` | empty | Configuration file instead of `.fortlsrc` / `.fortls.json` / `.fortls` |
| `zfls.sourceDirs` | the workspace folder | Folders with source files (globs allowed) |
| `zfls.includeDirs` | none | Folders searched for `#include` and `INCLUDE` files |
| `zfls.excludePaths` | none | Folders not to index |
| `zfls.includeSuffixes` | none | More file extensions to index, e.g. `.inc` |
| `zfls.excludeSuffixes` | none | File extensions not to index |
| `zfls.ppSuffixes` | upper-case extensions | File extensions to preprocess |
| `zfls.ppDefs` | none | Preprocessor definitions, name to value |
| `zfls.arguments` | none | Extra command-line options (`zfls --help`) |
| `zfls.disableModernFortranCheck` | `false` | Do not recommend disabling Modern Fortran |
| `zfls.trace.server` | `off` | Log the language server messages in the `zfls` output channel |

Each setting becomes the fortls option of the same meaning (the settings'
descriptions name them). Path settings expand `${workspaceFolder}`,
`${workspaceFolder:name}`, `${userHome}`, `${env:NAME}` and a leading `~`,
and every setting can differ per workspace folder. Changing one restarts the
language server.

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

## Workspaces with several folders

Each top-level folder of a multi-root workspace gets its own zfls, rooted
at that folder and configured by that folder's settings and `.fortlsrc`; a
folder inside another one is part of the outer one. A Fortran file outside
every folder gets a zfls rooted at its own directory.

## Using it with Modern Fortran

zfls registers the same Fortran language IDs as the
[Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran)
extension, so the two work together. Modern Fortran also starts fortls,
though; when both are installed, zfls offers to turn that off
(`fortran.fortls.disabled`), leaving Modern Fortran's other features, such
as linting with a compiler, in place.

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
