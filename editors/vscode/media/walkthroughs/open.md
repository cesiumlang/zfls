# Open your Fortran code

Open the folder of your project with **File > Open Folder**. zfls reads every
Fortran file in it, so that completion, hover, go to definition, find
references and rename work across files, and the Outline view, breadcrumbs
and sticky scroll show each file's program units.

The extension includes the `zfls` executable; there is nothing else to
install for these features.

If the Modern Fortran extension is installed, disable it: it starts a
language server of its own, and with both you get every completion, hover
and diagnostic twice. zfls offers to do the rest when it sees Modern
Fortran enabled.
