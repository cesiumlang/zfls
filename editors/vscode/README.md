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
| `zfls.disableModernFortranCheck` | `false` | Do not recommend disabling Modern Fortran when both are enabled |
| `zfls.trace.server` | `off` | Log the language server messages in the `zfls` output channel |
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
server (fortls), so with both enabled they compete for Fortran files and
you get duplicate completions, hovers and diagnostics.

When Modern Fortran is enabled, zfls recommends disabling it and opens its
page in the Extensions view, where you select **Disable** (an extension
cannot disable another one), then reload the window.

zfls does not have Modern Fortran's compiler linting and formatting
(findent/fprettify) yet. If you rely on those, you
can choose **Keep it, turn off its fortls** instead: that stops only Modern
Fortran's language server (`fortran.fortls.disabled`), so zfls answers the
language requests while Modern Fortran keeps its other commands. Its
grammars still apply alongside zfls's in that case.

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
