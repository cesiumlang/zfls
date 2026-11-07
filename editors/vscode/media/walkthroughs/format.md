# Format your code

**Format Document**, **Format Selection** and format on save use a
formatter that you install yourself:

| Formatter | Install | Formats |
| --- | --- | --- |
| [findent](https://pypi.org/project/findent/) | `pip install findent` | Indentation, free and fixed form |
| [fprettify](https://github.com/fortran-lang/fprettify) | `pip install fprettify` | Indentation, whitespace and more, free form |

Then choose it with `zfls.formatting.formatter`. It can differ by source
form, for example fprettify for free form and findent for fixed form:

```jsonc
"zfls.formatting.formatter": "fprettify",
"[FortranFixedForm]": {
  "zfls.formatting.formatter": "findent"
}
```
