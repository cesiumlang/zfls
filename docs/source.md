# Reading the source

## Comment markers

Some codebases are written in a dialect that a preprocessor turns into Fortran, with comments that start with something other than `!`, such as `;*` (`go to 110  ;* it's done`). `comment_markers` lists such markers: outside strings, zfls reads what follows one as a comment, so that its words are not names and a quote in it does not start a string.

```json
{ "comment_markers": [";*"] }
```

In VS Code, `zfls.commentMarkers` sets it, and the extension highlights those comments too, after a window reload.

## OpenMP conditional compilation

A line that starts with the OpenMP sentinel `!$` and a blank (`!$ use omp_lib`, `!$ call omp_set_num_threads(n)`; in fixed form `!$`, `c$`, `C$` or `*$` in columns 1 and 2, then blanks or a label up to column 5) is a statement when the file is compiled with OpenMP. zfls reads it as code, the sentinel as two blanks: hover, definition, completion, references and rename see the names in it, and a variable used only there counts as used. A line continues as any other (`!$ call s(a, &` then `!$ & b)`). The directives (`!$omp`, `!$acc`) and a comment such as `!$this` stay comments. `disable_openmp_conditional` (`zfls.disableOpenmpConditional` in VS Code) reads these lines as comments, as a build without OpenMP does. The compiler check sees them as code only with the OpenMP flag in `compiler_args` (`-fopenmp`, `-qopenmp`). The VS Code grammar still colors them as comments, under the semantic highlighting of their names.

## Debug lines

A fixed-form line with `D` or `d` in column 1 is a debug line (a DEC extension), which compilers read as a comment or as code by an option. `d_lines` says which: `comment` (the default) or `code`, where the `D` is a blank. zfls reads the lines so, the compiler check passes the compiler the option that reads them so (gfortran `-fd-lines-as-comments` / `-fd-lines-as-code`, Intel `-nod-lines` / `-d-lines`, nvfortran `-Mnodlines` / `-Mdlines`, nagfor `-d_lines`, flang `-fd-lines-as-code`, which needs Flang 21 or later: Flang 20 gets none) unless `compiler_args` already has one, and a debug line read as a comment is a comment for the editor's highlighting (semantic tokens). In VS Code, `zfls.fixedFormDLines` sets it.

```json
{ "d_lines": "code" }
```

## Intel conditional compilation

Intel Fortran has conditional compilation in directive comments, which the compiler honors without `-fpp`: `!DEC$ IF DEFINED (sym)`, `!DIR$ IF (expr)`, `ELSEIF (expr)` (or `ELSE IF`), `ELSE`, `ENDIF` (or `END IF`), and `DEFINE sym [= value]` and `UNDEFINE sym`, which change the symbols for the rest of the file. The prefix is `!DEC$` or `!DIR$` in any case (in fixed form `!`, `C`, `c` or `*` in column 1: `CDEC$`). zfls skips the branches they leave out, in every Fortran file and after the C preprocessor's `#if`, as it does those of `#if`: they are not parsed (no false "declared twice", the declaration in effect in hover), are shown inactive, and fold. Conditions take the Fortran operators (`.AND.`, `.OR.`, `.NOT.`, `.EQ.` ... `.GE.`, `==`, `/=`, ...) and `DEFINED(sym)`. Symbols come from `pp_defs` and the `-D` flags of `compile_commands.json`, and, when ifx or ifort is the compiler check's compiler (`compiler_diagnostics`), from the symbols it predefines (`__INTEL_LLVM_COMPILER`, `_WIN32`, `_M_X64`, `_OPENMP` ..., asked of it once from the `-D` options its driver gives fpp (`-###`: on Linux `__linux__`, `__unix__`, `__ELF__`, `__x86_64__` and no `_WIN32`), else with `-fpp -E` of a probe file, and again when its file changes; the C preprocessor's `#if` sees them too), and are not case-sensitive. `#define` does not define them, as for the compiler. Other directives (`!DIR$ ATTRIBUTES`, `!DIR$ IVDEP`) stay comments. `disable_intel_directives` (`zfls.disableIntelDirectives` in VS Code) reads every branch, as before.
