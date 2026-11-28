# Formatting and the source form

## Formatting

zfls answers `textDocument/formatting` and `textDocument/rangeFormatting` (format document, format selection, format on save) with its own formatter by default (`formatter` is `zfls`), or, with `formatter` set to `findent`, `fprettify`, `codee`, `forformat` or `custom`, by running that one, which is installed separately (`pip install findent`, `pip install fprettify`, or the same from conda-forge; [Codee](https://www.codee.com); forformat). This works in every editor, not only VS Code. With `formatter` set to `none` (and `formatter_fixed` unset or `none`), zfls offers no formatting, so an editor can use another formatter.

| `formatter` | Command line |
| --- | --- |
| `findent` | `findent -ifree` (or `-ifixed`), `-Ia` for a selection, then `formatter_args` |
| `fprettify` | `fprettify`, then `formatter_args` |
| `codee` | `codee format - -o -`, then `formatter_args`; the `codee` of `codee_path` unless `formatter_path` is set |
| `forformat` | `forformat --stdin-filename=FILE -ifree` (or `-ifixed`), then `formatter_args` |
| `custom` | `formatter_path` with `formatter_args`, in which `${file}` is the document's path and `${form}` `free` or `fixed` |
| `zfls` | none: zfls's own, which indents free-form files by their scopes (program units, procedures, types, interfaces and constructs; ELSE, CASE, TYPE IS, RANK and CONTAINS at their construct's level; continuation lines one level further, or, when they were indented further than their statement, by as much as they were, so that a line aligned with a parenthesis stays aligned) and changes nothing else: no token moves, preprocessor lines and the rest of a continued character literal stay as they are. `formatter_args` takes `--indent N` (3 by default), `--case upper`, `lower` or `title` (the keywords, not the names), `--spacing` (one blank after a comma and around `::`, the relational operators, and outside parentheses `=` and `=>`; a keyword argument's `=` stays as it is) and `--align` (the `::` of a run of declarations in one column). With `editor.formatOnType` it also indents the line Enter ends, so an END moves to its construct's level. `--indent-directives` nests the preprocessor's directives by their `#if`s, two blanks per level after the `#`, which stays in column 1. In fixed form it indents the code after column 6 (labels and continuation marks stay in their columns), and only where the line fits in `fixed_line_length` (72 by default) before and after, so sequence numbers in columns 73 to 80 stay; a line that ends in a continued character literal, and the one that goes on with it, stay as they are; `--spacing` and `--align` are free form only |

zfls gives the formatter the document's text, as the editor has it, on its standard input, reads the result from its standard output (no files are written), and answers with an edit for each block of lines the formatter changed (from a line diff), so the lines it left alone keep their exact text. The formatter runs in the file's directory, so fprettify finds the `.fprettify.rc` files there and above.

```json
{
  "formatter": "fprettify",
  "formatter_args": ["--indent", "4", "--enable-decl"],
  "formatter_fixed": "findent",
  "formatter_fixed_args": ["-i2"],
  "formatter_path": "/opt/tools/bin"
}
```

- `formatter_args`: the formatter's own options. findent gets `-ifree` or `-ifixed` from the file's form (its extension, else what zfls detects) unless these set the input form (`-i...`, `--input_format`), and for a selection `-Ia`, which starts at the indentation of its first line. On the command line it is one string, split at spaces: `--formatter_args="-i4 -r1"`.
- `formatter_fixed`, `formatter_fixed_args`: the formatter of fixed-form files and its options, when they differ (by default `formatter`'s); fprettify formats free form only, findent both. `none` formats no fixed-form files.
- `formatter_path`: the executable, or the directory that holds it (by default the formatter on the `PATH`).

A selection is formatted as whole lines, and findent, fprettify and a custom formatter see only those lines: select whole constructs for the indentation inside them to come out right. Codee's formatter and forformat format whole files only: zfls gives them the whole file and keeps the changes in the selected lines. When the formatter is missing or fails, the document is left as it is and zfls shows the error once (`window/showMessage`).

## The form of a `.fpp` file (`zfls/sourceForm`)

The compilers read a `.fpp` file as fixed form, preprocessed, unless their options say otherwise, and zfls detects its form from its text. An editor names a form by the document's language (VS Code opens every `.fpp` as `FortranFreeForm`), so for such a file zfls takes its own detection over the language the document is first opened in, and sends the notification `zfls/sourceForm`, `{ "uri": ..., "form": "fixed", "languageId": "FortranFixedForm" }` (or `"free"`, `"FortranFreeForm"`), when the language is not the detected form's. The VS Code extension gives the document that language, so highlighting, the formatter and the fixed-form features agree. A language the document is reopened in at once after that (Change Language Mode closes and opens it) is the user's choice, which zfls reads it in and keeps for the file while it runs; opened in the language it told, nothing more is sent.

A lasting choice is a file association: `file_associations` (option or configuration file) holds the editor's associations of glob patterns with languages, `{"*.fpp": "FortranFixedForm", "**/modern/*.fpp": "FortranFreeForm"}`, which the VS Code extension sends from VS Code's `files.associations`. A `.fpp` file whose association gives it `FortranFreeForm` or `FortranFixedForm` is read in that form, open or not, and nothing is sent for it. The patterns are matched as VS Code matches them: one with a `/` against the absolute path, one without against the file name, ignoring case; the longest that matches wins, whatever its language. A change applies at once: a document whose association changed is read anew, and the editor told its new form when its language is another.

## Converting the source form

findent rewrites a fixed-form source as free form (`-ifixed -ofree`), and a free-form one as fixed form (`-ifree -ofixed`). The request `zfls/convertForm`, with `{ "textDocument": { "uri": ... }, "to": "free" }` (or `"fixed"`), runs findent on the document's text as the editor has it and answers `{ "text": ..., "path": ... }`: the converted text and the file it belongs in (`name.f90`, or `name.f`; `.F90`/`.F` for a preprocessed file), since zfls takes the form from the extension. On failure, it answers `{ "error": ... }` with findent's message, or how to install findent. The findent of `formatter_path` is used when findent is the formatter, else the one on the `PATH`; findent's `formatter_args` (or `formatter_fixed_args`) come first. For clients that can create files in a workspace edit (`workspace.workspaceEdit.resourceOperations` with `create`), a fixed-form file has the source action "Convert to free form (new file name.f90)", whose edit creates that file with the converted text (it needs `enable_code_actions`). The old file is left; deleting it is the user's choice. In VS Code, **Fortran: Convert to Free Form** and **Fortran: Convert to Fixed Form** write the new file beside the old one, asking before they overwrite one, and open it.
