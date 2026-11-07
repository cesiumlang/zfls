# fpm projects and tests

In a folder with an `fpm.toml`, the
[Fortran Package Manager](https://fpm.fortran-lang.org) builds, runs and
tests the project:

- **Terminal > Run Task > fpm** builds, runs and tests it.
- **zfls: Run fpm Target** and **zfls: Debug fpm Target** offer its
  programs; Run Fortran File on a target's main program runs that target.
- The **Testing** view lists its tests, with the suites and tests of
  [test-drive](https://github.com/fortran-lang/test-drive), to run or
  debug one by one.

The Testing view also lists the tests of
[pFUnit](https://github.com/Goddard-Fortran-Ecosystem/pFUnit), in CMake
projects that build them with `add_pfunit_ctest`: each `@test` of a `.pf`
file, with a failed assertion shown at its line.
