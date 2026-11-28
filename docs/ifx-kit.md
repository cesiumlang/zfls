# ifx without Visual Studio (Windows x64)

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

zfls's build of a file to run (`zfls build-command`, the VS Code extension's **Run Fortran File**) sets this up itself (see [Building a file to run or debug](running.md)).

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
