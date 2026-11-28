# Configuration

Configure the editor's language client to start `zfls`; it communicates over standard input and output. All fortls options are accepted, for example:

```sh
zfls --incremental_sync --hover_signature --use_signature_help
zfls --help
```

Options can also be set in a configuration file in the project root: `.zflsrc` (TOML), else fortls's `.fortlsrc`, `.fortls.json` or `.fortls` (JSON or JSON5), the first found being read, or the file named with `-c`/`--config`, whose format is told by its content (a first token of `{`, `//` or `/*` is JSON5, anything else TOML). The option names are those of the command line and of the [fortls documentation](https://fortls.fortran-lang.org/options.html), the same in both formats.

A `.zflsrc` is TOML with one key per option, comments with `#`, and a table for the options that take a dictionary (`pp_defs`, `diagnostic_severity`, `file_associations`):

```toml
#:schema https://raw.githubusercontent.com/cesiumlang/zfls/main/editors/vscode/schemas/fortls.schema.json
source_dirs = ["src", "app"]
include_dirs = ["include"]
lowercase_hover = true
compiler_diagnostics = "gfortran"

[pp_defs]
USE_MPI = 1

[diagnostic_severity]
masks-parent = "off"
```

A key that is no option, and a value of the wrong type, are reported as a warning and ignored, in a `.zflsrc` (a fortls file's unknown keys are still skipped silently). The settings that name a program are not read from a project's file, in either format (see [the compiler check](compiler-check.md#compiler-diagnostics)). `zfls config [--root DIR] [options]` prints each option in effect and where it came from (the default, the command line, the user's file or the project's file).

Moving a fortls file over: the option names do not change, only the syntax.

| `.fortlsrc` (JSON5) | `.zflsrc` (TOML) |
| --- | --- |
| `{ "source_dirs": ["src"] }` | `source_dirs = ["src"]` |
| `"nthreads": 4,` | `nthreads = 4` |
| `"lowercase_hover": true,` | `lowercase_hover = true` |
| `"pp_defs": { "A": "1" },` | `[pp_defs]` then `A = "1"` |
| `"diagnostic_severity": { "masks-parent": "off" }` | `[diagnostic_severity]` then `masks-parent = "off"` |
| `// a comment` | `# a comment` |
| `"compiler_args": ["-Wall"]` | `compiler_args = ["-Wall"]` |
| `null` (not set) | leave the key out |

Tables are only for the dictionary options; other options are top-level keys, so that the command line, the schema and the files all use one set of names.

Personal defaults for every project go in a user configuration file of the same format: `%APPDATA%\zfls\config.json` on Windows, else `$XDG_CONFIG_HOME/zfls/config.json` (`~/.config/zfls/config.json` without that variable). Relative paths in it are relative to the workspace root, as in the project's file. It is read again when it changes, where the editor watches files outside the workspace, else at the next start.

The editor can also send them over LSP, under the same names, as one object or in its `zfls` member: in the `initializationOptions` of the `initialize` request, and in `workspace/didChangeConfiguration` when they change. In Neovim, for instance:

```lua
vim.lsp.config("zfls", {
  cmd = { "zfls" },
  filetypes = { "fortran" },
  init_options = { use_signature_help = true, source_dirs = { "src" } },
  settings = { zfls = { max_line_length = 132 } },
})
vim.lsp.enable("zfls")
```

Each source takes over from the one before: the command line, the user configuration file, the editor's settings, the project's configuration file. A change applies at once:

- One of the options that decide what is indexed (`source_dirs`, `excl_paths`, `incl_suffixes`, `excl_suffixes`, `include_dirs`, `pp_defs`, `pp_suffixes`, `comment_markers`, `d_lines`, `compile_commands`, ...) indexes the workspace again, keeping the unsaved text of the open documents. So does one that chooses the compiler of the compiler check or its arguments (`compiler_diagnostics`, `compiler_path`, `compiler_args`, their `_fixed` forms, `compiler_no_compile_commands`): the compiler's modules and predefined symbols are read again, and the open documents checked again. Set those in `initializationOptions` (Neovim's `init_options`) to index once at start-up.
- Turning on signature help, code actions or formatting registers them with an editor that allows that (`client/registerCapability`); others are told to restart zfls. Turning one off makes it answer nothing.
- The diagnostics of the open documents are published again.

The configuration file, `fpm.toml` and `compile_commands.json` are read again when they change on disk, with the same effects (a change of `fpm.toml` or `compile_commands.json` indexes the workspace again): zfls asks the editor to watch them where it allows that (`workspace/didChangeWatchedFiles`); other editors restart zfls.

The fortls debug options work as well, for instance `zfls --debug_parser --debug_filepath file.f90` prints the parser trace and the resulting object tree, and `--debug_hover --debug_filepath file.f90 --debug_line 10 --debug_char 5` runs a single hover request. Their output is meant for testing zfls and may differ from fortls's. They take the options as the server does: the command line's, with the configuration file's (`.zflsrc`, `.fortlsrc`, `.fortls.json`, `.fortls` or `-c`) in `--debug_rootpath` over them. With `--debug_log`, `fortls_debug.log` has a `Final options` line with the options in effect, after the command line, the editor's settings, the configuration file and the build files, at start-up and after each change of the settings.
