# Run and debug a file

The **Run Fortran File** and **Debug Fortran File** buttons at the top
right of the editor build the program in the editor with
`zfls.run.compiler` (gfortran by default) and run it in a terminal, or
start the debugger on it.

Debugging needs one of these extensions:

- [C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools),
  for gdb, and for programs of Intel's compilers on Windows
- [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)
- [CDT GDB Debug Adapter](https://marketplace.visualstudio.com/items?itemName=eclipse-cdt.cdt-gdb-vscode)

Breakpoints may have conditions in Fortran, such as `i .eq. 5`.

For a program of several files, use a launch configuration of type
`fortran`, which picks the debugger for you:

```json
{
  "type": "fortran",
  "request": "launch",
  "name": "Debug solver",
  "program": "${workspaceFolder}/build/solver"
}
```
