# zfls for VS Code

Fortran language support powered by
[zfls](https://github.com/cesiumlang/zfls), a fast native reimplementation
of the [fortls](https://github.com/fortran-lang/fortls) language server:

- completion, hover, signature help
- go to definition and implementation, find references, rename
- document and workspace symbols, with an outline tree for breadcrumbs and
  sticky scroll
- folding of program units, constructs (each `IF`, `SELECT` and `WHERE`
  branch on its own), preprocessor conditionals and comment blocks
- semantic highlighting: names colored by what they stand for (procedures,
  types, dummy arguments, components, variables named like keywords), and
  the branches of preprocessor conditionals that are left out shown as
  inactive
- untitled (new, unsaved) Fortran files too, served by the first folder's
  server
- Fortran files changed outside VS Code (a checkout, generated code) are
  indexed again; the server restarts when `.fortlsrc`, `.fortls.json`,
  `.fortls`, `fpm.toml` or `compile_commands.json` changes
- diagnostics, and a compiler's errors and warnings (see
  [Compiler diagnostics](#compiler-diagnostics))
- syntax highlighting for free-form and fixed-form Fortran, with OpenMP and
  OpenACC directives
- snippets for program units and constructs (see [Snippets](#snippets))
- formatting of documents and selections with findent or fprettify (see
  [Formatting](#formatting))
- breakpoints in Fortran files, for debuggers such as C/C++ (cppdbg,
  cppvsdbg) and CodeLLDB
- run and debug the current file with one click (see
  [Running and debugging](#running-and-debugging))
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
| `zfls.incrementalSync` | `true` | Send document changes incrementally |
| `zfls.signatureHelp` | `true` | Signature help while typing arguments, instead of argument snippets |
| `zfls.codeActions` | `true` | Code actions, such as implementing deferred type-bound procedures |
| `zfls.hoverSignature` | `true` | Procedure signatures in hover |
| `zfls.preferImplementation` | `false` | Hover and go to definition use a separate module procedure's body in its submodule, not its interface |
| `zfls.lowercaseIntrinsics` | `true` | Complete intrinsics and keywords in lowercase |
| `zfls.autocompleteNameOnly` | `false` | Complete procedure names without their arguments |
| `zfls.autocompleteNoSnippets` | `false` | No placeholders in completions |
| `zfls.autocompleteNoAutoUse` | `false` | Do not offer names of modules not used yet (completing one adds its `use` statement) |
| `zfls.sortKeywords` | `false` | Sort variable keywords in hover |
| `zfls.symbolSkipMembers` | `false` | Leave type members out of document symbols |
| `zfls.disableDiagnostics` | `false` | Turn off zfls's diagnostics |
| `zfls.diagnosticSeverity` | none | Severity of diagnostics by code, `off` to hide them |
| `zfls.externalModules` | none | Modules from outside the project (MPI, ...) that `USE` may name |
| `zfls.notifyInit` | `false` | Notify when the workspace has been indexed |
| `zfls.nthreads` | zfls's (4) | Threads used for indexing |
| `zfls.maxLineLength` | `-1` (off) | Warn about longer code lines |
| `zfls.maxCommentLineLength` | `-1` (off) | Warn about longer comment lines |
| `zfls.configFile` | empty | Configuration file instead of `.fortlsrc` / `.fortls.json` / `.fortls` |
| `zfls.sourceDirs` | the workspace folder | Folders with source files (globs allowed) |
| `zfls.includeDirs` | none | Folders searched for `#include` and `INCLUDE` files |
| `zfls.compileCommands` | `compile_commands.json` in the folder or `build/` | Compilation database adding include folders and definitions |
| `zfls.excludePaths` | none | Folders not to index |
| `zfls.includeSuffixes` | none | More file extensions to index, e.g. `.inc` |
| `zfls.excludeSuffixes` | none | File extensions not to index |
| `zfls.ppSuffixes` | upper-case extensions | File extensions to preprocess |
| `zfls.ppDefs` | none | Preprocessor definitions, name to value |
| `zfls.arguments` | none | Extra command-line options (`zfls --help`) |
| `zfls.disableModernFortranCheck` | `false` | Do not recommend disabling Modern Fortran when both are enabled |
| `zfls.trace.server` | `off` | Log the language server messages in the `zfls` output channel |
| `zfls.formatting.formatter` | `Disabled` | `findent` or `fprettify` to format Fortran files (see [Formatting](#formatting)) |
| `zfls.formatting.path` | empty | The formatter, or its directory, when it is not on the `PATH` |
| `zfls.formatting.findentArgs` | `[]` | Extra arguments for findent |
| `zfls.formatting.fprettifyArgs` | `[]` | Extra arguments for fprettify |
| `zfls.run.*` | | Compiler, arguments and debugger for running and debugging a file (see [Running and debugging](#running-and-debugging)) |

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

If you want to keep Modern Fortran installed for now, you can choose
**Keep it, turn off its fortls and linter** instead: that stops only
Modern Fortran's
language server (`fortran.fortls.disabled`) and its compiler linting
(`fortran.linter.compiler`), so zfls answers the language requests and
shows the compiler's messages while Modern Fortran keeps its other
commands. Its grammars still apply alongside zfls's in that case.

## Compiler diagnostics

When a Fortran file is opened or saved, zfls has a compiler check it
(without generating code) and shows the compiler's errors and warnings in
the file and in the Problems panel, labelled with the compiler's name.
They are cleared when the file is closed or compiler diagnostics are
turned off. By default, the compiler is gfortran; if it is not installed,
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

## Formatting

**Format Document**, **Format Selection** and format on save
(`editor.formatOnSave`) use an external formatter, which must be installed
separately:

| Formatter | Install | Formats |
| --- | --- | --- |
| [findent](https://pypi.org/project/findent/) | `pip install findent` or `conda install -c conda-forge findent` | Indentation of free-form and fixed-form files |
| [fprettify](https://github.com/fortran-lang/fprettify) | `pip install fprettify` or `conda install -c conda-forge fprettify` | Indentation, whitespace and more, free-form files only |

Choose one with `zfls.formatting.formatter`; it is `Disabled` by default, so
that no formatter runs, and VS Code offers formatters of other extensions,
until one is chosen. The setting can differ per language, for example
fprettify for free form and findent for fixed form:

```jsonc
"zfls.formatting.formatter": "fprettify",
"[FortranFixedForm]": {
  "zfls.formatting.formatter": "findent"
}
```

The extension sends the text to the formatter on its standard input and
reads the result from its standard output, so no files are written, and
changes only the lines the formatter changed. findent is told the source
form of the file (`-ifree` or `-ifixed`) unless `zfls.formatting.findentArgs`
sets one. fprettify reads `.fprettify.rc` files from the directory of the
file and its parents, as when it formats the file itself. Changes to these
settings apply to the next formatting, without a restart. In
`zfls.formatting.path` and the argument settings, `${workspaceFolder}`,
`${workspaceFolder:name}`, `${userHome}`, `${env:NAME}`, `${file}`,
`${fileDirname}` and a leading `~` are expanded.

**Format Selection** formats the whole lines the selection touches. The
formatter sees only those lines, not the surrounding code: findent starts
at the indentation of the first selected line (`-Ia`), and fprettify keeps
it too, but select whole constructs (a complete `do` loop, `if` block or
procedure) for the indentation inside them to come out right.

When the formatter is missing, fails, or prints nothing, the document is
left as it is, and the error is shown once, with details in the `zfls`
output channel (**zfls: Show Output**).

## Running and debugging

The **Run Fortran File** and **Debug Fortran File** buttons in the editor
title (also commands, **zfls: Run Fortran File** and **zfls: Debug Fortran
File**) build the file in the editor, saving it first, and then run it in a
terminal, or start the debugger on it. Programs of a single file are the
aim: the directory of the file is on the include path, but other source
files are not compiled. For a project, use a build system and a launch
configuration of your own.

The build uses `zfls.run.compiler` (`gfortran` by default) with debug
information and no optimization. The program and the compiler's module and
object files go into the extension's storage, a directory per source file,
not next to the sources, unless `zfls.run.outputDirectory` says where. On
Windows the compiler's directory is put first on the program's `PATH`, for
its runtime libraries.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.run.compiler` | `gfortran` | The compiler: `gfortran`, `ifx`, `ifort`, `flang`, `nvfortran`, `nagfor`, `lfortran`, ... |
| `zfls.run.compilerPath` | empty | The compiler, or its directory, when it is not on the `PATH` |
| `zfls.run.buildArgs` | not set | Compiler arguments; not set: `-g -O0` (`/Zi /Od` for `ifx` and `ifort` on Windows, `-g` for `lfortran`). The extension adds the include path, the output file and the source |
| `zfls.run.outputDirectory` | empty | Where the program and the module files go |
| `zfls.run.programArgs` | `[]` | Arguments for the program |
| `zfls.run.cwd` | `${fileDirname}` | The working directory of the program |
| `zfls.run.debugger` | `auto` | `cppdbg`, `cppvsdbg`, `lldb` or `gdb`; `auto` picks an installed one |
| `zfls.run.gdbPath` | empty | The `gdb` for `cppdbg` and `gdb`; empty: the one next to the compiler, else on the `PATH` |

`${workspaceFolder}`, `${env:NAME}`, `${userHome}`, `${file}`,
`${fileDirname}` and a leading `~` are expanded in these settings.

No debugger comes with the extension; debugging uses one of these
extensions, the first installed one with `zfls.run.debugger` set to `auto`:

| Extension | Debugger | For |
| --- | --- | --- |
| [C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools) | `cppdbg` | gdb (lldb on macOS): gfortran, Intel on Linux, flang, ... |
| [C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools) | `cppvsdbg` | The Visual Studio debugger: `ifx`, `ifort` and LLVM Flang on Windows, whose programs only it can debug |
| [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb) | `lldb` | lldb |
| [CDT GDB Debug Adapter](https://marketplace.visualstudio.com/items?itemName=eclipse-cdt.cdt-gdb-vscode) | `gdb` | gdb |

If none is installed, **Debug Fortran File** says which to install. With
Intel's compilers on Windows, start VS Code from a oneAPI command prompt (or
after `setvars.bat`), so that the compiler finds the linker and libraries.

**zfls: Add Build Task and Debug Configuration for Fortran File** writes
the same build as a task in `.vscode/tasks.json` and a debug configuration
that builds first in `.vscode/launch.json`, replacing those of the same
name, for starting it with F5 and changing it to suit.

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
- **zfls: Run Fortran File**, **zfls: Debug Fortran File** (also buttons in
  the editor title)
- **zfls: Add Build Task and Debug Configuration for Fortran File**
- **zfls: Lint Current File with Compiler**
- **zfls: Clear Compiler Diagnostics**
