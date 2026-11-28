# Editors

VS Code has the [extension](https://marketplace.visualstudio.com/items?itemName=cesiumlang.zfls) (`editors/vscode`; also on [Open VSX](https://open-vsx.org/extension/cesiumlang/zfls)), which includes zfls. Other editors start `zfls` as any language server; its options go in a `.zflsrc` in the project (see [Configuration](configuration.md)), or after `zfls` on its command line.

Neovim 0.11 or later, in `init.lua`:

```lua
vim.lsp.config("zfls", {
  cmd = { "zfls" },
  filetypes = { "fortran" },
  root_markers = { ".zflsrc", ".fortlsrc", ".fortls.json", "fpm.toml", ".git" },
})
vim.lsp.enable("zfls")
```

Helix, in `languages.toml` (with the `debugger` of [A debugger](debugging.md#a-debugger-zfls-dap) for `zfls dap`):

```toml
[language-server.zfls]
command = "zfls"

[[language]]
name = "fortran"
language-servers = ["zfls"]
```

Emacs with eglot:

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '((f90-mode fortran-mode) . ("zfls"))))
```

Emacs with lsp-mode (the priority puts it before lsp-mode's own client of fortls):

```elisp
(with-eval-after-load 'lsp-mode
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection '("zfls"))
                    :activation-fn (lsp-activate-on "fortran")
                    :priority 1
                    :server-id 'zfls)))
```

Sublime Text with the LSP package, in `LSP.sublime-settings`:

```json
{ "clients": { "zfls": { "enabled": true, "command": ["zfls"], "selector": "source.fortran | source.modern-fortran" } } }
```

Kate, in the LSP Client's User Server Settings:

```json
{ "servers": { "fortran": { "command": ["zfls"], "url": "https://github.com/cesiumlang/zfls", "highlightingModeRegex": "^Fortran.*$" } } }
```

Zed, with its Fortran extension, whose server is fortls (zfls takes fortls's options), in `settings.json`:

```json
{ "lsp": { "fortls": { "binary": { "path": "zfls", "arguments": [] } } } }
```
