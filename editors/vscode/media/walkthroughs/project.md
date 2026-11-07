# Tell zfls about your project

zfls finds most of what it needs by itself:

- **fpm projects:** the include directories and macros of `fpm.toml`.
- **CMake, Meson and others:** the include directories and macros of each
  file in `compile_commands.json`, when the build writes one
  (`zfls.compileCommands` says where, if it is not at the folder's root,
  in `build/` or in `builddir/`).
- **Otherwise:** every Fortran file of the folder is a source.

When that is not enough, set these in the settings (or in a `.fortlsrc`
file, as for fortls):

| Setting | For |
| --- | --- |
| `zfls.sourceDirs` | The directories with the sources, when not the whole folder |
| `zfls.excludePaths` | Directories and files to leave out |
| `zfls.includeDirs` | Directories of files brought in by `INCLUDE` and `#include` |
| `zfls.ppDefs` | Preprocessor macros, such as `{"USE_MPI": "1"}` |
| `zfls.ppSuffixes` | File extensions to preprocess, when not the upper-case ones (`.F90`, `.F`, ...) |

zfls restarts by itself when `.fortlsrc`, `fpm.toml` or
`compile_commands.json` changes.
