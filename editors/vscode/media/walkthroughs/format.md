# Format your code

**Format Document**, **Format Selection** and format on save use zfls's own formatter, which needs no tool: it indents free-form and fixed-form files by their scopes, and with `zfls.formatting.zflsArgs` also sets the keywords' case (`--case lower`), spaces operators (`--spacing`) and puts the `::` of declarations in a column (`--align`).

To use another formatter, install it and choose it with `zfls.formatting.formatter`:

| Formatter | Install | Formats |
| --- | --- | --- |
| [findent](https://pypi.org/project/findent/) | `pip install findent` | Indentation, free and fixed form |
| [fprettify](https://github.com/fortran-lang/fprettify) | `pip install fprettify` | Indentation, whitespace and more, free form |

It can differ by source form, for example fprettify for free form and findent for fixed form:

```jsonc
"zfls.formatting.formatter": "fprettify",
"[FortranFixedForm]": {
  "zfls.formatting.formatter": "findent"
}
```
