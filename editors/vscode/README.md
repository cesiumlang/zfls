# zfls for VS Code

Fortran language support powered by
[zfls](https://github.com/cesiumlang/zfls), a fast native reimplementation
of the [fortls](https://github.com/fortran-lang/fortls) language server:

- completion, hover, signature help
- go to definition and implementation, find references, rename
- document and workspace symbols
- diagnostics, and a compiler's errors and warnings (see
  [Compiler diagnostics](#compiler-diagnostics))
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
server (fortls) and compiler linting, so with both enabled they compete
for Fortran files and you get duplicate completions, hovers and
diagnostics.

When Modern Fortran is enabled, zfls recommends disabling it and opens its
page in the Extensions view, where you select **Disable** (an extension
cannot disable another one), then reload the window.

zfls does not have Modern Fortran's formatting (findent/fprettify) and
run/debug commands yet. If you rely on those, you can choose **Keep it,
turn off its fortls and linter** instead: that stops only Modern Fortran's
language server (`fortran.fortls.disabled`) and its compiler linting
(`fortran.linter.compiler`), so zfls answers the language requests and
shows the compiler's messages while Modern Fortran keeps its other
commands. Its grammars still apply alongside zfls's in that case.

## Compiler diagnostics

When a Fortran file is opened or saved, zfls has a compiler check it
(without generating code) and shows the compiler's errors and warnings in
the file and in the Problems panel, labelled with the compiler's name.
They are cleared when the file is closed or compiler diagnostics are
turned off. By default the compiler is gfortran; if it is not installed,
zfls says so once and checks nothing.

| Compiler (`zfls.linter.compiler`) | Runs | Options zfls passes |
| --- | --- | --- |
| `gfortran` | `gfortran` | `-fsyntax-only -fno-diagnostics-show-caret -cpp -ffree-form`/`-ffixed-form -J<dir>`, and `-Wall` by default |
| `ifx`, `ifort` | `ifx`, `ifort` | `-syntax-only -fpp -free`/`-fixed -module <dir>`, and `-warn all` by default (on Windows `/syntax-only /fpp /free`/`/fixed /module:<dir>`, `/warn:all`) |
| `nagfor` | `nagfor` | `-M -quiet -fpp -free`/`-fixed -mdir <dir> -I <dir>` |
| `lfortran` | `lfortran` | `--semantics-only --error-format=short --cpp`, `--fixed-form` for fixed form, `-J <dir>` |
| `nvfortran` | `nvfortran` | `-c -Mpreprocess -Mfree`/`-Mfixed -module <dir>`, and `-Minform=warn` by default; nvfortran has no syntax-only mode, so it compiles, writing the object file into `<dir>` |
| `flang` | `flang`, else `flang-new` | `-fsyntax-only -cpp -ffree-form`/`-ffixed-form -module-dir <dir>` |
| `Disabled` | | No compiler diagnostics |

Whether a file is free or fixed form follows its language in VS Code
(`FortranFreeForm` or `FortranFixedForm`, from the file extension or
`files.associations`), not the compiler's guess from the extension.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.linter.compiler` | `gfortran` | The compiler, or `Disabled` |
| `zfls.linter.compilerPath` | empty | The compiler executable, when it is not the one on the `PATH` |
| `zfls.linter.extraArgs` | `[]` | Further options, such as `-std=f2018`; when set, they replace the default warning options |
| `zfls.linter.includePaths` | `[]` | Directories for `INCLUDE` and `.mod` files (`-I`); glob patterns such as `${workspaceFolder}/build/**/include` |
| `zfls.linter.modOutput` | empty | Where the compiler writes `.mod` files; empty means a directory in VS Code's storage for the workspace, never the source tree |
| `zfls.linter.lintOnSave` | `true` | Check files when they are saved |
| `zfls.linter.lintOnType` | `false` | Check files while they are edited (a copy of the unsaved text is compiled) |
| `zfls.linter.lintOnTypeDelay` | `1000` | Milliseconds after the last change before such a check |
| `zfls.linter.resolveModules` | `true` | Build the modules a file uses first (see below) |
| `zfls.linter.fypp.enabled` | `false` | Run [fypp](https://fypp.readthedocs.io) on files first; `.fypp` files are only checked with it |
| `zfls.linter.fypp.path` | `fypp` | The fypp executable |
| `zfls.linter.fypp.definitions` | `{}` | fypp definitions (`-DNAME=VALUE`) |
| `zfls.linter.fypp.includes` | `[]` | fypp include directories |
| `zfls.linter.fypp.extraArgs` | `[]` | Further fypp options |

Path settings resolve `${workspaceFolder}`, `${workspaceFolder:name}`,
`${env:VAR}`, `${userHome}`, `${file}`, `${fileDirname}`,
`${fileBasenameNoExtension}` and a leading `~`; relative paths are relative
to the workspace folder.

How it behaves:

- **Modules.** A file that uses a module needs that module's `.mod` file.
  Before checking a file, zfls compiles the workspace files that define the
  modules it uses (those modules' own dependencies first), where their
  `.mod` files are missing or older than the files, and saving a module
  file checks the open files that use it again. Modules that come from
  outside the workspace need their `.mod` directory in
  `zfls.linter.includePaths`. A module whose file does not compile cannot
  be used; the file using it then shows the compiler's error about the
  missing module.
- **Included files.** An error in a file brought in by `INCLUDE` or
  `#include` shows at that `INCLUDE` line, prefixed with the included
  file's name and line, with a link to the place in the included file.
- **One compiler at a time.** Checks run one after another; a check is
  started a moment after the last open, save or edit of a file, and a newer
  check of a file stops the older one and its compiler, so that autosave
  does not pile up compiler processes.
- **No duplicates.** Each message shows once, even if the compiler prints
  it twice.
- **Clearing.** **zfls: Clear Compiler Diagnostics** clears the messages
  and the `.mod` files in VS Code's storage (not those in a configured
  `zfls.linter.modOutput`), and lists `zfls.linter.includePaths` glob
  matches afresh. **zfls: Lint Current File with Compiler** checks the
  active file now.

The command lines and the compiler output are logged in the `zfls` output
channel at the Debug log level (**Developer: Set Log Level...**).

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
- **zfls: Lint Current File with Compiler**
- **zfls: Clear Compiler Diagnostics**
