![zfls logo](logo.svg)

# zfls

A Fortran language server written in Zig. zfls is a native port of [fortls](https://github.com/fortran-lang/fortls), the Python Fortran language server, and speaks the same Language Server Protocol subset with the same command line options and configuration files.

## Features

- Completion, hover, signature help, go to definition, implementation and type definition, references, document highlights, rename, document and workspace symbols
- Beyond fortls: an outline tree of document symbols (for clients that take one: breadcrumbs, sticky scroll); folding of program units, constructs and their branches, statements continued over three lines or more, preprocessor conditionals and comment blocks; semantic highlighting of modules, types, procedures, dummy arguments, components and variables by what they are (a variable named `if` is a variable), with the lines that preprocessor conditionals leave out shown inactive, for the whole file or the lines on screen
- Diagnostics: declarations, scopes, `CONTAINS`, `IMPLICIT`, `USE`/`IMPORT` checks, line length limits; each with a code that settings and comments can turn off (see [Diagnostics](#diagnostics))
- Construct names (`outer: do` ... `exit outer`) and statement labels (`go to 10`, `read (5, 100)`): go to definition, references, rename, and completion after `exit` and `cycle`
- Completion of keyword arguments inside a call (`call move(p, dx=`): the dummy arguments of the procedure, of each procedure of a generic interface, of an intrinsic, or the components of a structure constructor
- Completion of the public names of modules not used yet, adding the `use module, only: name` statement, and a quick fix adding it for a type that is not found
- Code lenses: the number of references above each module, procedure and derived type, counted when the editor shows the lens (`code_lens_no_references` turns them off), and Run and Debug above a program (`code_lens_no_run`). Clicking runs a command of the client's: zfls names `zfls.showReferences` (URI, position, locations), `zfls.runFile` and `zfls.debugFile` (URI) where the client lists them in its `experimental.commands.commands` capability, as the VS Code extension does; elsewhere a reference lens only shows the count, and a program has none
- Call hierarchy: the procedures that call a procedure, and those it calls
- Type hierarchy: the type a derived type extends, and the types that extend it; completion offers the parent components of an extended type
- Inlay hints: the dummy argument each positional argument of a call goes to (`call move(p, dx: 1.0)`), the type of each `ASSOCIATE` name, the implicit type of each name that is not declared, and the value of a named constant where it is used
- Selection ranges (expand the selection from a name to its parentheses, statement, constructs, procedure, module and file), links on the files of `#include` and `INCLUDE`, and a rename check that refuses intrinsics and keywords before a new name is typed
- Code actions: implementing deferred type-bound procedures, adding `IMPLICIT NONE`, writing `.eq.` ... `.ge.` as `==` ... `>=` and `real*8` as `real(8)`, extracting statements into a subroutine, and (Source Actions) the keywords of a file in upper, lower or title case
- Formatting of documents and selections with findent, fprettify, Codee's formatter, forformat or a command of the user's (see [Formatting](#formatting)), and conversion of a file between fixed and free form with findent (see [Converting the source form](#converting-the-source-form))
- Include directories and preprocessor definitions from the project's `compile_commands.json` (CMake, Meson, Bear) and `fpm.toml` (see [Build files](#build-files))
- Fixed and free source form (also switched within a file by LLVM Flang's `!dir$ fixed` and `!dir$ free`, and ifx's `!DEC$ NOFREEFORM` and `!DEC$ FREEFORM`), line continuations, Doxygen and FORD style documentation comments, OpenMP conditional compilation lines (`!$ x = 1`) read as code (see [OpenMP conditional compilation](#openmp-conditional-compilation))
- Sources indexed by default by their extension, in either case: `.f90`, `.f95`, `.f03`, `.f05`, `.f08`, `.f18`, `.f23`, `.cuf`, `.pf` (pFUnit), `.fypp` and `.fpp`, and in fixed form `.f`, `.f77`, `.for`, `.ftn` (`incl_suffixes` adds more); one table (`src/suffixes.zig`) decides the source form, the Fortran entries of `compile_commands.json` and the VS Code extension's file associations
- DEC extensions: `STRUCTURE` (nested too), `RECORD`, `UNION`/`MAP`, and `.` between a variable and its component (`rec.field`)
- CUDA Fortran: `attributes(global)` and `attributes(device)` procedures, signature help in a kernel launch (`call k<<<grid, block>>>(...)`), `.cuf` files
- Namelist files (`.nml`, `.namelist`, or a document the client opens with the language `FortranNamelist`): an outline of their groups and the variables each sets; they are never parsed as Fortran nor diagnosed
- C preprocessor support (`#if`/`#ifdef`/`#elif`, also with Fortran's operators as Intel's fpp and LLVM Flang take them, `#if N .gt. 5 .and. .not. defined(X)`, except what the compiler check's compiler rejects: with ifx or ifort a `/=` is fpp's `#if: parse error.` and the branch is taken, with gfortran any Fortran operator is cpp's `token '/=' is not valid in preprocessor expressions` (or `token '.'`) and the branch is not taken, each a `preprocessor-condition` error; object and function-like macros, `#include`; `__LINE__`, `__FILE__`, `__DATE__` and `__TIME__`; the macros the compiler check's gfortran, ifx or ifort predefines, `__GFORTRAN__`, `__GNUC__`, `__INTEL_LLVM_COMPILER`, `_WIN32` ..., asked of it once, and again when its file changes, `pp_defs` winning over them; gfortran predefines no target macros such as `_WIN32` or `__x86_64__` on MinGW), and Intel's conditional compilation directives (`!DEC$ IF DEFINED (X)`, `!DIR$ IF (expr)`; see [Intel conditional compilation](#intel-conditional-compilation)); go to definition of a macro goes to the `#define` in effect at the use, in the file or a header, and references and highlights list its uses and the directives that name it
- Documentation for intrinsic procedures (with the specific names, such as `DSQRT` and `DCMPLX`, and those of Fortran 2018 and 2023), statements, keywords and the intrinsic modules (`iso_fortran_env`, OpenMP, OpenACC, ...); stubs of the MPI modules `mpi` and `mpi_f08`
- Compiler diagnostics from gfortran, ifx, ifort, LLVM Flang, nvfortran, nagfor or LFortran, next to zfls's own, and the linters fortitude and Codee (see [Compiler diagnostics](#compiler-diagnostics) and [Linters](#linters))
- A debug adapter, `zfls dap`, that shows a program's variables as Fortran (see [A debugger](#a-debugger-zfls-dap)), and for a debugger of any kind the module variables a line sees, inline values and the tests of a file

What depends on the compiler is in [Compilers](#compilers).

## Compilers

Everything above works on any Fortran source, whatever compiler builds it: zfls parses the code itself. A compiler comes in where zfls runs one (the compiler check, running a file) or reads what one wrote (a program under the debugger), and where the source is in a compiler's own dialect.

✓ is supported; ○ is implemented but not tested with that compiler (see [what is tested](#what-is-tested-with-a-real-compiler)); – is not available.

### The compiler check

`compiler_diagnostics` (see [Compiler diagnostics](#compiler-diagnostics)).

| | gfortran | ifx | ifort | flang | nvfortran | nagfor | lfortran |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Errors and warnings as diagnostics | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Without building (syntax only) | ✓ | ✓ | ✓ | ✓ | –¹ | ✓ | ✓ |
| Modules the file uses compiled first | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓² |
| The file's own command of `compile_commands.json` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Options by default: warnings, coarrays, OpenMP ([`compiler_args`](#compiler-diagnostics)) | `-Wall -fcoarray=single -fopenmp` | `-warn all,nodeclarations,noexternals -coarray=single -qopenmp` | `-warn all,nodeclarations,noexternals -coarray=single -qopenmp` | `-Wunused-variable -Wused-undefined-variable`⁴ `-fopenmp` | `-Minform=warn` | – | – |
| Preprocessed files | `-cpp` | `-fpp` | `-fpp` | `-cpp` | `-Mpreprocess` | `-fpp` | `--cpp` |
| Fixed-form line length (`fixed_line_length`) | any | 72, 80, 132 | 72, 80, 132 | any | 132 | 132 | – |
| Debug lines as zfls reads them (`d_lines`) | ✓ | ✓ | ✓ | ✓⁴ | ✓ | as code | – |
| Every error, not only the first | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓³ |
| Messages without a file and line | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

1. nvfortran has no syntax-only mode: it compiles the file, with the object file in zfls's cache.
2. LFortran's syntax-only mode writes no `.mod` file: the modules are compiled to their symbol tables (`--symtab-only -c`).
3. With `--continue-compilation`. zfls also passes LFortran `--implicit-typing --implicit-interface`, which its own dialect rejects, unless the options say otherwise.
4. LLVM Flang 22 and later, whose version zfls asks of it once (`flang --version`), and again when the executable's file changes; Flang 21 knows neither option, Flang 20 has only `-Werror`, and `-Wall` is none of Flang's, so older Flang get no warnings by default. Flang reads debug lines as comments by default; as code (`-fd-lines-as-code`) needs Flang 21 or later, and zfls passes Flang 20 no option, which then reads them as comments.

### Compiler dialects in the source

The parser reads these in every file, whichever compiler is configured; the columns say whose dialect each is.

| | gfortran | ifx | ifort | flang | nvfortran | nagfor | lfortran |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| `STRUCTURE`, `RECORD`, `UNION`/`MAP`, `rec.field` (DEC) | ✓⁵ | ✓ | ✓ | ✓⁶ | ✓ | – | – |
| [Conditional compilation in directives](#intel-conditional-compilation) (`!DEC$ IF`, `!DIR$ IF`) | – | ✓ | ✓ | – | – | – | – |
| Generated interface modules (`<name>__genmod.f90`) left out of the index | – | ✓ | ✓ | – | – | – | – |
| CUDA Fortran (`attributes(device)`, `call k<<<g, b>>>(...)`, `.cuf`) | – | – | – | ✓ | ✓ | – | – |
| `!DIR$ IGNORE_TKR`: no argument checks for the dummy arguments it names | – | – | – | ✓ | ✓ | – | – |
| `!GCC$ ATTRIBUTES NO_ARG_CHECK` (gfortran), `!DIR$ ATTRIBUTES NO_ARG_CHECK` (Intel): no argument checks for the dummy arguments it names | ✓ | ✓ | ✓ | – | – | – | – |
| `!DIR$ FIXED`, `!DIR$ FREE`: the source form of the lines after them | – | – | – | ✓ | – | – | – |
| `!DEC$ NOFREEFORM`, `!DEC$ FREEFORM` (also `!DIR$`): the source form of the lines after them | – | ✓ | ✓ | – | – | – | – |
| `!DEC$ REAL:n`, `!DEC$ INTEGER:n`: the default kind of the next program unit, in the argument checks | – | ✓ | ✓ | – | – | – | – |
| `!DEC$ FIXEDFORMLINESIZE:n` (also `!DIR$`): the line length of the fixed-form lines after it, in place of `fixed_line_length` | – | ✓ | ✓ | – | – | – | – |
| [Debug lines](#debug-lines) (`D` in column 1 of fixed form) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| `AUTOMATIC` and `STATIC` (DEC) statements and attributes (gfortran's with `-fdec-static`) | ✓ | ✓ | ✓ | – | – | – | – |
| `VIRTUAL` (DEC's `DIMENSION`), `PARAMETER` without parentheses (`PARAMETER N = 10`, of the type of its value) | – | ✓ | ✓ | – | – | – | – |
| `UNSIGNED` (`unsigned(kind=8)`, `42u`, `SELECTED_UNSIGNED_KIND`, `UINT`; with `-funsigned`, gfortran's from GCC 15) | ✓ | – | – | ✓ | – | – | ○ |
| `$` in names, also first (`subroutine $$lib$random`; gfortran's with `-fdollar-ok`, after the first character) | ✓ | ✓ | ✓ | ✓ | – | – | – |
| DEC's I/O statements: `ENCODE`, `DECODE`, `ACCEPT`, `DEFINE FILE`, `FIND`, the record of `READ (u'r)` | – | ✓ | ✓ | – | – | – | – |
| TAB-format fixed form (DEC): a TAB in columns 1 to 6 stands for them, a nonzero digit after it marks a continuation line | ✓ | ✓ | ✓ | ✓ | ○ | ○ | ○ |

5. gfortran's with `-fdec-structure`.
6. LLVM Flang's without `UNION` and `MAP`, which it has not implemented.

Not a compiler's own, and read for all of them: the C preprocessor, fypp files, OpenMP conditional compilation lines, kinds written with `*` (`real*8`), `BYTE`, old-style initial values (`integer :: k /3/`), Cray pointers (`pointer (p, b)`), and comment markers of other preprocessors ([Comment markers](#comment-markers)).

### Running and debugging

Run Fortran File and Debug Fortran File are the VS Code extension's, with the build zfls answers for any editor (see [Building a file to run or debug](#building-a-file-to-run-or-debug-zflsbuildcommand)); `zfls dap` is for any editor (see [A debugger](#a-debugger-zfls-dap)).

| | gfortran | ifx | ifort | flang | nvfortran | nagfor | lfortran |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Run Fortran File | ✓ | ✓ | ✓ | ✓ | ○ | ○ | ✓ |
| Links on Windows without Visual Studio | ✓⁷ | ✓⁸ | – | ✓⁸ | – | – | ✓⁸ |
| `zfls dap` on Linux | gdb ✓ | gdb ○ | gdb ○ | gdb ✓ | gdb ○ | gdb ○ | gdb ✓⁹ |
| `zfls dap` on Windows | gdb ✓ | Windows's ✓¹⁰ | Windows's ○ | gdb ✓, Windows's ✓¹² | – | gdb ○ | –⁹ |
| `zfls dap` on macOS | lldb-dap ✓¹¹ | – | lldb-dap ○¹¹ | lldb-dap ○¹¹ | – | lldb-dap ○¹¹ | lldb-dap ✓⁹ |
| Variables as Fortran (arrays, derived types, CHARACTER, module variables) | ✓ | ✓¹⁰ | ○ | ✓¹² | ○ | ○ | –⁹ |
| Stops at Fortran runtime errors and ERROR STOP | ✓ | ✓ | ○ | ✓¹² | ○ | ○ | ✓⁹ |

7. MinGW's gfortran needs none.
8. With zfls's ifx kit (and for ifx `zfls setup-ifx`), on Windows x64 (see [ifx without Visual Studio](#ifx-without-visual-studio-windows-x64)).
9. Programs built with `lfortran -g` (which runs `llvm-dwarfdump` and Python: build with LFortran's environment on the `PATH`; conda-forge's LFortran for Linux needs `llvm-tools` beside it), tested in CI with gdb on Linux x64 and lldb-dap on macOS x64: breakpoints, stepping, the stack, the stops at LFortran's runtime errors (a bound exceeded, which it checks by default) and at ERROR STOP, not at STOP. LFortran's debug information (LFortran 0.69) says its language is C and has integer and real scalars only, which the Variables view shows (without the compiler's temporaries, with lldb-dap too); arrays, derived types, CHARACTER lengths and module variables are not in it, and there is no module variables scope. LFortran 0.69's ERROR STOP in a `-g` program aborts on macOS before its runtime is called ("The stack address was not found"), so it stops there as a signal; and on Apple Silicon the stop at ERROR STOP is left out (the string that tells it from STOP is on the stack there, untested). LFortran for Windows refuses `-g`.
10. Windows's Debugger Engine (`"dbgeng": true`), for debug information of Microsoft's format; arrays are read through Intel's descriptors and LLVM Flang's. CI tests the engine on C programs (also a break instruction of the program's own, which stops as an exception, as the Intel runtime's at a runtime error does once), on LLVM Flang's built with `-g`, and on ifx 2026's built with `/Zi` (conda-forge's, linked with zfls's ifx kit): breakpoints, `stopAtEntry`, the stack, stepping, the variables, and the stops at a runtime error and at ERROR STOP (ifx's `for_error_stop_quiet`), not at STOP. The variables include a polymorphic object or array with its dynamic type's components (Flang's and ifx's), a module's variables by their own names in an expression (`ncells`, `grid::ncells`) and those of its COMMON blocks, and REAL(16) values.
11. lldb-dap (Xcode's command line tools), since gdb does not run on Apple Silicon and every user must code-sign it on an Intel Mac: breakpoints, stepping, the stack and the stops at runtime errors and ERROR STOP, but lldb has no Fortran support for variables and expressions, so the Variables view of these programs is empty (the row of variables is gdb's).
12. LLVM Flang's `-g` on Windows writes debug information of Microsoft's format only, with which Windows's engine has breakpoints, the stack, stepping, the variables (arrays through Flang's descriptors, a polymorphic object or array with its dynamic type's components, the main program's variables that Flang makes static) and the stops at Flang's runtime errors and ERROR STOP. A program built with `-gdwarf-4` and linked with `-Wl,-debug:dwarf` has DWARF too, which gdb reads (tested in CI with Flang 23 and MSYS2's gdb): the variables, a polymorphic object or array with its dynamic type's components, and stops at Flang's runtime errors and ERROR STOP (not at a plain STOP). The VS Code extension's Debug Fortran File builds Flang's programs so (where there is an `lld-link`) and debugs them with gdb; the engine is for those built with `-g` (`"dbgeng": true`).

### What is tested with a real compiler

CI runs zfls against gfortran (the symbols zfls extracts, compared with gfortran's own, on Linux, macOS and Windows x64; `zfls dap` with gdb on Linux and Windows x64, with lldb-dap on macOS), against LFortran (the compiler check and `zfls dap` with gdb, on Linux x64; `zfls dap` with lldb-dap on macOS x64; its programs linking without Visual Studio, on Windows x64) and against LLVM Flang (the compiler check and `zfls dap` with gdb, on Linux x64 and Windows x64; its programs linking without Visual Studio, and `zfls dap` with Windows's Debugger Engine, on Windows x64). The other compilers' options and message formats are tested with recorded output, not with the compilers.

## Installing

Each [release](https://github.com/cesiumlang/zfls/releases) publishes the `zfls` executable for Linux, macOS and Windows, each on x86_64 and ARM64, as `zfls-v<version>-<target>.tar.gz` (`.zip` on Windows), with `SHA256SUMS`. The executable needs nothing else: it can be run from wherever it is unpacked.

The installation scripts in `packaging` download the archive for the computer they run on, check it against `SHA256SUMS` (they stop, and unpack nothing, when that is missing or does not match) and unpack it, by default into the current directory, as `zfls-v<version>-<target>/zfls` (`zfls.exe` on Windows). They change nothing else, the `PATH` included. On macOS and Linux, or in Git Bash, MSYS2 or Cygwin on Windows:

```sh
curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh
```

`--dir DIR` unpacks it into DIR instead, and `--version VERSION` installs that release rather than the latest:

```sh
curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh -s -- --dir ~/tools --version 0.4.0
```

In PowerShell on Windows (Windows PowerShell 5.1 or PowerShell 7):

```powershell
irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1 | iex
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1))) -Dir C:\tools -Version 0.4.0
```

zfls is not signed. On macOS, an archive downloaded in a web browser is quarantined, and since zfls is not notarized by Apple, macOS then refuses to run it (*Apple could not verify "zfls" is free of malware*); Windows can likewise question an unsigned program downloaded in a browser (SmartScreen, Smart App Control). What the scripts download is not marked like that. For an archive downloaded in a browser on macOS, remove the quarantine before unpacking it (`xattr -d com.apple.quarantine zfls-v<version>-<target>.tar.gz`), or from `zfls` itself if it is already unpacked, or allow it once in System Settings, Privacy & Security, "Open Anyway". On Windows, unblock the zip before unpacking it (`Unblock-File`, or "Unblock" in its Properties).

The [VS Code extension](#vs-code-extension) includes `zfls`, and is not affected.

## Building

zfls needs Zig 0.17.1.

```sh
git clone --recurse-submodules <repository>
cd zfls
zig build -Doptimize=fast
```

The executable is `zig-out/bin/zfls` (`zfls.exe` on Windows). `zig build` also generates the API documentation in `zig-out/docs`; `zig build bin` installs only the executable.

Each release also publishes `zfls-v<version>-src.tar.gz`, the sources with its submodules included (`zig build source-archive -- [OUT_DIR]`), and `zfls-v<version>-conda-recipe.yaml`, the conda-forge recipe that builds it. `zig build conda-recipe -- --release ARCHIVE OUT_DIR` writes that recipe from the template in `packaging/conda-forge` (`--local` instead builds from the archive itself). CI builds and tests the recipe on Linux, macOS and Windows for every change.

### VS Code extension

`editors/vscode` is a VS Code extension that runs zfls for Fortran files and adds syntax highlighting. Each release publishes it as `zfls-vscode-v<version>-<platform>.vsix`, one per VS Code platform with that platform's zfls inside (`zig build package-vscode -- DIST`, from the release archives in DIST), plus a `universal` one that runs `zfls` from the `PATH`. To install one, use "Extensions: Install from VSIX..." in VS Code. The release also publishes the platform packages, as `cesiumlang.zfls`, to the Visual Studio Marketplace and to Open VSX (VSCodium and other VS Code derivatives), and the universal one to the Marketplace for the platforms without their own. Each registry has its own workflow, which the release job starts and which takes the packages from the release: "Publish to the Marketplace" (`.github/workflows/marketplace.yml`) uses Marketplace Trusted Publishing (`vsce publish --oidc`: the publisher's Trusted Publishing policy names this repository and that workflow file), and falls back, with a warning, to a Microsoft Entra managed identity that is a member of the publisher (the `AZURE_*` repository variables; the "Marketplace identity" workflow shows the ID to add); and "Publish to Open VSX" (`.github/workflows/open-vsx.yml`) is the workflow whose OIDC token Open VSX trusts for the `cesiumlang` namespace (trusted publishing; the `OVSX_PAT` repository secret is used only if that is refused, with a warning). No stored token is needed. Either workflow can be run by hand, on `main`, for any released version; versions already published are skipped, so a failed run can simply be run again.

The extension replaces the Modern Fortran extension (it registers the same Fortran languages, grammars and snippets, with zfls instead of fortls) and recommends disabling Modern Fortran when both are enabled; see its [README](editors/vscode/README.md#replacing-modern-fortran).

To work on it: Node.js is the version in `.node-version`, which the `.envrc` selects through [fnm](https://github.com/Schniz/fnm) when [direnv](https://direnv.net) is installed (CI's workflows read it too).

```sh
cd editors/vscode
npm ci
npm run typecheck
ZFLS_PATH=../../zig-out/bin/zfls npm test   # in a downloaded VS Code
```

- `engines.vscode` is zfls's oldest supported VS Code (1.102); `@types/vscode` matches it, and `@types/node` and esbuild's target follow its Node.js (22).
- Dependencies are pinned to exact versions and kept free of `npm audit` findings.
- `overrides` in `package.json` forces `minimatch` 11.0.9: `@vscode/vsce` 4.1.1 and `vscode-languageclient` 11.0.0 ask for `^10.2.6`, which has [GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249) (fixed in 11.0.1). Drop the override once they depend on a fixed version.

## Usage

Configure the editor's language client to start `zfls`; it communicates over standard input and output. All fortls options are accepted, for example:

```sh
zfls --incremental_sync --hover_signature --use_signature_help
zfls --help
```

Options can also be set in a configuration file in the project root: `.zflsrc` (TOML), else fortls's `.fortlsrc`, `.fortls.json` or `.fortls` (JSON or JSON5), the first found being read, or the file named with `-c`/`--config`, whose format is told by its content (a first token of `{`, `//` or `/*` is JSON5, anything else TOML). The option names are those of the command line and of the [fortls documentation](https://fortls.fortran-lang.org/options.html), the same in both formats.

A `.zflsrc` is TOML with one key per option, comments with `#`, and a table for the options that take a dictionary (`pp_defs`, `diagnostic_severity`, `file_associations`):

```toml
#:schema https://raw.githubusercontent.com/cesiumlang/zfls/main/editors/vscode/schemas/fortls.schema.json
source_dirs = ["src", "app"]
include_dirs = ["include"]
lowercase_hover = true
compiler_diagnostics = "gfortran"

[pp_defs]
USE_MPI = 1

[diagnostic_severity]
masks-parent = "off"
```

A key that is no option, and a value of the wrong type, are reported as a warning and ignored, in a `.zflsrc` (a fortls file's unknown keys are still skipped silently). The settings that name a program are not read from a project's file, in either format (see Security below). `zfls config [--root DIR] [options]` prints each option in effect and where it came from (the default, the command line, the user's file or the project's file).

Moving a fortls file over: the option names do not change, only the syntax.

| `.fortlsrc` (JSON5) | `.zflsrc` (TOML) |
| --- | --- |
| `{ "source_dirs": ["src"] }` | `source_dirs = ["src"]` |
| `"nthreads": 4,` | `nthreads = 4` |
| `"lowercase_hover": true,` | `lowercase_hover = true` |
| `"pp_defs": { "A": "1" },` | `[pp_defs]` then `A = "1"` |
| `"diagnostic_severity": { "masks-parent": "off" }` | `[diagnostic_severity]` then `masks-parent = "off"` |
| `// a comment` | `# a comment` |
| `"compiler_args": ["-Wall"]` | `compiler_args = ["-Wall"]` |
| `null` (not set) | leave the key out |

Tables are only for the dictionary options; other options are top-level keys, so that the command line, the schema and the files all use one set of names.

Personal defaults for every project go in a user configuration file of the same format: `%APPDATA%\zfls\config.json` on Windows, else `$XDG_CONFIG_HOME/zfls/config.json` (`~/.config/zfls/config.json` without that variable). Relative paths in it are relative to the workspace root, as in the project's file. It is read again when it changes, where the editor watches files outside the workspace, else at the next start.

The editor can also send them over LSP, under the same names, as one object or in its `zfls` member: in the `initializationOptions` of the `initialize` request, and in `workspace/didChangeConfiguration` when they change. In Neovim, for instance:

```lua
vim.lsp.config("zfls", {
  cmd = { "zfls" },
  filetypes = { "fortran" },
  init_options = { use_signature_help = true, source_dirs = { "src" } },
  settings = { zfls = { max_line_length = 132 } },
})
vim.lsp.enable("zfls")
```

Each source takes over from the one before: the command line, the user configuration file, the editor's settings, the project's configuration file. A change applies at once:

- One of the options that decide what is indexed (`source_dirs`, `excl_paths`, `incl_suffixes`, `excl_suffixes`, `include_dirs`, `pp_defs`, `pp_suffixes`, `comment_markers`, `d_lines`, `compile_commands`, ...) indexes the workspace again, keeping the unsaved text of the open documents. So does one that chooses the compiler of the compiler check or its arguments (`compiler_diagnostics`, `compiler_path`, `compiler_args`, their `_fixed` forms, `compiler_no_compile_commands`): the compiler's modules and predefined symbols are read again, and the open documents checked again. Set those in `initializationOptions` (Neovim's `init_options`) to index once at start-up.
- Turning on signature help, code actions or formatting registers them with an editor that allows that (`client/registerCapability`); others are told to restart zfls. Turning one off makes it answer nothing.
- The diagnostics of the open documents are published again.

The configuration file, `fpm.toml` and `compile_commands.json` are read again when they change on disk, with the same effects (a change of `fpm.toml` or `compile_commands.json` indexes the workspace again): zfls asks the editor to watch them where it allows that (`workspace/didChangeWatchedFiles`); other editors restart zfls.

The fortls debug options work as well, for instance `zfls --debug_parser --debug_filepath file.f90` prints the parser trace and the resulting object tree, and `--debug_hover --debug_filepath file.f90 --debug_line 10 --debug_char 5` runs a single hover request. Their output is meant for testing zfls and may differ from fortls's. They take the options as the server does: the command line's, with the configuration file's (`.zflsrc`, `.fortlsrc`, `.fortls.json`, `.fortls` or `-c`) in `--debug_rootpath` over them. With `--debug_log`, `fortls_debug.log` has a `Final options` line with the options in effect, after the command line, the editor's settings, the configuration file and the build files, at start-up and after each change of the settings.

### ifx without Visual Studio (Windows x64)

`zfls setup-ifx` sets up Intel's Fortran compiler, ifx, from Intel's offline installer for Windows, without running the installer (no administrator rights, nothing registered) and without Visual Studio:

```sh
zfls setup-ifx intel-fortran-compiler-2026.2.0.605_offline.exe --show-license
zfls setup-ifx intel-fortran-compiler-2026.2.0.605_offline.exe --accept-intel-license
```

Download the offline installer from [Intel](https://www.intel.com/content/www/us/en/developer/tools/oneapi/fortran-compiler-download.html); zfls distributes nothing of Intel's. It reads the installer as the zip it is, unpacks what a Fortran compiler needs (about 210 MB, leaving out OpenCL, SYCL, GPU offload and the debug and static runtimes), with Intel's license and notices, into `%LOCALAPPDATA%\zfls\ifx\<version>` (or `--dest`), once Intel's license is accepted (`--show-license` prints it). It then copies zfls's ifx kit (`ifx-kit`, next to zfls in the Windows x64 package) next to it and writes `bin\ifx.cfg`, so that this ifx links with its own `lld-link` and the kit instead of Visual Studio's linker and libraries: `ifx` works in any shell, Makefile or fpm build with its `bin` on the `PATH`.

The kit is a startup object of zfls's (the program's entry point over the Universal C Runtime of Windows, the stack probe and the `/GS` stack cookie, `src/ifxkit/shim.zig`) and import libraries made from MinGW-w64's definition files (`zig build ifx-kit`). Programs are built with `/MD`, the C runtime in DLLs (Windows's UCRT, part of Windows 10 and later), and need Intel's runtime DLLs (in ifx's `bin`) to run. `/MT` (Microsoft's static C runtime) does not link; CMake, which runs the linker itself, needs `CMAKE_LINKER` set to ifx's `lld-link` and `LIB` to ifx's `lib` and `zfls` directories. The VS Code extension's **zfls: Set Up ifx** does the same, showing Intel's license first.

The kit links LFortran's programs too (its startup object also has the `atexit`, `__report_rangecheckfailure` and `__GSHandlerCheck` that LFortran's runtime asks of Visual Studio's). LFortran runs `link` from the `PATH`, so a `link.cmd` that runs `lld-link` (conda-forge's `lld`, next to `lfortran`) stands for Visual Studio's, and `LINK`, which `lld-link` reads as arguments, names the kit's files:

```bat
rem link.cmd, in a directory of its own put first on the PATH
@"C:\conda\envs\lf\Library\bin\lld-link.exe" %*
```

```bat
set LIB=C:\zfls\ifx-kit
set LINK="C:\zfls\ifx-kit\zfls_ifx_shim.obj" msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib
lfortran hello.f90 -o hello.exe
```

zfls's build of a file to run (`zfls build-command`, the VS Code extension's **Run Fortran File**) sets this up itself (see [Building a file to run or debug](#building-a-file-to-run-or-debug-zflsbuildcommand)).

The kit links LLVM Flang's programs too. Flang's runtime (`flang_rt.runtime.dynamic.lib`, C++ built against Microsoft's `/MD` runtime) needs its static initializers run before the program, which the kit's startup code does, and a few functions of Microsoft's static libraries, which are in the startup object too. Flang runs `lld-link` itself (`-fuse-ld=lld`, with conda-forge's `lld` next to `flang`), and `-fms-runtime-lib=dll` has it use the C runtime in DLLs; with `LIB` set, neither Flang nor `lld-link` looks for Visual Studio's libraries:

```bat
set LIB=C:\zfls\ifx-kit
set LINK="C:\zfls\ifx-kit\zfls_ifx_shim.obj" msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib
flang -fms-runtime-lib=dll -fuse-ld=lld hello.f90 -o hello.exe
```

zfls's build of a file to run does this too, outside a Visual Studio environment.

An ifx whose own `ifx.cfg` does not choose its linker, such as conda-forge's (`ifx_win-64`, whose `ifx.cfg` is empty), links the same way: `/MD /fuse-ld=lld` has it run its own `lld-link` (in `Library\bin\compiler`), and `LIB` names the kit and ifx's libraries (`Library\lib`). Conda-forge's ifx does not find its own modules either (`iso_fortran_env`; its activation script adds them to `FFLAGS`), so `/I` names them:

```bat
set LIB=C:\zfls\ifx-kit;C:\conda\envs\ifx\Library\lib
set LINK="C:\zfls\ifx-kit\zfls_ifx_shim.obj" msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib
ifx /MD /fuse-ld=lld /IC:\conda\envs\ifx\opt\compiler\include\intel64 hello.f90
```

zfls's build of a file to run does this for such an ifx, outside a Visual Studio environment, and leaves alone one whose `ifx.cfg` chooses the linker (`zfls setup-ifx`'s) or one that `IFXCFG` gives a configuration.

### Building a file to run or debug (`zfls/buildCommand`)

zfls says how to build a Fortran file into a program to run or debug, so that every editor builds it the same way (the VS Code extension's Run Fortran File and Debug Fortran File run this build as a task): the compiler's default options for a debug build (`-g -O0`; `/Zi /Od` for ifx and ifort on Windows; `-g -O0 -static-libgfortran -static-libquadmath` for MinGW's gfortran, so that gdb stops at the errors its runtime raises; `-gdwarf-4 -O0 -Wl,-debug:dwarf` for LLVM Flang on Windows where it has an `lld-link`, for gdb; `-g` for LFortran, none on Windows), the file's directory on the include path, a directory of its own per source file in zfls's cache (`run` in it) for the program and the module and object files, the modules of conda-forge's ifx (`-I`, `/I` on Windows), and on Windows the link of ifx's, LLVM Flang's and LFortran's programs with zfls's ifx kit (see [ifx without Visual Studio](#ifx-without-visual-studio-windows-x64)). It answers the request `zfls/buildCommand`, and the same on the command line:

```sh
zfls build-command hello.f90 [--compiler C] [--compiler-path P] [--output-dir D] [--kit DIR] [-- ARGS...]
```

The request's parameters are `textDocument`, `compiler` (a name looked up on the `PATH`, or a path; `gfortran` by default), `compilerPath` (its file or directory, relative to the workspace), `args` (the build's options in place of the defaults), `outputDirectory` and `env` (values in place of the environment's, such as `{"Path": "${env:Path}"}` for a tasks.json). The answer, `null` when the compiler is not found:

```json
{
  "compiler": "/usr/bin/gfortran",
  "name": "gfortran",
  "debugInfo": "dwarf",
  "debugger": "gdb",
  "runEnv": {},
  "args": ["-g", "-O0", "-I/work", "-o", "/home/me/.cache/zfls/run/hello-1a2b3c4d5e/hello", "/work/hello.f90"],
  "cwd": "/home/me/.cache/zfls/run/hello-1a2b3c4d5e",
  "env": {},
  "program": "/home/me/.cache/zfls/run/hello-1a2b3c4d5e/hello"
}
```

Run `compiler` with `args` in `cwd`, with `env` added to the environment (on Windows, the compiler's directory first on the `PATH`, which MinGW's gfortran needs for its `f951` when it is given by its path, and the kit's `LIB` and `LINK`); when the answer has `linkArgs`, the build is in two steps: `args` compiles (`-c`), and `compiler` with `linkArgs`, run the same way, links. Then run `program` with `runEnv` added (on Windows, the compiler's directory first on the `PATH`, for its runtime libraries). `debugInfo` is the program's debug information (`dwarf`, or `pdb` for Microsoft's) and `debugger` the debugger of `zfls dap` that fits it (`gdb`, `lldb` on macOS, `dbgeng` for a PDB; see [A debugger](#a-debugger-zfls-dap)). `note` says why a build links otherwise than it could (no ifx kit, no `lld-link`). Nix's gfortran on macOS builds in two steps: its wrapper sets `DEVELOPER_DIR` to Nix's SDK, so the `dsymutil` that a `-g` build runs after linking finds no tool (`error: tool 'dsymutil' not found`) and the build fails; linked apart, the program has no `.dSYM`, and lldb reads the debug information from the object file, which stays in `cwd`. Without a `textDocument`, the answer has only the compiler's part (`compiler`, `name`, `debugInfo`, `debugger`, `runEnv`), for a program built otherwise.

With Neovim, a command that builds the current file and runs it in a terminal:

```lua
vim.api.nvim_create_user_command("FortranRun", function()
  local client = vim.lsp.get_clients({ name = "zfls", bufnr = 0 })[1]
  client:request("zfls/buildCommand", { textDocument = vim.lsp.util.make_text_document_params() }, function(_, cmd)
    if not cmd then return vim.notify("zfls: no compiler", vim.log.levels.ERROR) end
    local env = vim.tbl_extend("force", vim.fn.environ(), cmd.env, cmd.runEnv)
    local function step(args, after)
      vim.system(vim.list_extend({ cmd.compiler }, args), { cwd = cmd.cwd, env = env, text = true }, vim.schedule_wrap(function(built)
        if built.code ~= 0 then return vim.notify(built.stderr, vim.log.levels.ERROR) end
        after()
      end))
    end
    local function run()
      vim.cmd.split()
      vim.fn.jobstart({ cmd.program }, { term = true, env = cmd.runEnv })
    end
    step(cmd.args, cmd.linkArgs and function() step(cmd.linkArgs, run) end or run)
  end)
end, {})
```

With Emacs, through `compile`:

```elisp
(defun zfls-run-file ()
  "Build the current Fortran file with the command zfls answers, and run it."
  (interactive)
  (let* ((cmd (json-parse-string
               (shell-command-to-string (concat "zfls build-command " (shell-quote-argument buffer-file-name)))
               :object-type 'alist))
         (default-directory (file-name-as-directory (alist-get 'cwd cmd)))
         (process-environment
          (append (mapcar (lambda (v) (format "%s=%s" (car v) (cdr v)))
                          (append (alist-get 'env cmd) (alist-get 'runEnv cmd)))
                  process-environment)))
    (cl-flet ((step (key) (when-let* ((args (alist-get key cmd)))
                            (concat (mapconcat #'shell-quote-argument (cons (alist-get 'compiler cmd) (append args nil)) " ") " && "))))
      (compile (concat (step 'args) (step 'linkArgs) (shell-quote-argument (alist-get 'program cmd)))))))
```

With Helix, a key in `config.toml` (Linux and macOS, where the answer's environments are empty; with `jq`):

```toml
[keys.normal.space]
r = ":run-shell-command zfls build-command %{buffer_name} | jq -r '\"cd \" + (.cwd | @sh) + \" && \" + ([.compiler] + .args | map(@sh) | join(\" \")) + (if .linkArgs then \" && \" + ([.compiler] + .linkArgs | map(@sh) | join(\" \")) else \"\" end) + \" && \" + (.program | @sh)' | sh"
```

### A debugger (`zfls dap`)

`zfls dap` is a debug adapter (the Debug Adapter Protocol on standard input and output) that shows a Fortran program as Fortran, for any editor with a client of the protocol (VS Code through the extension's `fortran` debug type, Neovim's nvim-dap, Emacs's dape, Helix). It debugs with one of three debuggers, chosen by the `launch` or `attach` configuration, else by the program's debug information, with the rule `zfls/buildCommand` answers with: Windows's Debugger Engine for a program whose debug information is Microsoft's only (a PE whose debug directory names a PDB, without DWARF sections), even where the configuration names gdb or lldb-dap, which cannot read it; else gdb on Linux and Windows and lldb-dap on macOS. The choice by the program is said in the Debug Console (an `output` event); `"dbgeng": false` keeps a configuration from the engine.

- gdb, for the programs of gfortran, LLVM Flang, LFortran and the others with DWARF debug information: gdb 14 or later, built with Python (`gdb -i=dap`), the configuration's `gdb`, else `--gdb PATH`, else the `PATH`'s. zfls passes gdb's protocol through and reshapes its variables: arrays by their subscripts and bounds (`(2,-1)`), large ones in sections (`(1:100)`), previews of arrays and derived types (`[1.0, 2.0, …]`, `[2×3]`, `point(x=9.0, id=7)`), "not allocated" and "not associated", pointers as their targets, a polymorphic object with its dynamic type's components, gfortran's hidden CHARACTER lengths and LFortran's temporaries left out, CHARACTER of kind 4 and arrays of it as Fortran strings (`4_'hëllo'`, an element by its subscripts `w(2,1)`), and a Fortran expression for each (`a(2)`, `p%x`, `grid::cells`) for watches and setting values. `console` (`integratedTerminal`, `externalTerminal`) runs the program in a terminal for its input; `setupCommands` are gdb commands run first; `stopAtEntry` stops at the main program; an `attach` takes a `processId` or a gdbserver's `target`. On Linux AArch64 with SVE, gdbserver 15.1 to 16.2 (Ubuntu 24.04's is 15.1) fails an assertion of its own (`raw_compare: Assertion 'offset < regbuf.size ()' failed`) as the program first goes on, which then runs to its end past its breakpoints, with gdb's own commands too; gdb 16.3 fixed it: use gdbserver 16.3 or later there.
- lldb-dap, LLVM's debug adapter (`"lldb": true` or `"lldb": PATH`, or `--lldb [PATH]`; the default on macOS, where gdb does not run on Apple Silicon and must be code-signed with a certificate of one's own on Intel, and `"gdb": PATH` still chooses gdb): the configured one, else `xcrun --find lldb-dap` on macOS (Xcode's command line tools have it, signed: `xcode-select --install`), else the `PATH`'s `lldb-dap`, else its `lldb-vscode`. zfls passes its protocol through: breakpoints of lines and functions, stepping, the stack, `console`, `stopAtEntry`, an `attach` to a `processId`, and `setupCommands` as lldb commands. lldb reads no Fortran ("no plugin for the language fortran95"): for the programs of gfortran and LLVM Flang its Variables view is empty (its globals show without values), expressions are not evaluated, and there is no module variables scope. LFortran's debug information says its language is C, so lldb shows their integer and real scalars (without LFortran's temporaries). Not on Windows: lldb-dap there (LLVM 21's, the Swift toolchain's) stops the program but tells the stop only when it is asked something else, so zfls refuses it and names gdb and the Debugger Engine. A debugger that does not answer `initialize`, `launch`, `attach` or `disconnect` within two minutes fails that request. Over ssh, macOS lets a debugger start a program only with Developer Mode on (`sudo DevToolsSecurity -enable`).
- Windows's own Debugger Engine (`"dbgeng": true`, or `--dbgeng`, or chosen by the program; `dbgeng.dll` of System32, which every Windows 10 and later has), for the programs whose debug information is Microsoft's: those of ifx and ifort on Windows, and LLVM Flang's built with `-g` (with `-gdwarf-4` they are gdb's too). It launches the program (in a console window of its own) or attaches to it, stops at breakpoints of source lines, steps by lines, and shows the variables as Fortran: dbghelp says where each is, and zfls's declarations its type, kind and rank; arrays are read through Intel's and LLVM Flang's descriptors. For LLVM Flang's programs it has breakpoints, the stack, stepping, the variables (a polymorphic object with its dynamic type) and the stops at runtime errors; gdb reads the variables from a build with `-gdwarf-4 -Wl,-debug:dwarf` too. Its breakpoints take no conditions, hit conditions or log messages yet: such a breakpoint is not set, and says so.

With gdb and the engine, the module variables that the frame's line sees are a scope of their own (zfls indexes the program's sources: `sourceRoot` of the configuration, else `cwd`), and the Debug Console completes the names of Fortran: after `%` the components of the designator before it (`origin%`, `p t%po` with gdb, whose console takes its commands), else the frame's variables and those module variables (gdb's own completion of its commands stays). A module's COMMON variables, of which gfortran's DWARF has only the block, are read at their places in the block (zfls's declarations give their types and the offsets), of every intrinsic type, CHARACTER of a constant length, a SEQUENCE type the program has elsewhere, and any constant shape, also in expressions (`cm(2,3) + cx`). With all three, the exception filter **Fortran runtime errors** stops the program where the Fortran runtime reports an error (an array bound exceeded under `-fcheck=bounds`, a failed allocation, an I/O error without `iostat=`, `err=` or `end=`) or at ERROR STOP, LLVM Flang's and LFortran's runtimes' too. With gdb, data breakpoints watch a scalar, an array's element or a small component (gdb's hardware watchpoints, at its address); a whole array or more than 8 bytes has none, and `dataBreakpointInfo` says why. gdb's filters of C++ exceptions are shown only for a program that links a C++ runtime (libstdc++, libc++, MSVC's `msvcp140.dll`, by its file at the launch or attach, in a `capabilities` event), or for any with `"cppExceptionFilters": true` in the configuration.

A program of coarrays linked with gfortran's `-fcoarray=lib -lcaf_shmem` (GCC 16) runs each image as a process of its own, which neither gdb nor lldb-dap follows (gdb on Windows debugs no child process): its breakpoints, runtime errors and ERROR STOP in the images do not stop, and `zfls dap` says so in the Debug Console at the launch. Build it with `-lcaf_single` to debug one image in the program's own process.

On Windows, MSYS2's gdb reads no symbols of `libgfortran-5.dll`: a breakpoint on one of its functions by name lands in the program's import thunk only, and so misses the errors the runtime raises inside the DLL (an I/O error, `RANDOM_SEED`, `MATMUL`'s shapes). For a program linked with the DLL, zfls dap reads the DLL's export table when gdb loads it (gdb's Python) and sets the filter's breakpoints at those functions' addresses in the DLL instead, so they stop there too. Debug Fortran File builds gfortran's programs with `-static-libgfortran -static-libquadmath` on Windows all the same. `--text JSON` translates the words it shows (the VS Code extension passes them in VS Code's language).

With nvim-dap, for instance:

```lua
local dap = require("dap")
dap.adapters.zfls = { type = "executable", command = "zfls", args = { "dap" } }
dap.configurations.fortran = {
  {
    type = "zfls",
    request = "launch",
    name = "Debug",
    program = function() return vim.fn.input("Program: ", vim.fn.getcwd() .. "/", "file") end,
    cwd = "${workspaceFolder}",
    sourceRoot = "${workspaceFolder}",
  },
}
```

With dape (Emacs):

```elisp
(add-to-list 'dape-configs
             '(zfls modes (f90-mode fortran-mode) command "zfls" command-args ("dap")
                    :request "launch" :program "a.out" :cwd "." :sourceRoot "."))
```

With Helix, in `languages.toml`:

```toml
[[language]]
name = "fortran"
debugger = { name = "zfls", transport = "stdio", command = "zfls", args = ["dap"], templates = [
  { name = "launch", request = "launch", completion = [{ name = "program", completion = "filename" }], args = { program = "{0}" } },
] }
```

### Build files

zfls adds to the `include_dirs` and `pp_defs` options what the project's build files say:

- `compile_commands.json`, in the root, `build/` or `builddir/` (or the file, or directory, that the `compile_commands` option names; `""` or `disable_compile_commands` for none, as in fortls's pending PR #504): the `-I`, `-isystem` and `-D` flags (`/I` and `/D` too) of its Fortran entries. Definitions apply to every file, the first value of a name winning. The Fortran files it compiles outside the root (a sibling library, a fetched dependency) are indexed too, those that `excl_paths` and `excl_suffixes` leave in; the ones under the root are left to the scan of the source directories.
- A file's command in `compile_commands.json` (else `compiler_args`) also says how zfls reads the file, as its compiler does: the source form (`-ffixed-form`, `-ffree-form`; Intel's `/fixed`, `/free`; nvfortran's `-Mfixed`, `-Mfree`; the form of the command only, not of `compiler_args`), the fixed-form line length (`-ffixed-line-length-N`, `-none`, `-0`; Flang's `-ffixed-line-length=N`; Intel's `/extend-source[:N]`, `-extend-source N`, `/4LN`; `-Mextend`; `-132`; gfortran's 72 for a gfortran command without one, when `fixed_line_length` is not set), debug lines (`-fd-lines-as-code`, `-fd-lines-as-comments`; Intel's `/d-lines`; `-Mdlines`) `-fimplicit-none` (IMPLICIT NONE in each program unit without an IMPLICIT statement), and the default kinds the argument checks take (`-fdefault-real-8`, which makes DOUBLE PRECISION 16 unless `-fdefault-double-8`, `-fdefault-integer-8`, `-freal-4-real-8` and the other promotions; Intel's `/real-size:64`, `/integer-size:64`, `/double-size:128`, `/4R8`, `/4I8`, `/autodouble`; `-r8`, `-i8`), over zfls's own settings for that file.
- `fpm.toml` in the root: the `include-dir` of `[library]` (`include` by default, when it exists) and the `macros` of `[preprocess.cpp]`.

A definition from the options or the configuration file is kept over one from a build file.

A project that builds several programs may have a module of the same name in each (`utils` in `app1/` and in `app2/`). zfls keeps every one, and a file's `USE utils` (hover, definition, completion, diagnostics) sees the one whose module directory (`-J`, `-module`, `/module:`, ...; the compile's directory without one) comes first on that file's search path in `compile_commands.json` (that directory, `-I`, the compile's directory); without build information, the one in the file's own directory, then in the nearest directory, then the one of the lowest path.

A module that a USE names and that neither the workspace's sources nor zfls's table of the intrinsic modules defines is read from its module file when that is LLVM Flang's, which is Fortran source: `<module>.mod` in the `include_dirs` (with those of the build files), then, when `compiler_diagnostics` is `flang`, in the directory of Flang's intrinsic modules (`cudadevice`, `cooperative_groups`, `__fortran_builtins`, found from `flang --version`), and the modules that those files use. Hover, completion and go to definition then reach a library's modules and Flang's own; the module files' own diagnostics are not shown. A gfortran `.mod` there (gzip of S-expressions) is read too: zfls writes the module's interface as Fortran (its public types with their components and type-bound procedures, variables and named constants with their types, kinds, ranks and attributes, generic interfaces, and module procedures with their dummy arguments) to `gfortran-mod/` in its cache, which go to definition opens. Intel's `.mod` files are binary and not read; but when `compiler_diagnostics` (or `compiler_diagnostics_fixed`) is `ifx` or `ifort`, such a module is read from the sources the compiler ships with its modules, `opt/compiler/include/*.f90` beside its `bin` (oneAPI's, conda-forge's): `ifport`, `ifcore`, `ifqwin`, `kernel32`, `user32`, `ifwinty` and the others, so that `use ifport` finds `GETPID` and `use kernel32` `GetCurrentProcessId`; and when it is `gfortran`, from the sources in its `finclude` directory (`gfortran -print-file-name=finclude`): `omp_lib` and `openacc`. A compiler's `omp_lib`, `omp_lib_kinds`, `openacc` and `openacc_kinds` come before zfls's table of them (gfortran 16's `omp_lib` has routines the table has not, such as `omp_display_env` and `omp_get_max_teams`); its intrinsic modules do not.

### Fortran and C

For a procedure with `BIND(C)`, whose C name is its `NAME=` or else its name in lowercase, go to definition gives its C declarations too: zfls looks for them in the workspace's C and C++ files (`.h`, `.c`, `.cpp`, `.cu`, ...), in lines where the name follows a type and an opening parenthesis follows it, without parsing C. Find references gives the C calls too (the name followed by an opening parenthesis, outside comments and strings), and the references of the other Fortran procedures of the same C name (interfaces of the C function in other modules). `disable_bind_c_search` turns that search off.

With `bind_c_clangd` set to a clangd (its path, or `clangd` for the one on the `PATH`), zfls starts it after initialization and adds its answers to those of the search: clangd's index of the project's `compile_commands.json` has the declarations in headers outside the source directories, and the names a macro makes. This is for editors that have no C language server to ask (VS Code's extension asks clangd or Microsoft's C/C++ itself). clangd needs a `compile_commands.json` to know the files it has not opened, and keeps its index in `.cache/clangd/index`; until that index is built, and when clangd does not answer within 3 seconds, the search answers alone.

The other way, an editor that attaches zfls to C files too (in Neovim, with `c` and `cpp` among its filetypes) gets, on a C name, the Fortran procedures that bind it (go to definition) and their Fortran references with the C calls (find references). zfls only keeps the text of a C document: it neither parses nor diagnoses it, and answers nothing else there.

Three requests of zfls's own let an editor ask its C language server instead: `zfls/bindC` (a position) gives the procedure there and its C name, or null; `zfls/bindCTargets` (`{"name": ...}`) gives the locations of the Fortran procedures of a C name, and `zfls/bindCReferences` (`{"name": ...}`) their Fortran references. The VS Code extension uses them with clangd or Microsoft's C/C++.

### Module variables, for a debugger

`zfls/moduleVariables` (a position) gives the module variables that the line sees: those of the module or submodule around it (private ones too, and a submodule's ancestors'), then those its USE statements, and its hosts', make visible, each with the module that declares it, its name there, its name at the line (a USE may rename it) and its type; named constants are left out. `zfls dap` shows them, with their values, as a scope of the Variables view; with the C debuggers, whose variables view leaves them out, the VS Code extension shows them in a view of their own.

### Inline values, while debugging

`textDocument/inlineValue` gives, while a debugger is stopped, the places from the first line of the procedure (or program) that holds the stop down to the stop where its variables are used: its locals and dummy arguments, its host procedures', and the module variables the line sees, under the names `zfls dap` lists them by. The editor then shows each one's value at the end of its line (VS Code: `debug.inlineValues`). Named constants, components, procedures, types, strings and comments are left out.

### fpm targets, for tasks and Run/Debug

`zfls/fpmTargets` (no parameters) gives each fpm project of the workspace (a directory with an `fpm.toml`) with its `name` (`fpm.toml`'s, else the directory's), its `uri`, its `auto` switches (`executable`, `test`, `example`: `[build]`'s `auto-executables`, `auto-tests` and `auto-examples`) and its `targets`: the `[[executable]]`, `[[test]]` and `[[example]]` tables of `fpm.toml`, and, where the switch is on, each main program in `app/`, `test/` or `example/` and below that no table names, named after its file, as fpm makes them (`auto`). A target has its `kind`, `name` and the `uri` of its main program. The VS Code extension runs and debugs a target with it when Run or Debug Fortran File is asked of its main program, and names the projects with it; an editor can map a file to the `fpm run` or `fpm test` that runs it the same way. zfls looks through the workspace as for the tests below.

### Tests, for a test explorer

Two requests of zfls's own (no parameters) give the tests of the workspace, for an editor's test explorer to list, run and report (the VS Code extension's Testing view does):

- `zfls/fpmTests`: each fpm project (a directory with an `fpm.toml`), with its `name` (`fpm.toml`'s, else the directory's), its `uri` and its test `targets`: the `[[test]]` tables of `fpm.toml`, and unless `auto-tests = false` each program in `test/` and below, named after its file, as fpm makes them. A target has the `uri` and `range` of its main program (when the file is found), `selectsTests` (the program takes a suite and a test on its command line, as [test-drive](https://github.com/fortran-lang/test-drive)'s template does with `select_suite` and `run_selected`), and the `suites` of test-drive that the program makes (`new_testsuite("name", collect)`), each with the `tests` that its collect procedure returns (`new_unittest("name", ...)` in the sources next to the program).
- `zfls/pfunitTests`: `programs`, the test programs of CMake's `add_pfunit_ctest` in the workspace's `CMakeLists.txt` files (the `uri` of the file and the `range` of the name), each with the `suites` of its `TEST_SOURCES` (`${var}` of a `set()` in the same file expanded); and `unlisted`, the suites of the `.pf` files that no `add_pfunit_ctest` lists. A suite is named as [pFUnit](https://github.com/Goddard-Fortran-Ecosystem/pFUnit) names it (`@suite(name=...)`, else the module's name, else the file's, with `_suite`), at its module; its `tests` are the subroutines after its `@test` (or `@mpitest`) annotations, at the annotation, `parameterized` when they run once per parameter (`testParameters`, `cases`, `npes`, or of a `@testCase` with parameters), so that their results come under names of their own.

Each item has a `name`, a `uri` and a `range`. zfls looks through the whole workspace but builds (`build/`, `_deps/`), `node_modules/` and hidden directories. The procedures and modules are those zfls parses, with the editor's text of the files open in it; `.pf` files are parsed as free-form Fortran. Running the tests, and reading their results, is left to the editor.

### Index cache

A workspace of 200 files or more has its files' texts kept in one file of zfls's cache directory (`index/` in `%LOCALAPPDATA%\zfls` on Windows, `~/Library/Caches/zfls` on macOS, `$XDG_CACHE_HOME/zfls` or `~/.cache/zfls` elsewhere), each with its size and modification time, and with the symbols zfls parsed from it. A start reads a file whose size and time have not changed from there, instead of opening it: reading one file instead of thousands is what makes the first start after a reboot slow, on Windows above all, where an antivirus scans each file opened. It takes the file's symbols from there too, instead of parsing it, when all that parsing reads is what it was: the text, and for a preprocessed file the preprocessor's output, which changes with the macros, the include directories and the headers (the preprocessor runs at each start); a new version or build of zfls parses every file again. On OpenBLAS (3,941 Fortran files, commit dbf2c24c9), on Windows 11 with zfls built with `-Doptimize=safe`, a start takes 0.9 s instead of 2.0 to 3.2 s (`zig build bench`; the times differ on other systems). The cache is written again, on a thread of its own, when files were added, changed or removed, or parsed again; those of other workspaces are deleted after 60 days without use. `disable_index_cache` turns it off.

### Memory

zfls keeps a summary of each workspace file that is not open in the editor: its modules, types, interfaces and procedures as other files see them (dummy arguments, results, named constants, USE statements, docs), without the local variables and constructs of the procedures, which are most of a file's symbols. The summary is also what the index cache holds of such a file. A file is parsed in full again, from the text zfls keeps, when it is opened and before a request reads more of it: any request about the file itself, and, for find references, rename, reference lenses and incoming calls, the files whose text has the name (a document highlight reads the document alone). Those files go back to summaries at the next save, open or close (the last 64 a request read stay in full, for the requests that follow). Files that `INCLUDE` others or are included stay in full, as do all files with `workspace_diagnostics`. The answers are the same as with every file in full. On a generated workspace of 3,000 modules (36 MB of Fortran) memory after initialization goes from 505 MiB to 253 MiB (the full ASTs took 360 MB, the summaries 117 MB), and a start from the index cache takes 0.42 s instead of 0.81 s.

### Comment markers

Some codebases are written in a dialect that a preprocessor turns into Fortran, with comments that start with something other than `!`, such as `;*` (`go to 110  ;* it's done`). `comment_markers` lists such markers: outside strings, zfls reads what follows one as a comment, so that its words are not names and a quote in it does not start a string.

```json
{ "comment_markers": [";*"] }
```

In VS Code, `zfls.commentMarkers` sets it, and the extension highlights those comments too, after a window reload.

### OpenMP conditional compilation

A line that starts with the OpenMP sentinel `!$` and a blank (`!$ use omp_lib`, `!$ call omp_set_num_threads(n)`; in fixed form `!$`, `c$`, `C$` or `*$` in columns 1 and 2, then blanks or a label up to column 5) is a statement when the file is compiled with OpenMP. zfls reads it as code, the sentinel as two blanks: hover, definition, completion, references and rename see the names in it, and a variable used only there counts as used. A line continues as any other (`!$ call s(a, &` then `!$ & b)`). The directives (`!$omp`, `!$acc`) and a comment such as `!$this` stay comments. `disable_openmp_conditional` (`zfls.disableOpenmpConditional` in VS Code) reads these lines as comments, as a build without OpenMP does. The compiler check sees them as code only with the OpenMP flag in `compiler_args` (`-fopenmp`, `-qopenmp`). The VS Code grammar still colors them as comments, under the semantic highlighting of their names.

### Debug lines

A fixed-form line with `D` or `d` in column 1 is a debug line (a DEC extension), which compilers read as a comment or as code by an option. `d_lines` says which: `comment` (the default) or `code`, where the `D` is a blank. zfls reads the lines so, the compiler check passes the compiler the option that reads them so (gfortran `-fd-lines-as-comments` / `-fd-lines-as-code`, Intel `-nod-lines` / `-d-lines`, nvfortran `-Mnodlines` / `-Mdlines`, nagfor `-d_lines`, flang `-fd-lines-as-code`, which needs Flang 21 or later: Flang 20 gets none) unless `compiler_args` already has one, and a debug line read as a comment is a comment for the editor's highlighting (semantic tokens). In VS Code, `zfls.fixedFormDLines` sets it.

```json
{ "d_lines": "code" }
```

### Intel conditional compilation

Intel Fortran has conditional compilation in directive comments, which the compiler honors without `-fpp`: `!DEC$ IF DEFINED (sym)`, `!DIR$ IF (expr)`, `ELSEIF (expr)` (or `ELSE IF`), `ELSE`, `ENDIF` (or `END IF`), and `DEFINE sym [= value]` and `UNDEFINE sym`, which change the symbols for the rest of the file. The prefix is `!DEC$` or `!DIR$` in any case (in fixed form `!`, `C`, `c` or `*` in column 1: `CDEC$`). zfls skips the branches they leave out, in every Fortran file and after the C preprocessor's `#if`, as it does those of `#if`: they are not parsed (no false "declared twice", the declaration in effect in hover), are shown inactive, and fold. Conditions take the Fortran operators (`.AND.`, `.OR.`, `.NOT.`, `.EQ.` ... `.GE.`, `==`, `/=`, ...) and `DEFINED(sym)`. Symbols come from `pp_defs` and the `-D` flags of `compile_commands.json`, and, when ifx or ifort is the compiler check's compiler (`compiler_diagnostics`), from the symbols it predefines (`__INTEL_LLVM_COMPILER`, `_WIN32`, `_M_X64`, `_OPENMP` ..., asked of it once from the `-D` options its driver gives fpp (`-###`: on Linux `__linux__`, `__unix__`, `__ELF__`, `__x86_64__` and no `_WIN32`), else with `-fpp -E` of a probe file, and again when its file changes; the C preprocessor's `#if` sees them too), and are not case-sensitive. `#define` does not define them, as for the compiler. Other directives (`!DIR$ ATTRIBUTES`, `!DIR$ IVDEP`) stay comments. `disable_intel_directives` (`zfls.disableIntelDirectives` in VS Code) reads every branch, as before.

### Diagnostics

Each diagnostic has a code (shown by editors, e.g. in the VS Code Problems panel): `line-too-long`, `comment-too-long`, `statement-without-scope`, `multiple-contains`, `unexpected-end`, `mismatched-end`, `unclosed-scope`, `invalid-parent`, `procedure-before-contains`, `declared-twice`, `masks-parent`, `import-outside-interface`, `import-excludes-name`, `module-not-found`, `use-after-implicit`, `deferred-not-implemented`, `intent-not-in-arguments`, `argument-not-declared`, `not-imported`, `object-not-found`, `undeclared-name`, `unused-name`, `circular-use`, `argument-mismatch`, `argument-kind`, `intent-in-assigned`, `include-not-found`, `preprocessor-condition`, `use-name-not-found`, `argument-not-definable`, `argument-too-short`, `argument-storage-short`, `constant-assigned`, `label-defined-twice`, `label-not-found`, `case-value-overlap`, `exit-outside-loop`, `cycle-outside-loop`, `parameter-without-value`, `duplicate-dummy`, `bad-kind`, `subscript-count`, `unknown-component`, `allocate-object`, `allocate-shape`, `assignment-type`, `condition-type` and `intrinsic-arguments`.

- zfls publishes its diagnostics of a document when it is opened, when it is saved, and while it is edited: once its text has not changed for `diagnostics_change_delay` milliseconds (300 by default), so that a burst of typing costs one check, of the last text. 0 publishes with each change, a negative value only when the document is opened and saved. Other open documents that use a changed module follow when it is saved. A result of the compiler or a linter for a changed text is published with zfls's diagnostics of that text, not before them.
- A client that pulls diagnostics (its `textDocument.diagnostic` capability, as VS Code's has) asks for zfls's own when it shows a document (`textDocument/diagnostic`), and with `workspace_diagnostics` for every file (`workspace/diagnostic`); zfls then publishes none of them, and `diagnostics_change_delay` does not apply. A report the client already has comes back `unchanged`, computed again only after a change in the workspace; `interFileDependencies` tells the client that a change of a module changes the reports of the files that use it. The compiler's and the linters' diagnostics, which come later from their threads, are still published. After a change of the settings zfls asks the client to pull again (`workspace/diagnostic/refresh`). Turning `workspace_diagnostics` on for such a client takes a restart.
- `diagnostic_severity` (option or configuration file) sets the severity of a code, or hides it: `{"masks-parent": "off", "declared-twice": "warning"}`; the severities are `off`, `error`, `warning`, `information` and `hint`.
- `external_modules` names modules from outside the project (glob patterns, case-insensitive) that `USE` statements may name without a `module-not-found` diagnostic, e.g. `["mpi", "petsc*"]`.
- In the code, a comment `! zfls: disable=masks-parent, declared-twice` hides those codes on its line (`! zfls: disable` hides every code), `! zfls: disable-next-line=...` on the next line and `! zfls: disable-file=...` in the whole file.

These are zfls's own options: fortls does not have them.

### Dialects

zfls's own error checks (the ones fortls does not have, beyond names and arguments) follow a dialect, the Fortran that one compiler accepts. `lint_dialect` (`zfls.linter.dialect` in VS Code) names it: `neutral`, `gfortran`, `ifx` or `flang`. Without it the dialect is that of the compiler of the file's form (`compiler_diagnostics`, or `compiler_diagnostics_fixed` for fixed form; `ifort` is `ifx`'s; or the compiler `compiler_path` names when `compiler_diagnostics` is not set), and neutral when that is none or a compiler with no dialect (`nvfortran`, `nagfor`, `lfortran`). Set it to lint against one compiler and build with another.

- Neutral checks only what gfortran, ifx and Flang all agree on.
- A compiler's dialect also applies that compiler's quirks, ahead of the compiler check: for example `real(kind=3)` is an error in gfortran's dialect and fine in Flang's. A quirk is implemented where its rule is simple; the rest is left to the compiler check on save.
- Each rule has a diagnostic code of its own, so that `diagnostic_severity` or a `! zfls: disable=` comment can switch it off, and the documentation of the rule names the dialects that apply it. A file that the compilers accept gets no new diagnostic in any dialect.

The rules, by the dialects that apply them:

| Code | What it reports | Dialects |
| --- | --- | --- |
| `argument-not-definable` | a constant, expression, named constant or INTENT(IN) argument given for an INTENT(OUT) or INTENT(INOUT) dummy argument | all |
| `argument-too-short` | a whole rank-1 array or a section of literal bounds with fewer elements than an explicit-shape dummy argument | all |
| `argument-storage-short` | an array element with fewer elements left in its array than an explicit-shape dummy argument | gfortran, flang |
| `constant-assigned` | an assignment (`n = 4`, `n(1) = 4`) to a named constant (PARAMETER) | all |
| `case-value-overlap` | a CASE value (integer or one-character literals, ranges included) that overlaps an earlier value of the same SELECT CASE construct | all |
| `label-defined-twice` | a statement label defined twice in a scoping unit | all |
| `label-not-found` | a label that a GO TO, DO, FORMAT reference or I/O specifier (`err=`, `end=`, `eor=`) names and the scoping unit does not define; not checked in a file with an INCLUDE or lines a preprocessor conditional leaves out | all |
| `exit-outside-loop` | an EXIT with no construct name outside a DO construct (in a block or IF construct too); not checked in a file with an INCLUDE, `;` or lines a preprocessor conditional leaves out | all |
| `cycle-outside-loop` | a CYCLE with no construct name outside a DO construct, checked as `exit-outside-loop` | all |
| `intent-not-in-arguments` | a variable with INTENT that is not in the argument list; Flang accepts it, so neither it nor the neutral dialect reports it | gfortran, ifx |
| `parameter-without-value` | a named constant declared with no value (`integer, parameter :: n`) | all |
| `duplicate-dummy` | a dummy argument named twice in a SUBROUTINE or FUNCTION statement | all |
| `bad-kind` | a literal kind that no compiler of the dialect has (`integer(kind=3)`; `real(kind=3)` is gfortran's and ifx's error, Flang has it): neutral rejects what none of gfortran, ifx and Flang accepts | all, each by its compiler's kinds |
| `subscript-count` | an array reference with other subscripts than the rank its declaration gives (`a(1, 2)` for a rank-1 array); not for associate names, assumed-rank or arrays whose rank is not declared | all |
| `unknown-component` | `v%b` where the type of `v` is found whole (its extended types too; none with type parameters or an INCLUDE not read) and has no component or binding `b` | all |
| `allocate-object` | an ALLOCATE or DEALLOCATE of a variable that is neither ALLOCATABLE nor a POINTER (plain names only) | all |
| `allocate-duplicate` | the same object twice in one ALLOCATE or DEALLOCATE statement (plain names, subscripts aside); Flang accepts it | gfortran, ifx |
| `allocate-shape` | an ALLOCATE of an array with no shape (and no SOURCE or MOLD), or with a shape of another rank | all |
| `assignment-type` | an assignment of a value of a type that cannot be converted: a numeric or logical literal to a character variable (all dialects), a character literal to a numeric or logical variable (gfortran, flang; ifx accepts it); the same for variables and expressions of known types, `i = c` and `c = i + 1` (all dialects); and the operands of the expression: a CHARACTER one mixed with a numeric or logical one in arithmetic or a comparison (a character literal there is ifx's to accept), `//` of anything but CHARACTER; operands of unknown type, signs, `.not.` and expressions with a function call are not told; not where the workspace has an `assignment(=)` or an `operator` interface | all, see the description |
| `condition-type` | `if (i)` for a numeric or character variable (not the arithmetic IF) | gfortran, flang |
| `intrinsic-arguments` | a call of an intrinsic function (the ones of the M_intrinsics pages that gfortran accepts the same counts for, about 160) with too few or too many arguments, or with a keyword the intrinsic has not (where it is certain), where nothing of the workspace has that name | all |
| `unbalanced-parentheses` | a statement whose parentheses do not match, outside FORMAT and DATA statements and statements with a preprocessor line inside or cut by a blank line or comment after `&` | all |
| `dangling-operator` | an assignment to a declared variable whose expression ends in an operator (`a = b +`) | all |
| `abstract-type-declared` | a `type(t)` declaration of an ABSTRACT type (`class(t)` is fine) | all |
| `extends-unknown-type` | `extends(t)` of a type that nothing defines, where no module of another project or include could bring it in | all |
| `pure-function-argument` | a dummy argument of a PURE function with no INTENT(IN) or VALUE (all dialects), or with INTENT(OUT) or INTENT(INOUT) (Flang accepts them) | all, and gfortran and ifx for INTENT(OUT) and INTENT(INOUT) |
| `unknown-io-specifier` | a specifier of a READ or WRITE that no I/O statement of any compiler has | all |

### Compiler diagnostics

With `compiler_diagnostics` set to a compiler (`gfortran`, `ifx`, `ifort`, `flang`, `nvfortran`, `nagfor` or `lfortran`), zfls has it check each file when the file is opened and saved, and publishes the compiler's errors and warnings with its own diagnostics of the file, labeled with the compiler's name. This works in every editor, not only VS Code.

The compiler runs on a thread of its own, in syntax-only mode, one file at a time (a newer save of a file replaces a run that has not started), with every error (LFortran, which stops at the first one by default, with `--continue-compilation`). First it compiles the workspace modules that the file uses, and those they use, whose `.mod` files are missing or older than their sources, in compile order from zfls's module graph (LFortran, whose syntax-only mode writes no `.mod` file, compiles their symbol tables: `--symtab-only -c`, with the object file in the `.mod` directory); saving a file that defines modules checks again the open files that use them.

zfls reads the compiler's messages in English, so it runs the compiler (and fypp, the linters and the formatters) in the C locale (`LC_ALL=C`): a compiler with translations would otherwise write `Fehler` for `Error`. When the compiler fails with output of which zfls understands nothing, zfls says so once and logs that output. A message without a file and line (a bad option, a file the compiler cannot open) is published at the top of the file; for LFortran that is every line of its output that is not `file:lines:columns: severity: message`, such as an internal error and its traceback.

A compiler run that takes longer than 120 seconds is stopped, with the processes it started (a driver's compiler proper, such as gfortran's `f951`): each tool zfls runs, the compiler, fypp, the linters and the formatters, runs in a job object of its own on Windows and a process group elsewhere, which is also stopped when the server shuts down during a run.

```json
{
  "compiler_diagnostics": "gfortran",
  "compiler_path": "/opt/gcc/bin",
  "compiler_args": ["-Wall", "-std=f2018"],
  "compiler_mod_dir": "build/zfls-mod"
}
```

- `compiler_path`: the executable, or the directory that holds it (by default the compiler on the `PATH`).
- Settings that name a program (`compiler_path`, `compiler_path_fixed`, `compiler_fypp`, `formatter_path`, `fortitude_path`, `codee_path`, `bind_c_clangd`) and `debug_log` are read only from the user's configuration file, the command line and `initializationOptions` (the editor's settings), never from the workspace's own `.zflsrc`, `.fortlsrc`, `.fortls` or `.fortls.json`, which a repository can ship: they are ignored there, and the log says so once. `fortls_debug.log` is made as a new file, and not at all where a link or a directory is in its place. The flags that file gives the compiler (`compiler_args`) and fypp (`compiler_fypp_args`) are filtered to an allow-list as a command's of `compile_commands.json` are.
- A program named without a directory (`gfortran`, `fprettify`, `gdb`, `clangd`) is looked up on the `PATH` and run by its absolute path; a relative `PATH` entry (`.`) is skipped, so a file of the workspace is never taken for it. The VS Code extension starts zfls in the directory of its executable, not in the workspace.
- `compiler_args`: the compiler's own options; by default its warnings (`-Wall` for gfortran, `-warn all,nodeclarations,noexternals` for Intel, `-Minform=warn` for nvfortran, `-Wunused-variable -Wused-undefined-variable` for Flang 22 and later), one image of coarrays (`-fcoarray=single` for gfortran, `-coarray=single` for Intel; without it gfortran, ifx and ifort stop at the first coarray, and Flang needs none), and OpenMP while zfls reads its conditional lines (`-fopenmp`, Intel's `-qopenmp`; not with `disable_openmp_conditional`). On Windows Intel's are `/warn:all,nodeclarations,noexternals /Qcoarray:single /Qopenmp`. zfls adds the syntax-only, form, preprocessor and module directory options, the file's directory and `include_dirs` (`-I`), and, for files it preprocesses, `pp_defs` (`-D`). It also has the compiler read lines as zfls does: fixed-form lines up to `fixed_line_length` when it is set (`-ffixed-line-length-N` for gfortran, `-ffixed-line-length=N` for flang, `-extend-source N` for Intel with 72, 80 or 132, `-Mextend` for nvfortran and `-132` for nagfor with 132), and free-form lines without a limit (`-ffree-line-length-none` for gfortran, whose default is 132 columns before GCC 16); a line-length option in `compiler_args` replaces zfls's of that form. For LFortran, whose own dialect (its default `--std=lf`) rejects implicit typing and implicit interfaces, zfls passes `--implicit-typing --implicit-interface`, each unless `compiler_args` (or the project's command) has an option about it, and neither with a `--std`. On the command line it is one string, split at spaces: `--compiler_args="-Wall -std=f2018"`, or a JSON list, which keeps an argument with a space whole: `--compiler_args='["-Wall", "-I/my dir/inc"]'`. The same holds for the other options that are a program's arguments (`compiler_args_fixed`, `compiler_fypp_args`, `fortitude_args`, `codee_args`, `formatter_args`, `formatter_fixed_args`).
- `compiler_diagnostics_fixed`, `compiler_path_fixed`, `compiler_args_fixed`: the compiler, executable and arguments of fixed-form files, for a project whose legacy code builds with another compiler or options; each is that of the free form when not set (an empty `compiler_args_fixed`: the compiler's defaults), and `compiler_diagnostics_fixed` `none` checks no fixed-form file. The modules a file uses are compiled with the compiler of that file, whatever their form (the `.mod` files of two compilers do not mix).
- `compiler_mod_dir`: where the `.mod` files go, relative to the root; by default a directory per project, compiler and major version (gfortran's and Flang's, from `--version`: gfortran 9 to 14 cannot read the `.mod` files of gfortran 15 and 16) in zfls's cache (`%LOCALAPPDATA%\zfls` on Windows, `~/Library/Caches/zfls` on macOS, `$XDG_CACHE_HOME/zfls` or `~/.cache/zfls` elsewhere).
- `compiler_include_dirs`: further include directories, for the compiler only, relative to the root; glob patterns (`build/*/include`, `**/include`) match directories, as in `source_dirs`, and a path without glob characters is passed as it is.
- The compiler runs in the file's directory, so relative paths in `compiler_args` are relative to that. ifx and ifort, which write their preprocessor's output (`file.i90`) into their working directory, run in one of zfls's cache instead, with the relative directories of the `-I` and `-module` options of `compiler_args` made absolute. zfls passes them `-Tf <file>` (`/Tf <file>` on Windows), so that a file of any suffix (`.f08`, `.f77`, `.pf`) is checked; gfortran and Flang get `-x f95` right before the file for the same reason (`.f77`, `.f18`, `.f23`, `.pf`, `.cuf`). conda-forge's ifx does not find its own modules (`iso_fortran_env`, `ifport`, `omp_lib`; its activation adds them to `FFLAGS`): when `<prefix>/opt/compiler/include/intel64` is beside its `bin` (or `Library\bin`), zfls passes it with `-I`.
- A file opened with a text that is not the one on disk (unsaved changes the editor restored) is checked from a copy of that text.
- `compiler_on_change`: also check a file while it is edited, its unsaved text (a copy in zfls's cache), after `compiler_change_delay` milliseconds without a change (1000 by default). `compiler_no_save` checks files when they are opened only, not saved.
- `compiler_no_dependencies`: do not compile the modules a file uses first, nor check again the files that use a module when its file is saved.
- The project's own options: without `compiler_args`, a file that has a command in `compile_commands.json` (or another file of its directory that has one) is checked with that command's arguments in place of the compiler's defaults, in the command's `directory`, and with the configured compiler (or `compiler_path`): the command's own compiler is never run, and the flags that are not on an allow-list (include and definition flags, `-std`, `-f`, `-W`, `-O`, `-m` and the form and preprocessor options of the compilers zfls knows, with their values) are dropped. zfls keeps its syntax-only, form and module directory options, leaves out the command's compiler, `-c`, `-o`, source file, module directory (`-J`, `-module`, `/module:`...), dependency files (`-MD`, `-MF`...) and color options, and does not add `pp_defs` (the command has its own `-D`). The modules a file uses are compiled with their own commands. `compiler_no_compile_commands` turns this off, as `disable_compile_commands` does with the rest of the file.
- `compiler_fypp`: run [fypp](https://fypp.readthedocs.io) (this executable) on each file first, with line markers naming the file, so that the compiler's messages point into it; `compiler_fypp_args` are fypp's own options (`-I`, `-D`; a list, or one string split at spaces; an `-I` of a glob pattern stands for every directory it matches). fypp's own errors show as diagnostics labeled `fypp`. Without it, `.fypp` files are not checked: no compiler reads fypp's directives.

### Linters

zfls also runs [fortitude](https://fortitude.readthedocs.io) (`pip install fortitude-lint`) and [Codee](https://www.codee.com) (a commercial analyzer, installed and licensed separately) on a file when it is opened and saved, on a thread of their own, and publishes what they find with its diagnostics, labeled `fortitude` and `codee`, each code linking to its rule's page.

```json
{
  "fortitude": true,
  "fortitude_args": ["--select", "C,S"],
  "codee": true,
  "codee_args": ["${file}", "--", "gfortran", "-O2", "${file}"]
}
```

- `fortitude`: lint with fortitude, which reads the editor's text on stdin and its rules from `fpm.toml` or `fortitude.toml`. Its problems are warnings, its fixes quick fixes (the unsafe ones say so), and the source action `source.fixAll.fortitude` applies the safe ones (`fortitude check --fix-only`). `fortitude_path` is its executable or directory, `fortitude_args` further arguments of `fortitude check`, and `fortitude_on_change` lints while a file is edited too, after `fortitude_change_delay` milliseconds (500) without a change.
- `codee`: run `codee checks --json` on the file as saved (not on a file opened with unsaved changes, until it is saved). Its defects (`PWD...`) are errors, its recommendations (`PWR...`) warnings and its remarks (`RMK...`) hints. `codee_path` is its executable or directory, and `codee_args` further arguments, before the file, or with `${file}` where the file goes. zfls follows Codee's documentation of its output, untested with Codee itself.

The code actions are offered with fortitude on even when `enable_code_actions` is off (then only fortitude's).

Two requests act on the checks: `zfls/compilerCheck` (`{textDocument: {uri}}`) checks a file now, its text in the editor, and `zfls/compilerClear` drops the compiler's diagnostics and zfls's `.mod` files (not those of `compiler_mod_dir`).

### Formatting

With `formatter` set to `findent`, `fprettify`, `codee`, `forformat` or `custom`, zfls answers `textDocument/formatting` and `textDocument/rangeFormatting` (format document, format selection, format on save) by running that formatter, which is installed separately (`pip install findent`, `pip install fprettify`, or the same from conda-forge; [Codee](https://www.codee.com); forformat). This works in every editor, not only VS Code; zfls offers formatting only when a formatter is set.

| `formatter` | Command line |
| --- | --- |
| `findent` | `findent -ifree` (or `-ifixed`), `-Ia` for a selection, then `formatter_args` |
| `fprettify` | `fprettify`, then `formatter_args` |
| `codee` | `codee format - -o -`, then `formatter_args`; the `codee` of `codee_path` unless `formatter_path` is set |
| `forformat` | `forformat --stdin-filename=FILE -ifree` (or `-ifixed`), then `formatter_args` |
| `custom` | `formatter_path` with `formatter_args`, in which `${file}` is the document's path and `${form}` `free` or `fixed` |

zfls gives the formatter the document's text, as the editor has it, on its standard input, reads the result from its standard output (no files are written), and answers with an edit for each block of lines the formatter changed (from a line diff), so the lines it left alone keep their exact text. The formatter runs in the file's directory, so fprettify finds the `.fprettify.rc` files there and above.

```json
{
  "formatter": "fprettify",
  "formatter_args": ["--indent", "4", "--enable-decl"],
  "formatter_fixed": "findent",
  "formatter_fixed_args": ["-i2"],
  "formatter_path": "/opt/tools/bin"
}
```

- `formatter_args`: the formatter's own options. findent gets `-ifree` or `-ifixed` from the file's form (its extension, else what zfls detects) unless these set the input form (`-i...`, `--input_format`), and for a selection `-Ia`, which starts at the indentation of its first line. On the command line it is one string, split at spaces: `--formatter_args="-i4 -r1"`.
- `formatter_fixed`, `formatter_fixed_args`: the formatter of fixed-form files and its options, when they differ (by default `formatter`'s); fprettify formats free form only, findent both. `none` formats no fixed-form files.
- `formatter_path`: the executable, or the directory that holds it (by default the formatter on the `PATH`).

A selection is formatted as whole lines, and findent, fprettify and a custom formatter see only those lines: select whole constructs for the indentation inside them to come out right. Codee's formatter and forformat format whole files only: zfls gives them the whole file and keeps the changes in the selected lines. When the formatter is missing or fails, the document is left as it is and zfls shows the error once (`window/showMessage`).

### The form of a `.fpp` file (`zfls/sourceForm`)

The compilers read a `.fpp` file as fixed form, preprocessed, unless their options say otherwise, and zfls detects its form from its text. An editor names a form by the document's language (VS Code opens every `.fpp` as `FortranFreeForm`), so for such a file zfls takes its own detection over the language the document is first opened in, and sends the notification `zfls/sourceForm`, `{ "uri": ..., "form": "fixed", "languageId": "FortranFixedForm" }` (or `"free"`, `"FortranFreeForm"`), when the language is not the detected form's. The VS Code extension gives the document that language, so highlighting, the formatter and the fixed-form features agree. A language the document is reopened in at once after that (Change Language Mode closes and opens it) is the user's choice, which zfls reads it in and keeps for the file while it runs; opened in the language it told, nothing more is sent.

A lasting choice is a file association: `file_associations` (option or configuration file) holds the editor's associations of glob patterns with languages, `{"*.fpp": "FortranFixedForm", "**/modern/*.fpp": "FortranFreeForm"}`, which the VS Code extension sends from VS Code's `files.associations`. A `.fpp` file whose association gives it `FortranFreeForm` or `FortranFixedForm` is read in that form, open or not, and nothing is sent for it. The patterns are matched as VS Code matches them: one with a `/` against the absolute path, one without against the file name, ignoring case; the longest that matches wins, whatever its language. A change applies at once: a document whose association changed is read anew, and the editor told its new form when its language is another.

### Converting the source form

findent rewrites a fixed-form source as free form (`-ifixed -ofree`), and a free-form one as fixed form (`-ifree -ofixed`). The request `zfls/convertForm`, with `{ "textDocument": { "uri": ... }, "to": "free" }` (or `"fixed"`), runs findent on the document's text as the editor has it and answers `{ "text": ..., "path": ... }`: the converted text and the file it belongs in (`name.f90`, or `name.f`; `.F90`/`.F` for a preprocessed file), since zfls takes the form from the extension. On failure, it answers `{ "error": ... }` with findent's message, or how to install findent. The findent of `formatter_path` is used when findent is the formatter, else the one on the `PATH`; findent's `formatter_args` (or `formatter_fixed_args`) come first. For clients that can create files in a workspace edit (`workspace.workspaceEdit.resourceOperations` with `create`), a fixed-form file has the source action "Convert to free form (new file name.f90)", whose edit creates that file with the converted text (it needs `enable_code_actions`). The old file is left; deleting it is the user's choice. In VS Code, **Fortran: Convert to Free Form** and **Fortran: Convert to Fixed Form** write the new file beside the old one, asking before they overwrite one, and open it.

## Testing

| Command | Checks |
| --- | --- |
| `zig build test` | Zig unit tests, and the tests of upstream fortls issues |
| `zig build test-issues` | only the tests of the open issues of upstream fortls (see `tests/issues/README.md`) |
| `zig build test-fuzz` | mutated programs thrown at an in-process server (crashes, leaks); `--fuzz` runs the fuzzer |
| `zig build test-damaged` | every line of the test corpus damaged as half-typed code is (cut, deleted, END statements dropped, unbalanced parentheses and quotes, random bytes, mixed line endings, fixed and free form mixed), with the main requests on each version: crashes, error answers, leaks, hangs, ranges outside the document (minutes; a sample of it is part of `zig build test`) |
| `zig build test-parity` | fortls's server test suite, replayed against zfls |
| `zig build test-oracle` | symbols of `tests/fortran` and `tests/gfortran` (gfortran's dialect, a fixture's options on its `oracle-gfortran-args:` and `oracle-zfls-args:` lines, the oldest gfortran that reads it on its `oracle-gfortran-min:` line), with their types and kinds, ranks, ALLOCATABLE, POINTER, TARGET and INTENT, against gfortran parse trees (`-fdump-fortran-original`); CI also checks fortls's corpus (`-- _fortls/test/test_source`); the differences known, each with its reason, are in `tests/gfortran_oracle/known.zig` |
| `zig build test-flang-oracle` | symbols of `tests/fortran` and `tests/flang` (LLVM Flang's dialect and quirks), of the module files Flang writes of them and of Flang's intrinsic modules, with their types and kinds, ranks, ALLOCATABLE, POINTER, TARGET and INTENT, against Flang's scope trees (`-fc1 -fdebug-dump-symbols`); the differences known, each with its reason, are in `tests/flang_oracle/known.zig` |
| `zig build test-ifx-oracle` | symbols of `tests/fortran` and `tests/ifx` (Intel's dialect, a fixture's options on its `oracle-ifx-args:` and `oracle-zfls-args:` lines), with their types and kinds, ranks, ALLOCATABLE, POINTER, TARGET and INTENT, against ifx's listings (`/list /show:map`); the differences known, each with its reason, are in `tests/ifx_oracle/known.zig` |
| `zig build test-stress` | long randomized editing sessions (crashes, leaks, stale state) |
| `zig build test-compiler` | the compiler check (`compiler_diagnostics`) of `tests/compiler` with a real LFortran (`-- --compiler flang`: LLVM Flang; `--path EXE` names the compiler) |
| `zig build test-cancel` | `$/cancelRequest`: a request canceled while it waits is answered with RequestCancelled, one canceled while it runs gets its result (part of `zig build test`) |
| `zig build test-stdio` | zfls on standard streams opened for overlapped I/O, as Git Bash's pipes are (Windows; part of `zig build test` there) |
| `zig build test-differential` | every request type against Python fortls (slow) |
| `zig build test-all` | all of the above except the differential run |

The stress test edits a copy of fortls's test sources thousands of times, with saves, close/reopen and requests mixed in, and then checks that every edited file's symbols and diagnostics match a fresh server's. Run it on a Debug build so memory errors and leaks are caught; for longer runs, `zig build test-stress -- --seeds N --steps M` (`--help` lists the options). `zig build test-tools` installs the oracles and the stress test drivers in `zig-out/bin`, to run them against a server built elsewhere (`--zfls EXE`).

Memory checking under valgrind (Linux only: the macOS and Windows runners cannot run it, where the unit tests check leaks with Zig's debug allocator instead) is the manual workflow `memcheck.yml` (`gh workflow run memcheck.yml --ref BRANCH`; it also runs weekly on `main`). Its jobs run the unit tests and the request tests (`zig build memcheck-bins` installs their binaries), the server on LAPACK, OpenBLAS, numpy, M_intrinsics and fortls's corpus through the benchmark driver, the differential and stress drivers, and the debug adapter against gdb, each server process through `tests/memcheck/zfls-valgrind.sh`; a job fails when a valgrind log has anything in it. Findings that are not zfls's are suppressed in `tests/memcheck/zfls.supp` with the reason. Zig's allocators map memory themselves, so memcheck finds uninitialized reads and invalid accesses, not leaks of Zig-allocated memory; the `threads` job runs helgrind and drd on the indexing threads, whose report is informational, since they do not see Zig's futex based locks.

Where the server spends its time is the manual workflow `profile.yml` (`gh workflow run profile.yml --ref BRANCH`, once it is on `main`): the benchmark driver on LAPACK, OpenBLAS and numpy, one scenario at a time (cold index and start from the index cache, requests, edits, saves), under `perf record` (call graphs from frame pointers) and under callgrind (instruction counts, deterministic), through `tests/profile/zfls-perf.sh` and `tests/profile/zfls-callgrind.sh`. Its artifacts are the reports: `perf report` exclusive and inclusive, folded stacks, `callgrind_annotate`. `zig build -Doptimize=safe -Dprofile=true bin profile-bins` builds the server and the driver with frame pointers and symbols; on macOS `tests/profile/run.sh sample WORKSPACE OUT_DIR` samples each server process with `sample`.

The parity, differential and stress tests need a fortls checkout, `../fortls` by default or `-Dfortls=PATH` (the stress test takes its test sources, else `tests/fortran`). The parity and differential tests, which run fortls's own code, need Python 3 (`-Dpython=EXE`); no third-party Python packages are required. The oracle test needs `gfortran` on the `PATH` or in the MSYS2 UCRT64 installation; it is skipped when gfortran is missing. The Flang oracle needs LLVM Flang (`FLANG`, `-- --flang EXE`, or `flang` or `flang-new` on the `PATH`), with its intrinsic modules (conda-forge's `flang_linux-64`, `flang_win-64`); it is skipped without one, and CI runs it on Linux x64 and Windows x64. The compiler check's test (and `tests/issues/compiler_lfortran.zig`) needs `lfortran` on the `PATH` (`--lfortran EXE` or `LFORTRAN` for the driver), from conda-forge (`pixi add lfortran`, `conda install -c conda-forge lfortran`), and is skipped without it; CI runs it on Linux x64. The tests of the external tools zfls runs (`tests/issues/real_tools.zig`, `tests/issues/bind_c_clangd.zig`) run fortitude, fypp, findent, fprettify and clangd from the `PATH` (`pip install fortitude-lint fypp findent fprettify clangd`), each skipped without its tool (failed, with `ZFLS_TEST_TOOLS` set); CI runs them on Linux x64.

`zig build bench` first compares what the server's hot paths cost with `tests/bench/baseline.json`, then, given a workspace, times it. The comparison (`zig build bench-counts`, also part of `zig build test`) runs scenarios in process on fixed corpora (M_intrinsics, `tests/fortran`, a generated module of 1500 procedures, a statement of 20000 terms: initialization, then on the largest file documentSymbol, semanticTokens, pull diagnostics, hover, definition, references, completion and ten edits) with an allocator that counts the allocations and the bytes asked for, and the peak of the server's memory. Counts do not depend on the machine's load, so a count that grows by 50% over the baseline (1.75 times for the peak) fails (the platforms differ by up to a quarter: what the system calls allocate; the scenarios start the server with one indexing thread, so that the number of cores does not count), which shows a quadratic or per-term blowup on a pull request without wall-clock flakiness. After a change that costs less or more on purpose, `zig build bench-baseline` records the file again. To find where the bytes of a scenario go, `ZFLS_ALLOC_SITES=corpus/phase zig build bench-counts` (for example `long_expression/diagnostics`) prints the call stacks that asked for the most; `ZFLS_LONG_TERMS=1000000` sets the length of the long statement. For wall-clock time, `perf record -g` on Linux and Windows Performance Recorder (ETW, with an elevated prompt) profile a `-Doptimize=safe` server started by the benchmark below.

`zig build bench` times zfls on a large workspace (workspace initialization, request latency, edits, memory), and fortls too when `--fortls` gives the command that starts it, for example on a checkout of [json-fortran](https://github.com/jacobwilliams/json-fortran):

```sh
zig build bench -Doptimize=safe -- ../json-fortran --fortls fortls
```

## Releases

`zfls --version` reports the version in `build.zig.zon`, which is the version of the next release: with `-dev` in Debug builds, and with `-rc` in release builds while the `zfls.prerelease` file that `zig build` installs sits next to the executable. Release archives leave that file out, so a released binary reports the plain version.

GitHub Actions (`.github/workflows/ci.yml`) builds the release binaries for every pull request into `main` and every push to `main` once, and tests them as release candidates on Linux, Windows and macOS, each on x86_64 and ARM64: the suites above, longer stress runs and the differential test. macOS on ARM64, whose GitHub-hosted runners are few and can be unavailable for hours, is tested only by pull requests into `main`, by runs started by hand, and by a release that builds its own binaries. Pull requests into `dev` and pushes to `dev` are not run: whoever merges them runs the checks first, and `dev` as a whole is tested by the pull request that releases it, which runs again with each change of `dev`. To test another branch or pull request in between, start the workflow by hand on its branch (`gh workflow run ci.yml --ref BRANCH`); the run's checks show on the pull request. A pull request that only changes files listed in `.github/workflows/no-ci.txt` (documentation, editor settings) skips the build and the tests. The "CI" check sums up a run, passing when nothing failed, so also when the build and the tests were skipped; it is the check the ruleset of `main` requires, with "Version".

Changes are collected on the `dev` branch, by pull requests or pushes of maintainers, and released together by merging `dev` into `main`. `main` takes changes only through pull requests whose checks pass (an administrator can override that when merging); `dev` requires no checks, only that its history is not rewritten. A separate ruleset keeps `dev` from being deleted, with no exceptions, so merging the release pull request does not remove it.

The release notes are generated from the pull requests merged since the last release, in sections by label (`.github/release.yml`): `fix`, `feature`, `performance`, `tests`, `refactor` and `ci`. `skip-changelog` leaves a pull request out, for example the `dev` to `main` pull request of a release.

When a push to `main` passes on every platform, the same archives are published on the GitHub releases page and the tested commit is tagged. CI then merges `main` back into `dev` and commits the next patch version to `build.zig.zon` there. For a minor or major release, set the version in `build.zig.zon` on `dev` by hand. A pull request to `main` fails its "Version is unreleased" check when it can change the shipped binaries while `build.zig.zon` holds an already released (or older) version. Pushes to `main` that cannot change them are tested but not released. Changes that cannot (`.github/workflows/changes.sh` decides, for both) are those to the files of `no-ci.txt` and of `ci-only.txt`, which lists the files that CI builds or runs, but that do not ship (tests, tools, the conda-forge recipe, the workflows themselves); changes to Zig source that only touch whole-line comments and blank lines; and changes undone since (such as a version set back). A change to how `ci.yml` builds the binaries is released with the next change to the binaries themselves.

A merged pull request is not built again: when a passed run of the pull request built exactly the code that lands on `main` (the same git tree and version), the release publishes that run's archives. Otherwise, for example when `main` changed after the pull request was tested, the push to `main` builds and tests the release binaries itself first.

## Differences from fortls

zfls deliberately differs from fortls in a few places:

- Positions are UTF-16 code units, as the LSP specifies; fortls counts code points.
- Inserting text that ends with a newline through an incremental change does not add a spurious empty line.
- `initialize` announces `textDocumentSync` as options (`openClose`, `change`, and `save` without the text), so that every client sends the `didSave` that zfls runs its checks, the compiler and the linters on (hansec PR #183); fortls announces only the change kind, which a client may read as no save notifications.
- Several requests on which fortls raises an internal error (for example implementation requests on module names, or completion inside an `IMPORT` statement outside an interface) return `null` or an empty result.
- Line length diagnostics are not duplicated when a file is checked again.
- On a call of a generic interface, signature help shows the signature of each of its procedures, the one the arguments so far fit active (fortls #6), and go to definition goes to that procedure (hansec #135); fortls shows no signature and goes to the interface. The procedure is the one the arguments fit by their type, kind and rank (#273), when zfls can type them (literals, variables, expressions of these): `area(k)` with an integer `k` takes `area_i`, `twice(1.0d0)` the `REAL(8)` one, `total(a)` with an array `a` the one with an array argument, a call with an array an elemental procedure unless a nonelemental one takes the array, and derived types (an extension for a `CLASS`). Type-bound generics resolve the same way. When the types do not tell (an argument of unknown type, or several procedures still fit), it is the first that takes as many arguments with those keywords. Go to implementation, the inlay hints, the call hierarchy and hover (which shows only that procedure when the call fits no other) take the same procedure.
- Signature help stays on the call while the cursor is inside an array constructor argument (`call s([1, 2, ...`, `(/ ... /)`, an implied DO): the constructor is one argument, and a call inside it has its own signature (hansec #60); fortls shows none there.
- In a structure constructor (`pt(1, 2)`), signature help shows the type's data components, its parent's first, and with them the procedures of a generic interface named like the type (hansec #148); keyword completion offers both. A component with a default value is optional, and outside the type's module a type with a private component has no constructor signature. fortls shows none.
- Inside a call, completion also offers `name=` for each argument the call can name and has not named yet (hansec #133), first in the list; fortls offers only the names in scope.
- Completion also offers the public names of the workspace's and the intrinsic modules that the program unit does not use, after the others; choosing one adds `use module, only: name` after the unit's last USE statement (hansec #62, `autocomplete_no_auto_use` turns it off). A type that is not found has a quick fix adding that statement.
- To a client that resolves completion items (`completionItem/resolve`, as VS Code does), completion sends each item without its documentation, which follows when the item is selected: a list of 2,000 procedures is less than half the size and takes half the time; fortls sends every item's documentation.
- The workspace files that are not open are kept as summaries, parsed in full again when a request needs more of them (see [Memory](#memory)); fortls keeps every file's text and full parse (FL #563).
- With nothing typed, completion (Ctrl+Space) lists the names of a module after `use m, only:` and after each comma of the list (less those it has already), the modules after `use`, the types after `type(`, `class(` and `extends(`, the interfaces after `procedure(`, and the names after `import ::`, `public ::` and `private ::`; elsewhere it still waits for a letter. fortls answers nothing until a letter is typed.
- A local variable of a procedure or program, or a name of a `USE ONLY` list, that its scope never uses gets an `unused-name` hint, shown faded, with a quick fix removing it from its declaration: the whole statement when it declares nothing else, otherwise the name with its dimensions and initialization (continuation lines included). The source action "Remove all unused declarations" removes all of a file's. A name counts as used when it appears anywhere else in the scope, contained procedures, inactive preprocessor branches and the values of the macros used there included; dummy arguments, function results and module names are not reported. fortls has no such check.
- Diagnostics follow the text while a document is edited, after `diagnostics_change_delay` milliseconds without a change (see [Diagnostics](#diagnostics)); fortls publishes them when a document is opened and saved only, so that the list is the last save's while one types.
- `workspace_diagnostics` publishes the diagnostics of every workspace file after initialization, and again when a saved or changed file changes them, so that editors list the problems of files that are not open; a deleted file's are cleared. fortls only checks open files.
- An END statement that does not fit the construct open there gets a `mismatched-end` error (`END DO does not match the IF construct opened at line 4`); when it fits a scope further out, the scopes inside are closed with it, so that what follows is not read as nested. A program unit or construct still open at the end of the file gets an `unclosed-scope` error at its first line, except in a file that another includes, in a scope with an INCLUDE, and in a file that is not preprocessed but has `#if` directives. fortls reports neither.
- Under IMPLICIT NONE, a name that is not declared gets an `undeclared-name` warning with a quick fix declaring it (hansec #129); fortls only checks the types named in declarations. A line with macros is read with them expanded, as the compiler reads it, and a name is reported where it is written (`CHECK(nope)`). It is left out where a USE statement names a module that is not in the workspace, or in a scope with an INCLUDE whose file is not found or that continues a statement, as the name could come from those.
- A dummy argument with no declaration (`argument-not-declared`) has a quick fix declaring it after the procedure's declarations, and one for all of them when a header has several; and while a declaration's names are typed in the procedure, completion offers those arguments first (alone with nothing typed). fortls has neither (FL #323).
- `fixed_line_length` (as gfortran's `-ffixed-line-length-n`: 72, 80, 132) makes the columns past it of a fixed-form line a comment: a `comment` semantic token, and no names there (they declare nothing, and have no hover, definition or references); the compiler check is given the same length. The VS Code extension passes 72 by default (`zfls.fixedFormLineLength`), as its grammar no longer stops the code at column 72 itself (Modern Fortran #87). fortls has no such option.
- Go to definition of a preprocessor macro goes to its `#define` (the one in effect at the use, also in a header an `#include` reads), and null for a macro of `pp_defs` or `-D`; references and document highlights list the macro as a word of the file's code (outside strings and comments) and of its directives, and for a header's macro of the header and the workspace files that include it; hover and definition work on the names of `#ifdef`, `#ifndef`, `#if defined(...)` and `#undef` lines (hansec #115). fortls answers the use itself and lists only it.
- OpenMP conditional compilation lines (`!$ x = 1`) are code (Modern Fortran #17); fortls reads them as comments, so its references and rename leave them out. `disable_openmp_conditional` reads them as fortls does.
- Intel's conditional compilation directives (`!DEC$ IF DEFINED (X)`, `!DIR$ IF (expr)`) leave their branches not taken out of parsing, as `#if` does, in every file (FL #309); fortls reads every branch, which gives false "declared twice" errors. `disable_intel_directives` reads them as fortls does.
- On Windows, a folder on a UNC path, as a network share or `\\wsl.localhost\...` is, is served: its URIs (`file://host/share/dir/file.f90`) are read as `\\host\share\dir\file.f90` and written back in that form (hansec PR #219, Modern Fortran #1087).
- Typing `#` first on an indented line moves it to the first column (`textDocument/onTypeFormatting`, Modern Fortran #177); fortls has no on-type formatting.
- fypp: the words of inline expressions (`${...}$`), eval lines (`$:`) and macro calls (`@:`) are no Fortran names, and a file with fypp directives gets no `undeclared-name` warnings, as fypp's loops and macros make names.
- `use mpi` and `use mpi_f08` find stubs of the MPI modules (the procedures and constants used most, with their arguments): hover, signature help and completion work for them, and the names the stubs leave out are not reported as undeclared. fortls reports the modules as not found.
- CUDA Fortran: a procedure with `attributes(...)` is a procedure, also when other words of its prefix come first (`pure attributes(device) function`, as in LLVM Flang's `cudadevice` module), signature help reads past a kernel's `<<<grid, block>>>`, `.cuf` and `.CUF` files are Fortran sources, and the modules of NVIDIA's compiler (`cudafor`, `cublas`, `cufft`, `curand`, `cusparse`, ...) are external modules, never "not found". fortls reads none of these.
- DEC structures are read (fortls #171): `STRUCTURE /name/` is a derived type, `RECORD /name/ a, b` declares variables of it, the fields of `UNION`/`MAP` blocks are fields of the structure, and a nested structure declares the fields its name list gives. Its type is one of the scope around the outermost structure, as compilers make it, so `RECORD /inner/ r` can name it there. `.` separates a component when it follows a name or `)` and does not start an operator (`a.and.b`), as in `rec.field` or `arr(i).field` (hansec #45). fortls reads none of these.
- A statement function (`f(x) = x**2 + 1` in the specification part of a procedure or main program) is a function of its scope, with its dummy arguments: hover, definition, signature help, references. Its result and arguments have the types the scope gives their names. A statement of that form is an assignment to an array element when its name is an array, and when an executable statement came before it in the scope. The same goes for a name that is not declared where a USE, an INCLUDE or a host scope could declare it. fortls reads every such statement as an assignment.
- An ENTRY statement (`entry e2(x, y) [result(r)]`) declares a procedure of the kind of its procedure, in the scope that has that procedure (a module, the host, or the file), as the compilers do. It has hover, definition, signature help, references and symbols, and its dummy arguments and result are the procedure's variables of their names. fortls declares nothing for it.
- COMMON blocks and NAMELIST groups are symbols (in the outline and workspace symbols). Hover on one lists its variables (`COMMON /blk/ a, b(10)`, `NAMELIST /nl/ a, r`), and it has a definition and references. The references of a block are those of all the program units that name it, in COMMON and SAVE statements. A block's name is no name of the scope (`common /x/ x` is allowed), and the bounds a COMMON statement gives are its variables' dimensions. A group is the name that `write (*, nl)` and `nml=nl` name. fortls has neither.
- A user-defined operator (`.ord.`) has a definition (its `interface operator (.ord.)`), a hover (the procedures of that interface) and references (its uses in the workspace) (hansec #95); fortls has none. So has the `=` of an assignment to a variable whose type has a defined assignment (`generic :: assignment(=) => p` in the type or a type it extends, else an `interface assignment(=)` for it): its references are the binding and the assignments to variables of the types that use it.
- Hover on a coarray shows its codimension (`REAL, CODIMENSION[*] :: x`), written after its name or as an attribute; fortls drops it.
- With the `hover_signature` option (`zfls.hoverSignature`, on by default in the VS Code extension), hover on an actual argument of a call also shows the dummy argument it is passed to: the procedure's signature and the dummy's declaration and documentation (hansec #107, #188). Keyword arguments, the passed-object argument of a type-bound procedure, the specific of a generic that the arguments fit and nested calls are followed. fortls reads the option and does nothing with it.
- The `doc_math` option rewrites the formulas of documentation comments, Doxygen's `\f$ x \f$`, `\f[ x \f]` and `\f{env}{ x \f}` and FORD's `\( x \)` and `\[ x \]`, in hover, completion and signature help (fortls #70): `keep` (the default) leaves them as written, `dollar` writes `$x$` and `$$x$$` (on lines of their own) for clients that render KaTeX or MathJax, and `plain` puts the formula in backticks without its markers, so Markdown does not eat its `_`, `*` and `\`. The VS Code extension's `zfls.docMath` is `plain` by default, as VS Code's hover renders no math. fortls passes the markers on.
- Hover on a statement or attribute keyword (`ALLOCATE`, `CALL`, `INTENT`, ...) shows its documentation (fortls #547), and so does hover on a word of an OpenMP or OpenACC directive (`!$omp parallel do`, `reduction`, `!$acc data`); fortls has no hover there.
- The variables in the parentheses of an OpenMP or OpenACC directive's clauses (`private(i)`, `copyin(a)`, `reduction(+:total)`) are colored by semantic highlighting as the same names are in code; the directive's own words and its clauses' names are not (#725).
- Hover on a literal constant shows its type with its kind: `3.0_dp` is `REAL(dp)`, `7_8` `INTEGER(8)`, `1d0` `DOUBLE PRECISION`, `.false._1` `LOGICAL(1)`, `dp_'x'` `CHARACTER(LEN=1, KIND=dp)`, and `z'ff'` a BOZ constant of value 255 (fortls #125). fortls shows the type without its kind, and nothing on `1d0`, `7_8` or BOZ constants.
- Hover on the file name of an `#include` directive or `INCLUDE` statement links the file it reads (relative to the workspace root when it is inside it), and is empty when the file is not found; fortls answers as for a character literal. Strings and numbers on other preprocessor lines (`#define X "text"`) are no literals and get no hover.
- Hover on a name that is not declared shows the type that the IMPLICIT statements of its scope and the surrounding scopes, or the default rules (I to N INTEGER, other letters REAL), give it (hansec #201); fortls has no hover there. Under IMPLICIT NONE there is none.
- Workspace symbol search also finds the names the query matches fuzzily (`tar` finds `this_amazing_routine`), after those that contain it (hansec #195); fortls finds only the latter.
- Workspace symbols include the type-bound procedures of derived types, the procedures declared in interface blocks, what submodules declare and contain, and the internal procedures of every procedure, each with its host as the container (`mesh_mod::mesh_t`); fortls offers only the top-level units and what modules declare, with the module as the container.
- A request that the client cancels (`$/cancelRequest`) while it waits behind others is answered with `RequestCancelled` instead of being worked on; fortls ignores cancellations.
- With the `workDoneToken` of the initialize request, indexing reports its progress (`$/progress`, files parsed); fortls reports none.
- Stub actions: on a call of a procedure defined outside any module, an interface block for it after the calling unit's declarations, written from the procedure's source (its USE and IMPLICIT statements and the declarations of its arguments and result, in the caller's source form), replacing the caller's EXTERNAL or type declaration of it, and not offered when an interface is visible already; on a separate module procedure without implementation, its `module procedure` stub in a submodule of its module (a new one at the end of the file when there is none).
- More code actions: "Add IMPLICIT NONE" on the first line of a program unit without IMPLICIT statement, the relational operators `.eq.` ... `.ge.` as `==` ... `>=` and the kinds written with `*` (`real*8`, `character*10`) as kind parameters on the selected lines, and Source Actions putting the keywords of a file in upper, lower or title case (hansec #226, Modern Fortran #234), names spelled like keywords excepted. fortls only implements deferred procedures.
- Refactoring (`refactor.extract`): selected statements of a procedure or program move into a new internal subroutine after `CONTAINS` (of the procedure, or of its host when it is an internal procedure itself), and a CALL replaces them. The procedure's variables they use become its arguments: `intent(in)` when only read, `intent(out)` when first assigned whole and unconditionally and not read, `intent(inout)` otherwise (also when passed to a procedure); arrays of assumed shape (lower bounds kept), characters of assumed length. Refused, with the reason where the editor shows it, when the statements return, EXIT or CYCLE a construct around them, refer to a label outside them or are jumped into, or do not make up whole constructs; free form only.
- An implicitly typed variable (a name used without a declaration where IMPLICIT NONE does not apply) has go to definition, references, document highlights and rename: its first use in the scope is its definition, and a use in a nested scope that does not declare the name is the host's variable when the host uses it too. A rename to a name that is already in use in the scope is refused. These variables are not in the document outline; fortls has none of this.
- Calls of workspace procedures are checked (`argument-mismatch`): too many arguments, a keyword the procedure does not have, an argument given twice, a required (not OPTIONAL) argument missing, and the kind of type (integer, real, complex, logical, character, derived) of an argument, an array for a scalar, a scalar that is no variable or element for an array (not for elemental or assumed-rank). An argument is typed when it is a literal, a variable or a part of one (`a(i)` a scalar, `a(:)` or `a(v)` with an array `v` an array, `p%c`, a substring), or an expression of these with intrinsic operators; one with a function, an intrinsic, a user-defined operator or a derived type in an expression is not checked. Generic interfaces, intrinsics, procedure pointers, alternate returns and procedures whose argument list has preprocessor lines are not checked. When the type is right but its kind differs (`1.0` for a `REAL(dp)` argument), that is an `argument-kind` error, a code of its own, as a compiler option such as gfortran's `-fdefault-real-8` changes the default kinds. Kinds are numbered as gfortran does on x86-64, from kind numbers, `*8`, `DOUBLE PRECISION`, literals (`1d0`, `1_8`), the constants of `ISO_FORTRAN_ENV` and `ISO_C_BINDING`, `KIND()`, `SELECTED_REAL_KIND()`, `SELECTED_INT_KIND()` and the PARAMETERs set from them; a kind none of these gives is not checked. The dummy arguments that a `!DIR$ IGNORE_TKR` of the procedure names (LLVM Flang's and nvfortran's; all of them when it names none) are not checked for what its letters say: type (`t`), kind (`k`), rank (`r`), all three without letters; nor are those that a `NO_ARG_CHECK` of the procedure names (`!GCC$ ATTRIBUTES NO_ARG_CHECK :: x`, gfortran's; `!DIR$` or `!DEC$ ATTRIBUTES NO_ARG_CHECK :: x`, Intel's), for any of the three. Assigning to an INTENT(IN) dummy argument (not a pointer) is an `intent-in-assigned` error. A constant, an expression, a named constant or an INTENT(IN) dummy argument of the caller given for an INTENT(OUT) or INTENT(INOUT) dummy argument of a procedure with an explicit interface is an `argument-not-definable` error (gfortran, Flang and ifx all report it, so every dialect does). A derived type that is another than the dummy argument's (for CLASS, one that does not extend it), a variable that is not ALLOCATABLE for an ALLOCATABLE dummy argument, a function called with CALL and a module or internal subroutine used as a function are `argument-mismatch` errors too, and the array extents of the last two codes of the table below (see Dialects) are checked. fortls checks none of these.
- The modules and submodules of the workspace form a dependency graph: a USE that closes a cycle of modules using each other is a `circular-use` error, and the `zfls/compileOrder` request (the VS Code command "zfls: Show Module Compile Order") lists them in an order to compile them, each after those it uses, with the cycles. fortls has neither.
- The type hierarchy is answered (`textDocument/prepareTypeHierarchy`, `typeHierarchy/supertypes` and `subtypes`), and completion of a component offers the parent components of an extended type (`x%feature_base`, hansec #121); fortls has neither.
- The call hierarchy is answered (`textDocument/prepareCallHierarchy`, `callHierarchy/incomingCalls` and `outgoingCalls`): callers are the procedures around the references in call position (after CALL or before `(`), callees the procedures that the body's names in call position resolve to (the specific of a generic call, the implementation of a separate module procedure); fortls has none.
- `textDocument/inlayHint` is answered: the names of the dummy arguments that positional arguments of calls to workspace procedures go to (not when the argument is that name already, not for intrinsics, not past the first keyword argument), and the types of ASSOCIATE names; fortls has none.
- `textDocument/selectionRange`, `textDocument/documentLink` and `textDocument/prepareRename` (for clients that announce `prepareSupport`) are answered; fortls has none of them.
- `textDocument/typeDefinition` goes to the derived type of a variable or component, of a function's result, or of a type name itself; nothing for intrinsic types and `class(*)`. fortls has none.
- Construct names and statement labels have definitions, references and renames (fortls #424), and `exit`/`cycle` complete the names of the open constructs (hansec #157); fortls has no answer on them. A construct name repeated on an `else`, `case` or `elsewhere` statement is no undeclared name, and `selectcase` written as one word is a SELECT construct.
- At the start of a statement, completion offers the constructs and program units that can begin there, as snippets with their end statement for clients that take snippets (hansec #47): program units outside them and procedures after `contains`, `type`, `interface` and `enum` in a specification part, `do while`, `select case` and the other constructs in an executable part, the blocks of the open construct (`else`, `case`), `then` after `if (...)`, and after `end` only the end statement of the scope that is open. They follow `lowercase_intrinsics` and `autocomplete_no_snippets`. fortls offers none of them.
- `textDocument/linkedEditingRange` is answered: typing in the name of a program unit, derived type or named interface changes it in its END statement too, and the other way round (when the END statement has the name), and a construct name changes at all its places; fortls has none.
- Modules of the same name in several directories are all kept, and each file sees the one its build puts on its module search path, else the nearest (see [Build files](#build-files)); fortls keeps one per name (FL PR #504 has a similar design).
- The Fortran files that `compile_commands.json` compiles outside the workspace root are indexed (hansec #40, hansec PR #99); fortls indexes the source directories only.
- `.f23`, `.ftn`, `.pf` and `.fypp` files are indexed by default, besides fortls's extensions (FL #299, FL #521).
- `workspace/didChangeWatchedFiles` is read: Fortran files created, changed or deleted outside the editor (a checkout, generated code) are parsed again or dropped, except those open in the editor; fortls ignores it.
- The interface modules that ifort and ifx write with `-warn interfaces` (`<name>__genmod.f90`, first line `!COMPILER-GENERATED INTERFACE MODULE`) are not indexed, so their procedures are not listed twice in the workspace symbols; one opened in the editor is served as usual. fortls indexes them (hansec PR #56).
- Settings are taken over LSP as well, under the names of the configuration file: in `initializationOptions` and in `workspace/didChangeConfiguration`, which applies them at once, and the configuration file, `fpm.toml` and `compile_commands.json` are read again when they change (see [Usage](#usage)); fortls reads its settings once, from its command line and configuration file.
- `--debug_parser` and `--debug_preproc` take the command line's preprocessor options (`--pp_defs`, `--include_dirs`, `--pp_suffixes`) with the configuration file's over them, and find the configuration file as the server does; fortls's take them from a configuration file only. The debug log names the final options.
- A user configuration file (`%APPDATA%\zfls\config.json`, `~/.config/zfls/config.json`) gives defaults for every project, under the editor's settings and the project's file (see [Usage](#usage)); fortls has none (FL #408).
- Renaming or moving a file or directory in the editor (`workspace/willRenameFiles`) rewrites the `INCLUDE` statements and `#include` directives that name a file that moves, and the relative ones of a file that moves: relative to the including file's directory when the file was found there, to the include directory it was found in while it stays in it; fortls has none.
- A document is served from the text the client sends with `didOpen` and its changes: a file whose text in the editor is not the one on disk (unsaved changes restored when the editor starts, a new file not saved yet: hansec #123), and a document that is not a file (an untitled one, `untitled:Untitled-1`). Closed without a save, a file is read from disk again, and one that was never saved leaves the workspace. fortls reads every document from disk.
- `compile_commands.json` and `fpm.toml` add include directories and preprocessor definitions (see [Build files](#build-files)).
- Diagnostics have a `code` and the `source` `zfls`, and can be configured and suppressed by code (see [Diagnostics](#diagnostics)).
- There is no automatic update from PyPI; `--disable_autoupdate` is accepted and ignored.
- The intrinsic procedure documentation is a newer M_intrinsics than fortls's, and its links to other procedures open the pages M_intrinsics publishes.
- An intrinsic with several argument lists (`THIS_IMAGE`, `TOKENIZE`) completes to its first, and signature help shows each; fortls's completion mixes the two in one snippet.
- `--recursion_limit` limits the nesting depth of scopes, emulating the recursion error fortls reports for deeply nested code.
- When several files define the same module, program or procedure name, code in one of those files sees its own definition, and other files see one definition chosen however the files were loaded or edited: a workspace file over an intrinsic module, then the file with the lowest path. fortls uses whichever file it parsed last, and parsing either file again loses the name until the other is saved again.
- Links that would loop (for example type-bound procedures or `ASSOCIATE` names that refer to each other while code is being edited) are left unresolved; fortls hits a recursion error on them.
- Go to definition on a preprocessor `#include "file"`, or on a Fortran `INCLUDE 'file'` whose file is not in the workspace, opens the file (searched next to the including file and in `include_dirs`); fortls has no answer.
- `#include <file>` is searched as `#include "file"` is, next to the file and in `include_dirs`; fortls reads only the quoted form. An `#include` whose file is found nowhere gets an `include-not-found` diagnostic (information) on its name, and is taken as an include zfls cannot read: the checks that its macros could make wrong (`argument-not-declared`, `undeclared-name`) are left out in its procedure or, when it is outside procedures, in the scope around it and the procedures after it. fortls says nothing and reports what depends on it as errors.
- An `INCLUDE 'file'` statement is also searched in `include_dirs`, as `#include` is; fortls only looks next to the including file.
- A file that another file `#include`s into a scope sees the names of that scope (as for `INCLUDE` statements, but also for files that hold whole procedures); fortls reports them as unknown in the included file. The procedures of such a file are the including scope's, found there before another file's procedure of the same name.
- A file that an `INCLUDE` or `#include` names is read for its declarations even when it is no source file of the workspace (`.inc`, not in `incl_suffixes`), and so are the files it includes; its own diagnostics are published only while it is open. fortls only links files of the workspace. An include that a statement continues into (the rest of an argument list) is text of that statement, and is not linked.
- The USE statements and the IMPLICIT statement of a file that an `INCLUDE` or `#include` brings in (a header with a project's USE list) apply in the including scope, as if written at the include line; fortls keeps them in the included file, so the names of those modules are unknown there (FL PR #277).
- Hover shows the whole value of a parameter. fortls cuts it at the first parenthesis or bracket, so `selected_real_kind(6)` shows as `selected_real_kind`. It shows it after an entity's own bounds too (`arr(3) = [1, 2, 3]`), with the blanks of its strings (and its strings on a line of several statements, where fortls blanks them), and an entity's own bounds and length (`b(5)` in `real, dimension(3) :: a, b(5)`, `v*8` in `character*(*) u, v*8`, `s(3)[*]*10`) in place of the declaration's.
- The `PARAMETER` statement (`parameter (n = 5)`) makes the variables it names constants, with their values, and the other attribute statements (`dimension v(n)`, `optional :: w`, `intent(in) a`, `allocatable`, `pointer`, `target`, `save`, `codimension`, `contiguous`, `value`, `volatile`, `asynchronous`, `protected`) give their attribute to the names they list, before or after the type declaration, so hover shows it and the argument checks know the arrays and optional arguments. A name they list without a declaration, under implicit typing, is declared by the statement with its implicit type. fortls ignores these statements. A type declaration keeps `VALUE`, `VOLATILE`, `ASYNCHRONOUS` and `PROTECTED`, and the attributes after them, which fortls drops.
- A `BLOCK DATA` unit may end with `END` alone, as FORTRAN 77 sources end it, and the outline lists it (an unnamed one as `BLOCK DATA`); fortls reports the `END` as an unexpected end of scope. That error, where it applies (a `BLOCK` construct closed by `END` alone), is on the `END` line.
- An `ASSOCIATE` name bound to an array element or section shows the dimensions of that element or section; fortls shows those of the whole array.
- An `ASSOCIATE` selector names what the scope around the construct has: in `associate (x => x%field)` the name `x` gets the type of `x%field`, and the selector's `x` is the outer variable in references and rename. A name bound to a literal, an expression of variables and literals or a call of an intrinsic function gets that type (`r => 1.0` is `REAL`) where fortls shows `UNKNOWN`, and a named construct (`outer: associate (...)`) defines its names, which fortls does not see.
- A variable that is declared with a type and then called, `real fff` and `fff(1.2, 3.3)`, shows the signature of the global function of that name in hover, and an `EXTERNAL` name shows the interface of its procedure and has it as its implementation. Signature help, inlay hints, the argument checks, references and rename go through such a declaration to the procedure too, as they do for a call with no declaration (fortls #23, #483): not for a dummy argument of the caller (a dummy procedure), nor when the workspace has no global procedure of the name or more than one.
- A `!>` documentation comment is dropped at an assignment, a `CALL`, `IMPLICIT`, `CONTAINS` or an `END` statement, instead of waiting for the next object.
- A blank line follows a parameter whose documentation ends in a Markdown list in hover, so the next parameter is not shown as part of the list.
- String literals are found from left to right, a literal ending only at its own quote (`'it''s'` doubled), so two strings that each hold the other quote character (`"it's", "Bob's"`) do not hide the code between them from declaration lists, signature help, hover and the argument checks; fortls removes the `'...'` strings before the `"..."` ones.
- References to (and renames of) a separate module procedure include both its interface and its implementation in a submodule; fortls does not relate the two. With the `prefer_implementation` option, hover shows the documentation of that implementation (the interface's when it has none) and go to definition goes to it (fortls #501, #502); fortls always uses the interface. Go to declaration (`textDocument/declaration`, which fortls does not answer) always goes to the interface, also from the body; for other names it does what go to definition does.
- In a function without `RESULT`, the function's name and its result variable are one name for references, document highlights and rename, started from either (fortls #322); fortls keeps them apart, and its rename from inside the body leaves the function statement and the calls with the old name. With `RESULT(r)`, `r` stays separate.
- With the `lowercase_hover` option, the keywords of hover are in lowercase (`real, intent(in) :: x`), names and strings as written (fortls #28); fortls's are always uppercase.
- Hover on a derived type, or on a variable of one, shows the type as it is written: `TYPE, EXTENDS(base) :: name`, its own components, its type-bound procedures and generics after `CONTAINS` (hansec #147). Outside the type's module its private components and bindings are left out, and after 20 lines the block ends with `...`. The `hover_no_type_components` option (`zfls.hoverNoTypeComponents`) turns it off. fortls shows only `TYPE :: name` and the variable's declaration.
- With the `hover_plain_comments` option (`zfls.hoverPlainComments`), plain `!` comments document a declaration that has no `!>`, `!<` or `!!` documentation, as legacy code (LAPACK and the like) is documented: the block of comment lines directly above a procedure, type, module or variable (`C` and `*` lines in fixed form), a comment at the end of its line, and a block right under a procedure's header line. A blank line between, directives (`!$omp`, `!dir$`) and rulers (`!-----`) are no documentation. Hover, completion and signature help show it (hansec #44, #37); fortls reads only `!>`, `!<` and `!!` comments.
- A rename without `ONLY` (`use m, local => original`) is read: the local name is the module's entity and the original name is not visible under that name. On the USE line, hover, definition and references on either name reach the module's entity (hansec #137); fortls only reads renames after `ONLY:` and has no answer on the original name.
- References and document highlights on a name that USE statements rename (`use base, only: loc => origin`) list its places under every name it has, the original and the local ones. Rename changes only the name it starts on: on a module's local name, also where the modules that use that module name it, renaming it again (`use user, only: far => loc`) or not. A name renamed in two modules in a row resolves with or without `ONLY`. fortls lists only the places of the original name and renames a local name only in the scope of its USE statement (fortls #52).
- A module passes on the names it has by USE as the Fortran standard says: with `private` as its default, only those a `public` statement names, and never those a `private` statement names. fortls applies a module's default only to its own declarations, so names hidden behind a facade module get hover and completion and are not reported as undeclared (fortls PR #562).
- `SUBMODULE (ancestor:parent) name` is named `name` and extends its parent submodule (and through it the ancestor module); fortls names it `parent`.
- A main program without a `PROGRAM` statement (the statements before an `END` outside every program unit) is a program unit named `main` in the outline, its `IMPLICIT` and `CONTAINS` apply to it, and the procedures after its `END` are external ones. fortls reports its `IMPLICIT` as outside any scope and each procedure after it as defined before `CONTAINS`.
- Of several scopes that open on one line (`do i = 1, n; associate (p => a(i))`), the last is the innermost, so the names it declares are found; fortls uses the first.
- The lines of an inactive preprocessor branch inside a continued statement (`REAL &` / `#ifdef X` / `, POINTER &` / `#endif`) are left out of it; fortls joins them, so the declaration gets the attributes of every branch.
- Comment lines, blank lines and preprocessor directives between the lines of a continued statement (`call foo(a, &` / `! the rest` / `b)`) do not end it, in either source form: signature help, completion and hover see the whole statement, and a fixed-form declaration continued after a comment line declares all its names. fortls ends the statement at such a line.
- A function-like macro without parameters (`#define NOARG() 42`) expands to its value, and a macro's value is used as written; fortls reads it as a regex template, so `\1` in it and, for `NOARG()`, its digits are lost (FL #486).
- In a macro's value, `a ## b` pastes the two words together and `#x` is the argument in double quotes; `/**/` is removed from macro values and the lines of a preprocessed file, as gfortran's cpp does, so `wrap_/**/P` is the name `wrap_abc`. Character literals and comments are left as they are. fortls keeps `##`, `#x` and `/**/` in the text.
- A file named as free-form source (`.f90`, `.F90`, `.f08`, ...) is read as free form, as compilers read it. fortls decides from the text alone, and takes a file with no line indented 1 to 4 columns (the Fortran stdlib's, indented 5) for fixed form. Other files are still told by their text.
- A document the editor opens as `FortranFixedForm` or `FortranFreeForm` (the languages of the VS Code extension, also set there with `files.associations` or the language picker) is read in that form while it is open, whatever its name and text say, and the compiler checks it in that form (Modern Fortran #200, #222, #460, #904, #1131). Any other language identifier (`fortran`, `fortran90`) leaves the form to the name and the text, and so do the files that are not open, but for a `.fpp` file that `file_associations` (VS Code's `files.associations`) gives a form. fortls does not read the language identifier.
- A form feed (a page break of old sources) is read as a blank, as compilers read it; fortls drops the statement of a line that starts with one (fortls #443).
- The enumerators of an ENUM are named integer constants of the surrounding scope, with hover, definition and completion, PUBLIC or PRIVATE by name; fortls does not read them.
- In each block of a SELECT RANK, its associate name (`select rank (v => a)`) is the selector; fortls does not read SELECT RANK.

## Licenses

zfls is distributed under the MIT license, see `LICENSE`, except for the ifx kit's startup code (`src/ifxkit/shim.zig`, `src/ifxkit/cxx.zig`), which is under MIT No Attribution (MIT-0) because it is linked into the programs built with the kit; the kit's import libraries come from MinGW-w64's public-domain definition files. ifx itself is Intel's, under Intel's license, which `zfls setup-ifx` shows and which the user accepts. zfls is derived from fortls and its predecessor fortran-language-server, also MIT licensed, whose copyright notices `LICENSE` includes. The intrinsic procedure documentation comes from the [M_intrinsics](https://github.com/urbanjost/M_intrinsics) project, also MIT licensed, whose notice `LICENSE` includes too: the `vendor/M_intrinsics` submodule, which a scheduled workflow moves to upstream latest commit. The Windows builds include the Win32 API bindings of [zigwin32](https://github.com/marlersoft/zigwin32), which rstd vendors, also MIT licensed, whose notice `LICENSE` includes as well.
