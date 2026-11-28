# zfls

zfls is a Fortran language server written in Zig: one native program, for Linux, macOS and Windows, that gives an editor completion, hover, go to definition, references, rename, diagnostics, formatting and more for Fortran, and a debug adapter that shows a program's variables as Fortran. It is a port of [fortls](https://github.com/fortran-lang/fortls), the Python Fortran language server, and takes the same command line options and configuration files.

zfls parses the code itself, so it works on any Fortran source, whatever compiler builds it. Where a compiler is installed, zfls can also run it: its errors and warnings beside zfls's own, and a build of the open file to run or debug.

## Getting it

- In VS Code, install the extension `cesiumlang.zfls` from the [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=cesiumlang.zfls) or [Open VSX](https://open-vsx.org/extension/cesiumlang/zfls). It includes zfls.
- For another editor, get the `zfls` program from a [release](https://github.com/cesiumlang/zfls/releases) or with the installation scripts ([Installing](installing.md)), and tell the editor to start it ([Editors](editors.md)).

zfls needs no configuration to start. A project's options go in a `.zflsrc` at its root ([Configuration](configuration.md)).

## The documentation

| Page | What it covers |
| --- | --- |
| [Installing](installing.md) | The release archives, the installation scripts, the macOS package, and checking a download. |
| [Editors](editors.md) | Starting zfls from Neovim, Helix, Emacs, Sublime Text, Kate and Zed. |
| [Configuration](configuration.md) | The configuration files, the user's defaults, settings sent by the editor, and which wins. |
| [Features](features.md) | Everything zfls does, in one list. |
| [Compilers](compilers.md) | What works with gfortran, ifx, ifort, LLVM Flang, nvfortran, nagfor and LFortran. |
| [Diagnostics and dialects](diagnostics.md) | zfls's own checks, their codes, turning them off, and the checks of one compiler's dialect. |
| [The compiler check and linters](compiler-check.md) | A compiler's errors and warnings in the editor, fortitude and Codee. |
| [Formatting and the source form](formatting.md) | zfls's formatter and the external ones, fixed and free form, and converting between them. |
| [Reading the source](source.md) | Comment markers, OpenMP conditional compilation, debug lines, Intel's conditional compilation. |
| [Build files and C](build-files.md) | `compile_commands.json`, `fpm.toml`, module files, and procedures bound to C. |
| [Building a file to run or debug](running.md) | The build zfls answers for any editor (`zfls/buildCommand`). |
| [Debugging](debugging.md) | `zfls dap`, with gdb, lldb-dap or Windows's Debugger Engine; module variables and inline values. |
| [ifx without Visual Studio](ifx-kit.md) | `zfls setup-ifx` and the ifx kit, which also links LLVM Flang's and LFortran's programs on Windows. |
| [fpm targets and tests](tests.md) | The requests an editor's tasks and test explorer are built on. |
| [Start-up time and memory](performance.md) | The index cache, and what zfls keeps of the files that are not open. |
| [Differences from fortls](fortls.md) | Where zfls deliberately does something else, or more. |

For those working on zfls itself: [Building](building.md), [Testing](testing.md), [Releases](releases.md) and [Licenses](licenses.md).
