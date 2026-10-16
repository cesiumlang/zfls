# Third-party notices

The files in `syntaxes/` and `language-configuration.json` are the Fortran
grammars and language configuration of the
[Modern Fortran](https://github.com/fortran-lang/vscode-fortran-support)
extension, version 4.0.0, and the snippets in `snippets/` up to "Module
Documentation Header" are adapted from its `snippets/fortran90.json`. The
**Run Fortran File** and **Debug Fortran File** commands and their editor
title buttons follow its `fortran.build.run` and `fortran.build.debug`, and
the choice among debugger extensions its `src/debug/configuration.ts`. The
compiler linting in `src/linter.ts` and `src/lint/` follows the design of
its `src/lint/` (settings, compiler options, and the message formats of
gfortran, Intel, NAG and LFortran). These are used under its MIT license:

```text
MIT License

Copyright (c) 2017-2022 The Fortran Programming Language

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The bundled `zfls` executable is MIT licensed; see `LICENSE`.
