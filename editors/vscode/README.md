# zfls for VS Code

Fortran language support powered by [zfls](https://github.com/cesiumlang/zfls), a fast native reimplementation of the [fortls](https://github.com/fortran-lang/fortls) language server:

- completion, hover, signature help
- go to definition, implementation and type definition, find references, rename
- document and workspace symbols, with an outline tree for breadcrumbs and sticky scroll
- folding of program units, constructs (each `IF`, `SELECT` and `WHERE` branch on its own too), statements continued over three lines or more, preprocessor conditionals and comment blocks
- semantic highlighting: names colored by what they stand for (procedures, types, dummy arguments, components, variables named like keywords), and the branches of preprocessor conditionals that are left out shown as inactive
- untitled (new, unsaved) Fortran files too, served by the first folder's server
- Fortran files changed outside VS Code (a checkout, generated code) are indexed again, and the settings read again when `.fortlsrc`, `.fortls.json`, `.fortls`, `fpm.toml` or `compile_commands.json` changes, without a restart
- diagnostics, a compiler's errors and warnings (see [Compiler diagnostics](#compiler-diagnostics)), fortitude's problems with its fixes (see [Linting with fortitude](#linting-with-fortitude)), and Codee's checks (see [Codee checks](#codee-checks))
- syntax highlighting for free-form and fixed-form Fortran, with OpenMP and OpenACC directives, and Fortran code in documentation comments (a block from `` !> ```fortran `` to `` !> ``` ``)
- namelist files (`.nml`, `.namelist`): highlighting, folding of each group, and an outline of the groups and the variables they set (from zfls, which does not read them as Fortran)
- snippets for program units and constructs (see [Snippets](#snippets))
- indentation as you type: a line after the start of a program unit, procedure (with its prefixes: `pure`, `integer`, ...), derived type, interface or construct (named or not) is indented, and an END, ELSE, CASE, CONTAINS, TYPE IS, ... is outdented as you type it; keywords in comments and strings are ignored. A `module procedure` line does not indent the next one (in an interface block it has no body)
- formatting of documents and selections with findent or fprettify (see [Formatting](#formatting))
- Fortran and C: go to definition of a `BIND(C)` procedure gives its C declarations too, and find references its C calls (from clangd or Microsoft's C/C++, when one is installed, and from zfls's own search of the workspace's C files); on a name in a C or C++ file, go to definition gives the Fortran procedures that bind it and find references their Fortran calls, even before a Fortran file is opened
- a debugger of its own, for programs that gdb debugs: arrays by their subscripts, derived types and polymorphic objects as Fortran shows them, module variables, stopping on Fortran runtime errors (see [zfls's debugger](#zflss-debugger)); breakpoints in Fortran files for the other debuggers too, such as C/C++ (cppdbg, cppvsdbg) and CodeLLDB
- code lenses: the number of references above each module, procedure and derived type (click it for the references), and **Run** and **Debug** above a program
- run and debug the current file with one click (see [Running and debugging](#running-and-debugging))
- fpm projects: tasks, running and debugging their targets, and their tests in the Testing view (see [fpm projects](#fpm-projects))
- pFUnit's tests in the Testing view, for CMake projects (see [pFUnit tests](#pfunit-tests))
- a Fortran file icon, in file icon themes that use the language's icon

The extension includes the `zfls` executable for Windows, Linux and macOS (x64 and ARM64). Nothing else needs to be installed.

It replaces the Modern Fortran extension rather than working alongside it: disable Modern Fortran when you install zfls (see [Replacing Modern Fortran](#replacing-modern-fortran)).

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.path` | empty | A `zfls` to run instead of the bundled one, or the directory that holds it |
| `zfls.incrementalSync` | `true` | Send document changes incrementally |
| `zfls.signatureHelp` | `true` | Signature help while typing arguments, instead of argument snippets |
| `zfls.codeActions` | `true` | Code actions, such as implementing deferred type-bound procedures |
| `zfls.docMath` | `plain` | Formulas of documentation comments (`\f$ x \f$`) in backticks without their markers; `dollar` writes `$x$` for a renderer with math, `keep` leaves them |
| `zfls.hoverSignature` | `true` | Hover on an argument of a call also shows the dummy argument it is passed to |
| `zfls.lowercaseHover` | `false` | Keywords in hover in lowercase (`real, intent(in) :: x`) |
| `zfls.hoverNoTypeComponents` | `false` | Hover on a derived type or a variable of one does not list the type's components and type-bound procedures |
| `zfls.hoverPlainComments` | `false` | Plain `!` comments above a declaration, at the end of its line or right under a procedure's header are its documentation when it has no `!>`, `!<` or `!!` comment |
| `zfls.preferImplementation` | `false` | Hover and go to definition use a separate module procedure's body in its submodule, not its interface |
| `zfls.lowercaseIntrinsics` | `true` | Complete intrinsics and keywords in lowercase |
| `zfls.autocompleteNameOnly` | `false` | Complete procedure names without their arguments |
| `zfls.autocompleteNoSnippets` | `false` | No placeholders in completions |
| `zfls.autocompleteNoAutoUse` | `false` | Do not offer names of modules not used yet (completing one adds its `use` statement) |
| `zfls.sortKeywords` | `false` | Sort variable keywords in hover |
| `zfls.symbolSkipMembers` | `false` | Leave type members out of document symbols |
| `zfls.codeLensNoReferences` | `false` | No reference counts above modules, procedures and types (`editor.codeLens` turns off every lens) |
| `zfls.codeLensNoRun` | `false` | No **Run** and **Debug** above a program |
| `zfls.disableDiagnostics` | `false` | Turn off zfls's diagnostics |
| `zfls.workspaceDiagnostics` | `false` | Problems of every workspace file, not only the open ones |
| `zfls.diagnosticsChangeDelay` | `300` | Milliseconds without a change before the problems of a file that is edited are updated (0: with each change); for other editors only, since VS Code asks zfls for them itself when it wants them |
| `zfls.diagnosticSeverity` | none | Severity of diagnostics by code, `off` to hide them |
| `zfls.externalModules` | none | Modules from outside the project (MPI, ...) that `USE` may name |
| `zfls.notifyInit` | `false` | Notify when the workspace has been indexed |
| `zfls.nthreads` | zfls's (4) | Threads used for indexing |
| `zfls.maxLineLength` | `-1` (off) | Warn about longer code lines |
| `zfls.maxCommentLineLength` | `-1` (off) | Warn about longer comment lines |
| `zfls.fixedFormLineLength` | `72` | Columns of code in a fixed-form line (80 or 132 for longer cards); the rest is shown as a comment |
| `zfls.fixedFormCommentCharacter` | `!` | The character **Toggle Line Comment** (`Ctrl+/`) puts in column 1 of a fixed-form line: `C`, `c` or `*` (`!`: VS Code's own toggle) |
| `zfls.fixedFormDLines` | `comment` | How a fixed-form line with `D` or `d` in column 1 (a debug line) is read: as a `comment`, or as `code`; zfls reads it so, and the compiler check passes the option that reads it so (gfortran `-fd-lines-as-code`, Intel `-d-lines`) unless `zfls.linter.extraArgs` has one |
| `zfls.configFile` | empty | Configuration file instead of `.fortlsrc` / `.fortls.json` / `.fortls` |
| `zfls.sourceDirs` | the workspace folder | Folders with source files (globs allowed) |
| `zfls.includeDirs` | none | Folders searched for `#include` and `INCLUDE` files |
| `zfls.compileCommands` | `compile_commands.json` in the folder or `build/` | Compilation database adding include folders and definitions |
| `zfls.excludePaths` | none | Folders not to index |
| `zfls.commentMarkers` | none | Further markers that start a comment as `!` does, such as `;*`; zfls reads them as comments, and they are highlighted as comments after a window reload |
| `zfls.disableOpenmpConditional` | `false` | Read OpenMP conditional compilation lines (`!$ x = 1`) as comments, as a build without OpenMP does; by default they are code |
| `zfls.includeSuffixes` | none | More file extensions to index, e.g. `.inc` |
| `zfls.excludeSuffixes` | none | File extensions not to index |
| `zfls.ppSuffixes` | upper-case extensions | File extensions to preprocess |
| `zfls.ppDefs` | none | Preprocessor definitions, name to value |
| `zfls.disableIntelDirectives` | `false` | Read Intel's conditional compilation directives (`!DEC$ IF DEFINED (X)`) as comments, every branch included |
| `zfls.arguments` | none | Extra command-line options (`zfls --help`) |
| `zfls.disableModernFortranCheck` | `false` | Do not recommend disabling the extensions zfls replaces (Modern Fortran, ...) when they are enabled |
| `zfls.trace.server` | `off` | Log the language server messages in the `zfls` output channel |
| `zfls.formatting.formatter` | `Disabled` | `findent`, `fprettify`, `codee`, `forformat` or `custom` to format Fortran files (see [Formatting](#formatting)) |
| `zfls.formatting.path` | empty | The formatter, or its directory, when it is not on the `PATH` |
| `zfls.formatting.findentArgs` | `[]` | Extra arguments for findent |
| `zfls.formatting.fprettifyArgs` | `[]` | Extra arguments for fprettify |
| `zfls.formatting.codeeArgs` | `[]` | Extra arguments for `codee format` |
| `zfls.formatting.forformatArgs` | `[]` | Extra arguments for forformat |
| `zfls.formatting.customArgs` | `[]` | The arguments of the custom formatter (`${file}`, `${form}`) |
| `zfls.run.*` | | Compiler, arguments and debugger for running and debugging a file (see [Running and debugging](#running-and-debugging)) |

Each setting becomes the fortls option of the same meaning (the settings' descriptions name them). Path settings expand `${workspaceFolder}`, `${workspaceFolder:name}`, `${userHome}`, `${env:NAME}` and a leading `~`, and every setting can differ per workspace folder. A running language server takes a changed setting at once (sent with `workspace/didChangeConfiguration`): one that decides what is indexed (`zfls.sourceDirs`, `zfls.includeDirs`, `zfls.ppDefs`, ...) has it index the workspace again. The server restarts instead when `zfls.path`, `zfls.arguments`, `zfls.incrementalSync` or `zfls.configFile` changes, when `zfls.arguments` holds any options (they may set what a setting does), when a setting goes back to empty where zfls's default cannot be sent (`zfls.sourceDirs`), and when signature help, code actions or formatting are turned off.

As with fortls, a `.fortlsrc`, `.fortls.json` or `.fortls` file in the workspace root configures source directories, preprocessor definitions and other options. zfls also reads a user configuration file of the same format, `%APPDATA%\zfls\config.json` on Windows, else `~/.config/zfls/config.json` (`$XDG_CONFIG_HOME/zfls/config.json`), for other editors; this extension's settings take over from it, and the project's file from both. VS Code opens these files as JSON with comments and checks them against a schema of the options zfls reads from them, with their descriptions and defaults in completion and hover. The schema is generated from zfls's option table (`zig build generated`).

With a TOML extension that supports `tomlValidation`, such as [Even Better TOML](https://marketplace.visualstudio.com/items?itemName=tamasfe.even-better-toml), `fpm.toml` files are checked against the [fpm manifest schema](https://github.com/fortran-lang/fpm-metadata) too.

## Workspaces with several folders

Each top-level folder of a multi-root workspace gets its own zfls, rooted at that folder and configured by that folder's settings and `.fortlsrc`; a folder inside another one is part of the outer one. A Fortran file outside every folder gets a zfls rooted at its own directory.

## Replacing Modern Fortran

zfls is a replacement for the [Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran) extension, not a companion to it. Both register the same Fortran language IDs, grammars and snippets, and Modern Fortran starts its own language server (fortls) and compiler linting, so with both enabled they compete for Fortran files and you get duplicate completions, hovers and diagnostics.

When Modern Fortran is enabled, zfls recommends disabling it and opens its page in the Extensions view, where you select **Disable** (an extension cannot disable another one), then reload the window.

If you want to keep Modern Fortran installed for now, you can choose **Keep it, turn off its fortls and linter** instead: that stops only Modern Fortran's language server (`fortran.fortls.disabled`) and its compiler linting (`fortran.linter.compiler`), so zfls answers the language requests and shows the compiler's messages while Modern Fortran keeps its other commands. Its grammars still apply alongside zfls's in that case.

zfls recommends disabling these extensions in the same way, as it does what they do: Modern Fortran under its old ID (`krvajalm.linter-gfortran`, the same languages and grammars, and linting), FORTRAN IntelliSense (`hansec.fortran-ls`, a language server of its own, so each completion and hover comes twice) and Fortran Breakpoint Support (`ekibun.fortranbreaker`, breakpoints in Fortran files). **Don't ask again** (`zfls.disableModernFortranCheck`) stops the recommendation for all of them.

## Compiler diagnostics

When a Fortran file is opened or saved, zfls has a compiler check it (without generating code) and shows the compiler's errors and warnings in the file and in the Problems panel, labeled with the compiler's name. They are cleared when the file is closed or compiler diagnostics are turned off. By default, the compiler is gfortran; if it is not installed, zfls says so once and checks nothing.

| Compiler (`zfls.linter.compiler`) | Runs | Options zfls passes |
| --- | --- | --- |
| `gfortran` | `gfortran` | `-fsyntax-only -fno-diagnostics-show-caret -fdiagnostics-color=never -ffree-form -ffree-line-length-none`/`-ffixed-form -ffixed-line-length-N -fd-lines-as-comments` (or `-fd-lines-as-code`), `-cpp` for a preprocessed file, `-J<dir>`, and `-Wall -fcoarray=single -fopenmp` by default (`-fopenmp` while OpenMP's conditional lines are read as code), then `-x f95 <file>`, which checks a file of any suffix (`.f77`, `.f18`, `.pf`, ...) |
| `ifx`, `ifort` | `ifx`, `ifort` | `-syntax-only -fpp -free`/`-fixed -extend-source N -module <dir>`, and `-warn all,nodeclarations,noexternals -coarray=single -qopenmp` by default, then `-Tf <file>`, which checks a file of any suffix (`.f08`, `.f77`, `.pf`, ...) (on Windows `/syntax-only /fpp /free`/`/fixed /extend-source:N /module:<dir>`, `/warn:all,nodeclarations,noexternals /Qcoarray:single /Qopenmp`, `/Tf <file>`) |
| `nagfor` | `nagfor` | `-M -quiet -fpp -free`/`-fixed` (`-132` for 132 columns) `-mdir <dir> -I <dir>` |
| `lfortran` | `lfortran` | `--semantics-only --continue-compilation --error-format=short --cpp`, `--fixed-form` for fixed form, `-J <dir>`, `--implicit-typing --implicit-interface` unless your options say otherwise or choose a `--std`; the modules a file uses are compiled with `--symtab-only -c -o <dir>/zfls-lint.o`, which writes their `.mod` files |
| `nvfortran` | `nvfortran` | `-c -Mpreprocess -Mfree`/`-Mfixed` (`-Mextend` for 132 columns) `-module <dir>`, and `-Minform=warn` by default; nvfortran has no syntax-only mode, so it compiles, writing the object file into `<dir>` |
| `flang` | `flang`, else `flang-new` | `-fsyntax-only -cpp -ffree-form`/`-ffixed-form -ffixed-line-length=N -module-dir <dir>`, and `-Wunused-variable -Wused-undefined-variable` by default with Flang 22 and later (older Flangs have neither) and `-fopenmp`, then `-x f95 <file>`, which checks a file of any suffix (`.cuf`, `.f77`, `.f18`, ...) |
| `Disabled` | | No compiler diagnostics |

`N` is `zfls.fixedFormLineLength` (Intel takes 72, 80 or 132). A line-length option of your own in `zfls.linter.extraArgs` replaces zfls's.

Whether a file is free or fixed form follows its language in VS Code (`FortranFreeForm` or `FortranFixedForm`, from the file extension or `files.associations`), not the compiler's guess from the extension. The server reads an open document in that form too. A file that is not open has the form of its name and text, so give a fixed-form source a fixed-form extension, or one that says neither (`.inc`), when other files use what it declares.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.linter.compiler` | `gfortran` | The compiler, or `Disabled` |
| `zfls.linter.compilerPath` | empty | The compiler executable, when it is not the one on the `PATH` |
| `zfls.linter.extraArgs` | `[]` | Further options, such as `-std=f2018`; when set, they replace the default warning options |
| `zfls.linter.fixedCompiler` | empty | The compiler of fixed-form files, when it is another (or `Disabled`); empty: `zfls.linter.compiler`. The modules a file uses are compiled with the file's compiler |
| `zfls.linter.fixedCompilerPath` | empty | Its executable; empty: `zfls.linter.compilerPath` |
| `zfls.linter.fixedExtraArgs` | `null` | Its options; `null`: `zfls.linter.extraArgs`, `[]`: its default warnings |
| `zfls.linter.includePaths` | `[]` | Directories for `INCLUDE` and `.mod` files (`-I`); glob patterns such as `${workspaceFolder}/build/**/include` |
| `zfls.linter.modOutput` | empty | Where the compiler writes `.mod` files; empty means a directory in zfls's cache for the workspace, never the source tree |
| `zfls.linter.lintOnSave` | `true` | Check files when they are saved |
| `zfls.linter.lintOnType` | `false` | Check files while they are edited (a copy of the unsaved text is compiled) |
| `zfls.linter.lintOnTypeDelay` | `1000` | Milliseconds after the last change before such a check |
| `zfls.linter.resolveModules` | `true` | Build the modules a file uses first (see below) |
| `zfls.linter.noCompileCommands` | `false` | Do not check a file with its command's options from `compile_commands.json` (see below) |
| `zfls.linter.fypp.enabled` | `false` | Run [fypp](https://fypp.readthedocs.io) on files first; `.fypp` files are only checked with it |
| `zfls.linter.fypp.path` | `fypp` | The fypp executable |
| `zfls.linter.fypp.definitions` | `{}` | fypp definitions (`-DNAME=VALUE`) |
| `zfls.linter.fypp.includes` | `[]` | fypp include directories |
| `zfls.linter.fypp.extraArgs` | `[]` | Further fypp options |

Path settings resolve `${workspaceFolder}`, `${workspaceFolder:name}`, `${env:VAR}`, `${userHome}` and a leading `~`; relative paths are relative to the workspace folder. There is no `${file}`: these settings are the language server's, one per workspace folder, not one per file.

How it behaves:

- **Modules.** A file that uses a module needs that module's `.mod` file. Before checking a file, zfls compiles the workspace files that define the modules it uses (those modules' own dependencies first), where their `.mod` files are missing or older than the files, and saving a module file checks the open files that use it again. Modules that come from outside the workspace need their `.mod` directory in `zfls.linter.includePaths`. A module whose file does not compile cannot be used; the file using it then shows the compiler's error about the missing module.
- **The project's options.** When `zfls.linter.extraArgs` is empty and `compile_commands.json` has a command for the file (or for another file in its folder), the file is checked with that command's options (its `-std`, `-fdefault-real-8`, `-ffree-line-length-none`, `-D`, `-I`, ...), in that command's directory, and with its compiler when that is the configured one; zfls's own syntax-only and module directory options stay, and the command's `-c`, `-o`, module directory and dependency files are left out. `zfls.linter.noCompileCommands` turns this off.
- **Included files.** An error in a file brought in by `INCLUDE` or `#include` shows at that `INCLUDE` line, prefixed with the included file's name and line, with a link to the place in the included file. For a file included by an included file, the line is the outer `INCLUDE`, with a link to each one in between. Flang says which line includes the file; for gfortran, ifx and ifort, zfls finds it.
- **One compiler at a time.** Checks run one after another, and a newer check of a file replaces one that has not started, so that autosave does not pile up compiler processes. A check of edits waits for `zfls.linter.lintOnTypeDelay` milliseconds without a change.
- **No duplicates.** Each message shows once, even if the compiler prints it twice.
- **Clearing.** **zfls: Clear Compiler Diagnostics** clears the messages and the `.mod` files in zfls's cache (not those in a configured `zfls.linter.modOutput`). **zfls: Lint Current File with Compiler** checks the active file now, its text in the editor.

The zfls language server runs the compiler (its `compiler_diagnostics` options, which other editors use too); these settings become those options, and a change applies to the next check. Besides `zfls.linter.includePaths`, the compiler gets zfls's include directories (`zfls.includeDirs`, and those of `compile_commands.json` and `fpm.toml`) and its preprocessor definitions. Glob patterns in the include paths are expanded when zfls starts and when the settings change. The compiler's output is in zfls's log (its `debug_log` option) in the `zfls` output channel.

## Linting with fortitude

With `zfls.fortitude.enabled`, [fortitude](https://fortitude.readthedocs.io) checks a Fortran file when it is opened and saved (also while it is edited, with `zfls.fortitude.lintOnType`), and its problems show as warnings labeled `fortitude`, each code linking to its rule's documentation. Its fixes are quick fixes (the unsafe ones say so), and **zfls: Fix All Safe fortitude Problems** applies every safe fix; for fixes on save, add `"source.fixAll.fortitude": "explicit"` to `editor.codeActionsOnSave`. fortitude reads the unsaved text, and its rules from `fpm.toml` or `fortitude.toml` above the file. Install it with `pip install fortitude-lint`. The zfls language server runs it (its `fortitude` options, which other editors use too); these settings become those options.

| Setting | Default | Description |
| --- | --- | --- |
| `zfls.fortitude.enabled` | `false` | Lint with fortitude |
| `zfls.fortitude.path` | `fortitude` on the `PATH` | The fortitude executable, or its directory |
| `zfls.fortitude.args` | `[]` | Extra arguments for `fortitude check` (`--select`, `--preview`, ...) |
| `zfls.fortitude.lintOnType` | `false` | Also lint while the file is edited |
| `zfls.fortitude.lintOnTypeDelay` | `500` | Milliseconds without changes before linting |

## Codee checks

With `zfls.codee.enabled`, the checks of [Codee](https://www.codee.com), a commercial analyzer of Fortran correctness, modernization and performance (installed and licensed separately), show in the file and in the Problems panel when it is opened and saved: `codee checks --json` on the file as saved. Each check links to its page of Codee's Open Catalog. Its defects (`PWD...`) are errors, its recommendations (`PWR...`) warnings and its remarks (`RMK...`) hints, as in Codee's own editor integrations.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.codee.enabled` | `false` | Run Codee on Fortran files |
| `zfls.codee.path` | empty | The codee executable, or its directory |
| `zfls.codee.args` | `[]` | More arguments, before the file: `["-p", "build/compile_commands.json"]`, or with `${file}` where the file goes, `["${file}", "--", "gfortran", "-O2", "${file}"]` |

The zfls language server runs it (its `codee` options, which other editors use too); these settings become those options. This support follows Codee's documentation of its output: zfls has not been tested with Codee itself.

## Formatting

**Format Document**, **Format Selection** and format on save (`editor.formatOnSave`) use an external formatter, which must be installed separately:

| Formatter | Install | Formats |
| --- | --- | --- |
| [findent](https://pypi.org/project/findent/) | `pip install findent` or `conda install -c conda-forge findent` | Indentation of free-form and fixed-form files |
| [fprettify](https://github.com/fortran-lang/fprettify) | `pip install fprettify` or `conda install -c conda-forge fprettify` | Indentation, whitespace and more, free-form files only |
| [Codee](https://www.codee.com) (`codee`) | Codee's installer; the `codee` of `zfls.codee.path` is used unless `zfls.formatting.path` is set | Its formatter, `codee format`, on whole files |
| forformat | as its project says | Whole files |
| `custom` | your own: `zfls.formatting.path` with `zfls.formatting.customArgs` | What your command does with the source on its standard input |

Choose one with `zfls.formatting.formatter`; it is `Disabled` by default, so that no formatter runs, and VS Code offers formatters of other extensions, until one is chosen. The setting can differ per language, for example fprettify for free form and findent for fixed form:

```jsonc
"zfls.formatting.formatter": "fprettify",
"[FortranFixedForm]": {
  "zfls.formatting.formatter": "findent"
}
```

The zfls server runs the formatter (its `formatter` options, which these settings set; other editors set them in a configuration file, see the [zfls readme](https://github.com/cesiumlang/zfls#formatting)). It sends the text to the formatter on its standard input and reads the result from its standard output, so no files are written, and changes only the lines the formatter changed. findent is told the source form of the file (`-ifree` or `-ifixed`) unless `zfls.formatting.findentArgs` sets one. fprettify reads `.fprettify.rc` files from the directory of the file and its parents, as when it formats the file itself. A change of these settings applies to the next formatting; turning formatting off restarts the server, so that VS Code stops offering it. In `zfls.formatting.path` and the argument settings, `${workspaceFolder}`, `${workspaceFolder:name}`, `${userHome}`, `${env:NAME}` and a leading `~` are expanded; an argument with a space in it stays one.

**Format Selection** formats the whole lines the selection touches. The formatter sees only those lines, not the surrounding code: findent starts at the indentation of the first selected line (`-Ia`), and fprettify keeps it too, but select whole constructs (a complete `do` loop, `if` block or procedure) for the indentation inside them to come out right.

When the formatter is missing, fails, or prints nothing, the document is left as it is, and the error is shown once, with details in the `zfls` output channel (**zfls: Show Output**).

## Running and debugging

The **Run Fortran File** and **Debug Fortran File** buttons in the editor title (also commands, **zfls: Run Fortran File** and **zfls: Debug Fortran File**) build the file in the editor, saving it first, and then run it in a terminal, or start the debugger on it. Programs of a single file are the aim: the directory of the file is on the include path, but other source files are not compiled. In an fpm project, they run the target the file is the main program of with fpm instead (see [fpm projects](#fpm-projects)). For other projects, use a build system and a launch configuration of your own.

The build uses `zfls.run.compiler` (`gfortran` by default) with debug information and no optimization. The program and the compiler's module and object files go into the extension's storage, a directory per source file, not next to the sources, unless `zfls.run.outputDirectory` says where. On Windows the compiler's directory is put first on the program's `PATH`, for its runtime libraries.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.run.compiler` | `gfortran` | The compiler: `gfortran`, `ifx`, `ifort`, `flang`, `nvfortran`, `nagfor`, `lfortran`, ... |
| `zfls.run.compilerPath` | empty | The compiler, or its directory, when it is not on the `PATH` |
| `zfls.run.buildArgs` | not set | Compiler arguments; not set: `-g -O0` (`/Zi /Od` for `ifx` and `ifort` on Windows; `-g -O0 -static-libgfortran -static-libquadmath` for `gfortran` on Windows, so that the debugger stops at the errors its runtime raises (gdb reads no symbols of `libgfortran-5.dll`); `-gdwarf-4 -O0 -Wl,-debug:dwarf` for `flang` on Windows, for gdb, where there is an `lld-link`; `-g` for `lfortran`, and none for `lfortran` on Windows: its build from conda-forge lacks the runtime stacktrace that `-g` needs, and refuses it). The extension adds the include path, the output file and the source |
| `zfls.run.outputDirectory` | empty | Where the program and the module files go |
| `zfls.run.programArgs` | `[]` | Arguments for the program |
| `zfls.run.cwd` | `${fileDirname}` | The working directory of the program |
| `zfls.run.debugger` | `auto` | `zfls`, `cppdbg`, `cppvsdbg`, `lldb` or `gdb`; `auto`: zfls's own when there is a gdb for it (on macOS an lldb-dap), and for the programs of ifx and ifort on Windows, else an installed one |
| `zfls.run.gdbPath` | empty | The `gdb` for `zfls`, `cppdbg` and `gdb`; empty: the one next to the compiler, else on the `PATH`. On macOS, set: zfls's debugger runs this gdb, not lldb-dap |

`${workspaceFolder}`, `${env:NAME}`, `${userHome}`, `${file}`, `${fileDirname}` and a leading `~` are expanded in these settings.

With `zfls.run.debugger` set to `auto`, debugging uses zfls's own debugger when there is a gdb for it (gdb 14 or later, built with Python, as MSYS2's, Ubuntu's since 24.04 and most others are; on macOS an lldb-dap, which Xcode's command line tools have), and on Windows for the programs of `ifx` and `ifort`, with Windows's own Debugger Engine (see [zfls's debugger](#zflss-debugger)); else the first installed of these extensions:

| Extension | Debugger | For |
| --- | --- | --- |
| [C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools) | `cppdbg` | gdb (lldb on macOS): gfortran, Intel on Linux, flang, ... |
| [C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools) | `cppvsdbg` | The Visual Studio debugger: `ifx` and `ifort` on Windows, LLVM Flang's programs built with `-g` |
| [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb) | `lldb` | lldb |
| [CDT GDB Debug Adapter](https://marketplace.visualstudio.com/items?itemName=eclipse-cdt.cdt-gdb-vscode) | `gdb` | gdb |

If there is none, **Debug Fortran File** says which to install. gdb cannot debug the programs of `ifx` and `ifort` on Windows (their debug information is Microsoft's: zfls's debugger then uses Windows's Debugger Engine), nor run on macOS on Arm, where lldb, which knows no Fortran, is the debugger.

LLVM Flang's `-g` on Windows also writes Microsoft's debug information only. **Debug Fortran File** builds with `-gdwarf-4`, which writes DWARF too and has Flang link with `lld-link`, and `-Wl,-debug:dwarf`, with which `lld-link` keeps the DWARF in the program (and the PDB beside it): gdb, and so zfls's debugger, reads it as it reads gfortran's programs. Without an `lld-link` (next to `flang` or on the `PATH`) the build is `-g -O0`, for Windows's Debugger Engine. A `fortran` configuration of a program built with `-g` takes `"dbgeng": true` for the engine. Debugging an fpm target built with Flang adds `-gdwarf-4 -Wl,-debug:dwarf` to fpm's flags (`--flag`, which fpm passes to the link too) where there is an `lld-link`, unless `zfls.fpm.flags` already has a `-gdwarf`, and debugs it with gdb; without an `lld-link`, fpm's `-g` build goes to the engine.

With Intel's compilers on Windows, start VS Code from a oneAPI command prompt (or after `setvars.bat`), so that the compiler finds the linker and libraries, or set up ifx without Visual Studio:

### ifx without Visual Studio (Windows x64)

**zfls: Set Up ifx (Intel Fortran) without Visual Studio** sets up Intel's ifx from Intel's Fortran offline installer for Windows, which you download from [Intel](https://www.intel.com/content/www/us/en/developer/tools/oneapi/fortran-compiler-download.html) (the command opens the page): it shows Intel's license from the installer and, once you accept it, unpacks the compiler without running the installer (no administrator rights, nothing registered, about 210 MB in `%LOCALAPPDATA%\zfls\ifx`) and sets it up to link with its own `lld-link` and zfls's ifx kit instead of Visual Studio's linker and libraries. It then offers to set `zfls.run.compiler`, `zfls.run.compilerPath` and `zfls.fpm.compiler` to it. Programs are built with `/MD` (the C runtime of Windows), and zfls's debugger debugs them. The same is `zfls setup-ifx` on the command line (see zfls's readme).

### LFortran without Visual Studio (Windows x64)

LFortran links its programs on Windows with Visual Studio's `link`. Where Visual Studio's environment is not set up (no `VCToolsInstallDir`), **Run Fortran File** has it link with `lld-link` and zfls's ifx kit instead, when there is an `lld-link` next to `lfortran` (conda-forge's `lld` package: `conda install -c conda-forge lfortran lld`, or `pixi add lfortran lld`) or on the `PATH`. The extension writes a `link.cmd` that runs that `lld-link` into its storage, puts it first on the build's `PATH`, and sets `LIB` and `LINK` to the kit's directory, startup object and libraries; **zfls: Add Build Task and Debug Configuration for Fortran File** writes the same into the build task. The programs use Windows's C runtime (UCRT) and LFortran's static runtime, so they need nothing else to run.

### LLVM Flang without Visual Studio (Windows x64)

LLVM Flang too links with Visual Studio's `link` and libraries, which it finds by itself. Where Visual Studio's environment is not set up (no `VCToolsInstallDir`), **Run Fortran File** has it link with `lld-link` and zfls's ifx kit instead, when there is an `lld-link` next to `flang` (conda-forge's `flang_win-64` brings `lld`: `conda install -c conda-forge flang_win-64`, or `pixi add flang_win-64`) or on the `PATH`. It adds `-fms-runtime-lib=dll -fuse-ld=lld` to the build (Windows's C runtime in DLLs, and `lld-link`), and sets `LIB` and `LINK` to the kit's directory, startup object and libraries, as the build task of **zfls: Add Build Task and Debug Configuration for Fortran File** does. With `LIB` set, neither Flang nor `lld-link` looks for Visual Studio's libraries. The programs use Windows's C runtime, and Flang's runtime is linked into them, so they need nothing else to run. When `zfls.run.buildArgs` choose the linker (`-fuse-ld=`) or the C runtime (`-fms-runtime-lib=`), the extension leaves the link to them.

### The `fortran` debug type

A launch configuration of type `fortran` is resolved, when it starts, into zfls's debugger or one of the debugger extensions above, chosen as for Debug Fortran File:

```json
{
  "type": "fortran",
  "request": "launch",
  "name": "Debug solver",
  "program": "${workspaceFolder}/build/solver",
  "args": ["input.nml"]
}
```

`program` is the program; or `fpmTarget` (with `fpmTargetKind` `executable`, `example` or `test`) names an fpm target, which fpm builds first. `args`, `cwd`, `env` and `stopAtEntry` are as their names say; `console` is where the program's input and output go: the Debug Console (`internalConsole`, the default: the program reads no input), `integratedTerminal` or `externalTerminal`. `debugger` picks the debugger (`auto` by default, as `zfls.run.debugger`), and `compiler` says which compiler built the program (by default `zfls.run.compiler`, or for an fpm target `zfls.fpm.compiler`), which decides the debugger on Windows (`ifx`'s programs need Windows's engine or the Visual Studio debugger; `"dbgeng": true` asks for the engine for LLVM Flang's built with `-g`) and puts its runtime libraries on the `PATH`. Any other key goes to the debugger as it is (`setupCommands`, `MIMode`, ...). The configuration stays the same whichever debugger runs it.

An `attach` configuration attaches zfls's debugger to a running program, picked from a list (`"processId": "${command:pickProcess}"`), or to a gdbserver (`"target": "host:2345"`), with `program` for its debug information.

F5 without a `launch.json` debugs the file in the editor, as Debug Fortran File does, and the Run and Debug view lists a configuration for each executable, example and test of the workspace's fpm projects.

Breakpoints in Fortran files may have conditions in Fortran (`i .eq. 5`, `x > 1.0`), set before the program starts or while it runs: gdb reads them in the language of the breakpoint's line.

With the debugger extensions, while the program is stopped in a Fortran file, the **Fortran Module Variables** view of Run and Debug lists the module variables that the selected frame's line sees, which their Variables view leaves out (zfls's debugger shows them in the Variables view): those of its module, private ones too, and those its USE statements bring in, under the names they have there (FortranBreaker #10). Their values come from the debugger, asked for each variable by the names that the compilers give it: `module::name` (gdb), `__module_MOD_name` (gfortran's symbol, for lldb), `_QMmoduleEname` (LLVM Flang's), `MODULE_mp_NAME` (Intel's, for the Visual Studio debugger). Arrays and derived types expand as in the Variables view. A variable the debugger has no value for shows as not available.

Hovering over a component (`p%x`, `a(i)%x`) while debugging with gdb shows the component, not the variable of that name.

### zfls's debugger

zfls's debugger is `zfls dap`, the debug adapter of the zfls executable (the extension's own, or `zfls.path`), which other editors use too. It runs gdb (`zfls.run.gdbPath`) in its Debug Adapter Protocol mode (`gdb -i=dap`: gdb 14 or later, built with Python), or, for the programs of `ifx` and `ifort` on Windows (and LLVM Flang's with `"dbgeng": true`), Windows's own Debugger Engine (`dbgeng.dll`, which every Windows 10 and later has), and shows the program as Fortran (on macOS it runs lldb-dap instead, see below):

- arrays by their subscripts and bounds (`(2,-1)`, columns as `(:,-1)`), a large one in sections (`(1:100)`, ...), with a preview of their first elements (`[1.0, 2.0, …]`) or their shape (`[2×3]`); an unallocated array, or a pointer not associated, says so;
- derived types with a preview of their components (`point(x=9.0, y=-2.0, id=7)`), pointers as their targets, and a polymorphic object (`class(point)`) with the components of its dynamic type;
- the module variables that the frame's line sees, as the **Module variables** scope of the Variables view: those of its module, private ones too, and those its USE statements bring in, under their names there (`local => name` when renamed), as zfls's index of the sources (the workspace folder) finds them;
- each variable with its Fortran expression, for **Add to Watch**, **Copy as Expression** and setting a value: `a(2)`, `p%x`, `grid::cells`;
- gfortran's hidden lengths of CHARACTER arguments, and LFortran's temporaries, left out;
- **Fortran runtime errors**, an exception breakpoint of the Breakpoints view, on by default: the program stops where the runtime reports an error (an array bound exceeded under `-fcheck=bounds`, an allocation that failed, an I/O error without `iostat=`, `err=` or `end=`) or at ERROR STOP, at the line of the program, before it ends.

LFortran's programs (built with `-g`, not on Windows, where LFortran refuses it) have breakpoints, stepping, the stack and the **Fortran runtime errors** stops, with gdb and with lldb-dap; their debug information has integer and real scalars only, so the Variables view shows those, and no arrays, derived types, CHARACTER lengths or module variables.

The Debug Console takes gdb's commands (`print a(2:5)`, `ptype p`). `setupCommands` (gdb commands, such as `set print elements 0`) run before the program starts.

On macOS zfls's debugger runs lldb-dap (`"lldb": true` in the configuration, or the lldb-dap to run; `xcrun --find lldb-dap` finds Xcode's), since gdb does not run on Apple Silicon and must be code-signed on Intel; `zfls.run.gdbPath` or the configuration's `gdb` choose gdb instead. With lldb-dap there are breakpoints, stepping, the stack, the program in a terminal and the **Fortran runtime errors** stops, but lldb reads no Fortran: for the programs of gfortran and LLVM Flang the Variables view is empty and expressions are not evaluated. Over ssh, macOS lets a debugger start a program only with Developer Mode on (`sudo DevToolsSecurity -enable`).

With Windows's Debugger Engine, zfls reads the variables itself: dbghelp (of the engine) says where each is, zfls's index of the sources (the workspace folder) its type, kind and rank, and the array descriptors (Intel's, LLVM Flang's) their bounds; a polymorphic object or array shows its dynamic type's components, which the descriptor names. Of LLVM Flang's programs built with `-g`, the engine shows the variables (the main program's that Flang makes static too) and stops at Flang's runtime errors and ERROR STOP. The program runs in a console window of its own (`"console": "internalConsole"`: none, its output is then lost). Hovers, watches and the Debug Console take a variable, its components, elements and substrings (`p%x`, `a(2,-1)`, `s(2:4)`), and a module's variable by the name the line sees (`cells`) or by its module's (`grid::cells`).

**zfls: Add Build Task and Debug Configuration for Fortran File** writes the same build as a task in `.vscode/tasks.json` and a debug configuration that builds first in `.vscode/launch.json`, replacing those of the same name, for starting it with F5 and changing it to suit.

## fpm projects

For a directory with an `fpm.toml`, the [Fortran Package Manager](https://fpm.fortran-lang.org) builds, runs and tests the project. fpm must be installed (`pip install fpm`, conda, or a release from its site); `zfls.fpm.path` says where when it is not on the `PATH`.

- **Tasks:** **Terminal > Run Task > fpm** offers `build`, `build --profile release`, `run`, `test`, `install` and `clean` for each project. In `tasks.json`, a task of type `fpm` takes a `command`, and optionally a `target`, `example`, `profile`, `compiler`, `flags`, `args`, `programArgs` and `cwd` (the project's directory in the folder). The compiler's errors appear in the Problems view (the problem matchers `$zfls-gfortran` and `$zfls-intel`); `build` and `install` run in the C locale (`LC_ALL=C`), so that the compiler writes them in English.
- **zfls: Run fpm Target** and **zfls: Debug fpm Target** offer the executables and examples (and, to debug, the tests) that fpm lists. Debugging builds the target with fpm, then starts the debugger of `zfls.run.debugger` on its program, in the project's directory.
- **Run Fortran File** and **Debug Fortran File**, on the main program of a target (a `main` of `fpm.toml`, or a program in `app`, `test` or `example`), do the same for that target, unless `zfls.fpm.runFile` is off. `zfls.run.programArgs` are the program's arguments.
- **Testing view:** each test target, with a gutter button on its program: the `[[test]]` tables of `fpm.toml`, and (unless `auto-tests = false`) each program in `test` and below, named after its file, as fpm makes them. For [test-drive](https://github.com/fortran-lang/test-drive), the suites the program makes (`new_testsuite`) and the tests of their collect procedures (`new_unittest`, in the sources next to the program) are listed below it, and their results are read from its output. Running one suite or test passes its name to the program when it takes them, as test-drive's template does (`select_suite`, `run_selected`); otherwise the whole target runs. The debug profile runs the program under the debugger. zfls finds the tests (`zfls/fpmTests`, which other editors can ask too); the extension runs them.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.fpm.path` | empty | The fpm executable, or its directory |
| `zfls.fpm.profile` | empty | `--profile`: `debug` (fpm's default), `release` or a feature profile |
| `zfls.fpm.compiler` | empty | `--compiler`; empty: `FPM_FC`, else `gfortran` |
| `zfls.fpm.flags` | empty | `--flag`, the compiler flags |
| `zfls.fpm.args` | `[]` | More arguments of fpm's builds, runs and tests |
| `zfls.fpm.runFile` | `true` | Run and Debug Fortran File use fpm for the programs of fpm projects |
| `zfls.fpm.testExplorer` | `true` | fpm's tests in the Testing view |

zfls itself reads `fpm.toml` too: the include directories and macros of a project come from it (see the server's documentation).

## pFUnit tests

In a CMake project that builds its [pFUnit](https://github.com/Goddard-Fortran-Ecosystem/pFUnit) tests with `add_pfunit_ctest`, the Testing view lists each test program, with the suite of each of its `.pf` files (`@suite(name=...)`, else the module's name with `_suite`) and their `@test` procedures, with gutter buttons on them. zfls finds them (`zfls/pfunitTests`, which other editors can ask too); the extension builds and runs them.

- **Running** builds the program (`cmake --build DIR --target NAME`, with the compiler's problems in the Problems view), takes its command from CTest (`ctest --show-only=json-v1`), runs it with its results in an XML file (`-x -o FILE`), and reports each test, a failed assertion at its line of the `.pf` file. Running one test passes `-f SUITE.TEST` (not for parameterized tests); otherwise the whole program runs.
- **Debugging** builds the program and runs it under the `fortran` debug type (see [The `fortran` debug type](#the-fortran-debug-type)), with `-f` for one test.
- The project has to be configured first (by CMake Tools, or `cmake -S . -B build`). A `.pf` file that no `add_pfunit_ctest` names is listed too, and says so when run.

| Setting | Default | Meaning |
| --- | --- | --- |
| `zfls.pfunit.testExplorer` | `true` | pFUnit's tests in the Testing view |
| `zfls.pfunit.buildDirectory` | empty | The CMake build directory; empty: CMake Tools' `cmake.buildDirectory` (when it has no variables but `${workspaceFolder}`), else `build` |
| `zfls.pfunit.build` | `true` | Build a test program before running its tests |
| `zfls.pfunit.args` | `[]` | More arguments of the test programs |

## Snippets

At the start of a statement, the server completes the constructs and program units that can begin there, each with its end statement: `program`, `module`, `submodule`, `subroutine`, `function`, `type`, `interface`, `enum`, `if ... then`, `do`, `do while`, `do concurrent`, `select case`, `select type`, `select rank`, `associate`, `block`, `where`, `forall`, `critical`; inside an open construct its `else`, `else if`, `case`, `type is`, `elsewhere` and the like; `then` after `if (...)`; and after `end`, the end statement of the scope that is open. They follow `zfls.lowercaseIntrinsics` and `zfls.autocompleteNoSnippets`.

The extension adds these: type a prefix and pick the snippet from the completion list.

| Prefix | Inserts |
| --- | --- |
| `typ`, `typc`, `proc` | A derived type with `contains`, a type with a type-bound procedure, a type-bound procedure binding |
| `if`, `ife` | A one-line `if`, an `if`/`else` block |
| `imp` | `implicit none` |
| `modoc` | A module documentation header |

The fixed-form snippets indent with spaces and keep every line at the column where the prefix was typed, so type the prefix at column 7 or later. Fixed-form files show rulers after columns 5, 6 and 72 (the label, the continuation mark and the end of the code), a default of `"[FortranFixedForm]": {"editor.rulers": [...]}` that a setting of your own replaces. Most snippets are adapted from those of Modern Fortran.

## Commands

- **zfls: Get Started**: a walkthrough of the extension, also under **Help > Welcome** (Modern Fortran #472)
- **zfls: Restart Language Server**
- **zfls: Show Output**
- **zfls: Show Module Compile Order**
- **zfls: Toggle Fixed-Form Line Comment** (`Ctrl+/` in fixed form): with `zfls.fixedFormCommentCharacter` set to `C`, `c` or `*`, comments the lines with that character in column 1, or uncomments them (Modern Fortran #535)
- **zfls: Run Fortran File**, **zfls: Debug Fortran File** (also buttons in the editor title)
- **zfls: Add Build Task and Debug Configuration for Fortran File**
- **zfls: Run fpm Target**, **zfls: Debug fpm Target**
- **zfls: Lint Current File with Compiler**
- **zfls: Clear Compiler Diagnostics**
- **zfls: Fix All Safe fortitude Problems**
- **Fortran: Convert to Free Form** (in a fixed-form file), **Fortran: Convert to Fixed Form** (in a free-form file): findent converts the file, and the result goes to `name.f90` (or `name.f`) beside it, which opens; an existing file is overwritten only when you agree. The old file is left. Needs findent (`pip install findent`); `zfls.formatting.path` is used when findent is the formatter.
