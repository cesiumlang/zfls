# Compilers

Every [feature](features.md) works on any Fortran source, whatever compiler builds it: zfls parses the code itself. A compiler comes in where zfls runs one (the compiler check, running a file) or reads what one wrote (a program under the debugger), and where the source is in a compiler's own dialect.

✓ is supported; ○ is implemented but not tested with that compiler (see [what is tested](#what-is-tested-with-a-real-compiler)); – is not available.

## The compiler check

`compiler_diagnostics` (see [Compiler diagnostics](compiler-check.md#compiler-diagnostics)).

| | gfortran | ifx | ifort | flang | nvfortran | nagfor | lfortran |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Errors and warnings as diagnostics | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Without building (syntax only) | ✓ | ✓ | ✓ | ✓ | –¹ | ✓ | ✓ |
| Modules the file uses compiled first | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓² |
| The file's own command of `compile_commands.json` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Options by default: warnings, coarrays, OpenMP ([`compiler_args`](compiler-check.md#compiler-diagnostics)) | `-Wall -fcoarray=single -fopenmp` | `-warn all,nodeclarations,noexternals -coarray=single -qopenmp` | `-warn all,nodeclarations,noexternals -coarray=single -qopenmp` | `-Wunused-variable -Wused-undefined-variable`⁴ `-fopenmp` | `-Minform=warn` | – | – |
| Preprocessed files | `-cpp` | `-fpp` | `-fpp` | `-cpp` | `-Mpreprocess` | `-fpp` | `--cpp` |
| Fixed-form line length (`fixed_line_length`) | any | 72, 80, 132 | 72, 80, 132 | any | 132 | 132 | – |
| Debug lines as zfls reads them (`d_lines`) | ✓ | ✓ | ✓ | ✓⁴ | ✓ | as code | – |
| Every error, not only the first | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓³ |
| Messages without a file and line | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

1. nvfortran has no syntax-only mode: it compiles the file, with the object file in zfls's cache.
2. LFortran's syntax-only mode writes no `.mod` file: the modules are compiled to their symbol tables (`--symtab-only -c`).
3. With `--continue-compilation`. zfls also passes LFortran `--implicit-typing --implicit-interface`, which its own dialect rejects, unless the options say otherwise.
4. LLVM Flang 22 and later, whose version zfls asks of it once (`flang --version`), and again when the executable's file changes; Flang 21 knows neither option, Flang 20 has only `-Werror`, and `-Wall` is none of Flang's, so older Flang get no warnings by default. Flang reads debug lines as comments by default; as code (`-fd-lines-as-code`) needs Flang 21 or later, and zfls passes Flang 20 no option, which then reads them as comments.

## Compiler dialects in the source

The parser reads these in every file, whichever compiler is configured; the columns say whose dialect each is.

| | gfortran | ifx | ifort | flang | nvfortran | nagfor | lfortran |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| `STRUCTURE`, `RECORD`, `UNION`/`MAP`, `rec.field` (DEC) | ✓⁵ | ✓ | ✓ | ✓⁶ | ✓ | – | – |
| [Conditional compilation in directives](source.md#intel-conditional-compilation) (`!DEC$ IF`, `!DIR$ IF`) | – | ✓ | ✓ | – | – | – | – |
| Generated interface modules (`<name>__genmod.f90`) left out of the index | – | ✓ | ✓ | – | – | – | – |
| CUDA Fortran (`attributes(device)`, `call k<<<g, b>>>(...)`, `.cuf`) | – | – | – | ✓ | ✓ | – | – |
| `!DIR$ IGNORE_TKR`: no argument checks for the dummy arguments it names | – | – | – | ✓ | ✓ | – | – |
| `!GCC$ ATTRIBUTES NO_ARG_CHECK` (gfortran), `!DIR$ ATTRIBUTES NO_ARG_CHECK` (Intel): no argument checks for the dummy arguments it names | ✓ | ✓ | ✓ | – | – | – | – |
| `!DIR$ FIXED`, `!DIR$ FREE`: the source form of the lines after them | – | – | – | ✓ | – | – | – |
| `!DEC$ NOFREEFORM`, `!DEC$ FREEFORM` (also `!DIR$`): the source form of the lines after them | – | ✓ | ✓ | – | – | – | – |
| `!DEC$ REAL:n`, `!DEC$ INTEGER:n`: the default kind of the next program unit, in the argument checks | – | ✓ | ✓ | – | – | – | – |
| `!DEC$ FIXEDFORMLINESIZE:n` (also `!DIR$`): the line length of the fixed-form lines after it, in place of `fixed_line_length` | – | ✓ | ✓ | – | – | – | – |
| [Debug lines](source.md#debug-lines) (`D` in column 1 of fixed form) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| `AUTOMATIC` and `STATIC` (DEC) statements and attributes (gfortran's with `-fdec-static`) | ✓ | ✓ | ✓ | – | – | – | – |
| `VIRTUAL` (DEC's `DIMENSION`), `PARAMETER` without parentheses (`PARAMETER N = 10`, of the type of its value) | – | ✓ | ✓ | – | – | – | – |
| `UNSIGNED` (`unsigned(kind=8)`, `42u`, `SELECTED_UNSIGNED_KIND`, `UINT`; with `-funsigned`, gfortran's from GCC 15) | ✓ | – | – | ✓ | – | – | ○ |
| `$` in names, also first (`subroutine $$lib$random`; gfortran's with `-fdollar-ok`, after the first character) | ✓ | ✓ | ✓ | ✓ | – | – | – |
| DEC's I/O statements: `ENCODE`, `DECODE`, `ACCEPT`, `DEFINE FILE`, `FIND`, the record of `READ (u'r)` | – | ✓ | ✓ | – | – | – | – |
| TAB-format fixed form (DEC): a TAB in columns 1 to 6 stands for them, a nonzero digit after it marks a continuation line | ✓ | ✓ | ✓ | ✓ | ○ | ○ | ○ |

5. gfortran's with `-fdec-structure`.
6. LLVM Flang's without `UNION` and `MAP`, which it has not implemented.

Not a compiler's own, and read for all of them: the C preprocessor, fypp files, OpenMP conditional compilation lines, kinds written with `*` (`real*8`), `BYTE`, old-style initial values (`integer :: k /3/`), Cray pointers (`pointer (p, b)`), and comment markers of other preprocessors ([Comment markers](source.md#comment-markers)).

## Running and debugging

Run Fortran File and Debug Fortran File are the VS Code extension's, with the build zfls answers for any editor (see [Building a file to run or debug](running.md)); `zfls dap` is for any editor (see [A debugger](debugging.md#a-debugger-zfls-dap)).

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
8. With zfls's ifx kit (and for ifx `zfls setup-ifx`), on Windows x64 (see [ifx without Visual Studio](ifx-kit.md)).
9. zfls builds LFortran's programs through LFortran's LLVM IR (`zfls lfortran-ir`, which `zfls build-command` answers): LFortran writes the IR with its debug information (`lfortran -g --show-llvm`), zfls adds what LFortran 0.69 leaves out, clang or llc compiles it (the one next to LFortran, else clang on the `PATH`: `conda install clang`, or `llvm-tools`, which has llc), and LFortran links it (on macOS, dsymutil then writes the `.dSYM`). Without clang or llc, zfls builds with `lfortran -g` (which runs `llvm-dwarfdump` and Python: build with LFortran's environment on the `PATH`; conda-forge's LFortran for Linux needs `llvm-tools` beside it), without what follows. LFortran 0.69 gives PRINT and WRITE statements no line of their own (their code carries the line of the statement before), so a breakpoint on one stops elsewhere or not at all; zfls gives them theirs: each such statement is one call of LFortran's runtime, and the k-th call of a procedure gets the line of its k-th PRINT or WRITE (a procedure where the two differ in number keeps LFortran's lines). zfls also writes each variable's storage (its `alloca` or global and LFortran's struct types: its descriptors, `lfortran_array`, and strings, `lfortran_string`), with the source's names of derived types' components; the function's parameters as the dummy arguments (with LFortran's hidden extents and lengths, `__1a`, `__libasr_len_s`); module variables (`__module_grid_ncells`) and a program's saved ones as globals. It leaves out LFortran's traceback before an ERROR STOP, which ends the program before its message (on macOS a `-g` program of LFortran's own build aborts there: "The stack address was not found"). Tested in CI with gdb on Linux x64 and lldb-dap on macOS x64: breakpoints (one on a PRINT), stepping, the stack, the stops at LFortran's runtime errors (a bound exceeded, which it checks by default) and at ERROR STOP, not at STOP. LFortran's DWARF says its language is C, so gdb and lldb-dap show the variables as C's (the descriptors as structs; without the compiler's temporaries), and there is no module variables scope. On Apple Silicon, where the string that tells ERROR STOP from STOP is passed on the stack, `zfls dap` reads it there (tested locally with lldb-dap on an M-series Mac; CI has no Apple Silicon runner). LFortran for Windows refuses `-g` and writes DWARF only; there zfls marks the IR for CodeView instead, and lld-link links it with LFortran's static runtime and zfls's ifx kit, no Visual Studio, when clang and lld-link are next to LFortran or on the `PATH` (`conda install clang lld`); `zfls dap` debugs them with Windows's Debugger Engine: breakpoints, stepping, the stack and the variables as ifx's (arrays, derived types, CLASS objects and arrays as their dynamic types, CHARACTER of any length, ALLOCATABLE and POINTER ones, dummy arguments, a program's saved variables, module and COMMON variables, without LFortran's temporaries), with LFortran's hidden extents and lengths read for its dummy arguments.
10. Windows's Debugger Engine (`"dbgeng": true`), for debug information of Microsoft's format; arrays are read through Intel's descriptors and LLVM Flang's. CI tests the engine on C programs (also a break instruction of the program's own, which stops as an exception, as the Intel runtime's at a runtime error does once), on LLVM Flang's built with `-g`, and on ifx 2026's built with `/Zi` (conda-forge's, linked with zfls's ifx kit): breakpoints, `stopAtEntry`, the stack, stepping, the variables, and the stops at a runtime error and at ERROR STOP (ifx's `for_error_stop_quiet`), not at STOP. The variables include a polymorphic object or array with its dynamic type's components (Flang's and ifx's), a module's variables by their own names in an expression (`ncells`, `grid::ncells`) and those of its COMMON blocks, and REAL(16) values.
11. lldb-dap (Xcode's command line tools), since gdb does not run on Apple Silicon and every user must code-sign it on an Intel Mac: breakpoints, stepping, the stack and the stops at runtime errors and ERROR STOP, but lldb has no Fortran support for variables and expressions, so the Variables view of these programs is empty (the row of variables is gdb's).
12. LLVM Flang's `-g` on Windows writes debug information of Microsoft's format only, with which Windows's engine has breakpoints, the stack, stepping, the variables (arrays through Flang's descriptors, a polymorphic object or array with its dynamic type's components, the main program's variables that Flang makes static) and the stops at Flang's runtime errors and ERROR STOP. A program built with `-gdwarf-4` and linked with `-Wl,-debug:dwarf` has DWARF too, which gdb reads (tested in CI with Flang 23 and MSYS2's gdb): the variables, a polymorphic object or array with its dynamic type's components, and stops at Flang's runtime errors and ERROR STOP (not at a plain STOP). The VS Code extension's Debug Fortran File builds Flang's programs so (where there is an `lld-link`) and debugs them with gdb; the engine is for those built with `-g` (`"dbgeng": true`).

## What is tested with a real compiler

CI runs zfls against gfortran (the symbols zfls extracts, compared with gfortran's own, on Linux, macOS and Windows x64; `zfls dap` with gdb on Linux and Windows x64, with lldb-dap on macOS), against LFortran (the compiler check and `zfls dap` with gdb, on Linux x64; `zfls dap` with lldb-dap on macOS x64; its programs linking without Visual Studio, on Windows x64) and against LLVM Flang (the compiler check and `zfls dap` with gdb, on Linux x64 and Windows x64; its programs linking without Visual Studio, and `zfls dap` with Windows's Debugger Engine, on Windows x64). The other compilers' options and message formats are tested with recorded output, not with the compilers.
