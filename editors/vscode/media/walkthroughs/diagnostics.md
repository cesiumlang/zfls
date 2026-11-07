# See your compiler's errors

When you open or save a Fortran file, zfls has a compiler check it, without
building anything, and shows the errors and warnings in the file and in the
Problems panel. A file that uses modules of the workspace gets them
compiled first.

The compiler is gfortran by default. `zfls.linter.compiler` picks another:
`ifx`, `ifort`, `nagfor`, `lfortran`, `nvfortran` or `flang`, or
`Disabled`. `zfls.linter.extraArgs` takes options such as `-std=f2018`, and
`zfls.linter.includePaths` the directories of `.mod` files from outside the
workspace.

Two more checkers can run alongside, when installed:

- [fortitude](https://github.com/PlasmaFAIR/fortitude), a linter for
  Fortran, with fixes (`zfls.fortitude.enabled`)
- [Codee](https://www.codee.com), checks of correctness and performance
  (`zfls.codee.enabled`)
