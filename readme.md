![zfls logo](logo.svg)

# zfls

A Fortran language server written in Zig. zfls is a native port of [fortls](https://github.com/fortran-lang/fortls), the Python Fortran language server, and speaks the same Language Server Protocol subset with the same command line options and configuration files.

The documentation is at [zfls.cesiumlang.org](https://zfls.cesiumlang.org); its pages are the Markdown files in [`docs/`](docs/index.md).

## What it does

- Completion, hover, signature help, go to definition, implementation and type definition, references, rename, document and workspace symbols, call and type hierarchies, code lenses, inlay hints, folding and semantic highlighting
- Its own diagnostics, each with a code that settings and comments can turn off, and the checks of one compiler's dialect (gfortran, ifx or LLVM Flang)
- A compiler's errors and warnings in the editor (gfortran, ifx, ifort, LLVM Flang, nvfortran, nagfor or LFortran), and the linters fortitude and Codee
- Formatting with its own formatter, findent, fprettify, Codee's or forformat, and conversion between fixed and free form
- Include directories and preprocessor definitions from `compile_commands.json` and `fpm.toml`; the C preprocessor, fypp, OpenMP and Intel conditional compilation
- A build of the open file to run or debug, and a debug adapter, `zfls dap`, that shows a program's variables as Fortran with gdb, lldb-dap or Windows's Debugger Engine
- ifx on Windows without Visual Studio (`zfls setup-ifx`)

[Features](docs/features.md) has the whole list, [Compilers](docs/compilers.md) what depends on the compiler, and [Differences from fortls](docs/fortls.md) where zfls does something else than fortls.

## Getting it

In VS Code, install the extension `cesiumlang.zfls` from the [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=cesiumlang.zfls) or [Open VSX](https://open-vsx.org/extension/cesiumlang/zfls); it includes zfls.

For other editors, each [release](https://github.com/cesiumlang/zfls/releases) has the `zfls` executable for Linux, macOS and Windows, each on x86_64 and ARM64, and it needs nothing else. On macOS and Linux, or in Git Bash, MSYS2 or Cygwin on Windows:

```sh
curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh
```

In PowerShell on Windows:

```powershell
irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1 | iex
```

[Installing](docs/installing.md) has the options, the macOS package and how to verify a release; [Editors](docs/editors.md) how to start zfls from Neovim, Helix, Emacs, Sublime Text, Kate and Zed; [Configuration](docs/configuration.md) the `.zflsrc` file.

## Building

zfls needs Zig 0.17.1.

```sh
git clone --recurse-submodules <repository>
cd zfls
zig build -Doptimize=fast
```

The executable is `zig-out/bin/zfls` (`zfls.exe` on Windows). See [Building](docs/building.md), [Testing](docs/testing.md) and [Releases](docs/releases.md).

## Licenses

zfls is distributed under the MIT license, see `LICENSE`; the ifx kit's startup code is under MIT No Attribution (MIT-0). [Licenses](docs/licenses.md) has the details and the sources zfls is derived from.
