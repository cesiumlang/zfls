# Building a file to run or debug (`zfls/buildCommand`)

zfls says how to build a Fortran file into a program to run or debug, so that every editor builds it the same way (the VS Code extension's Run Fortran File and Debug Fortran File run this build as a task): the compiler's default options for a debug build (`-g -O0`; `/Zi /Od` for ifx and ifort on Windows; `-g -O0 -static-libgfortran -static-libquadmath` for MinGW's gfortran, so that gdb stops at the errors its runtime raises; `-gdwarf-4 -O0 -Wl,-debug:dwarf` for LLVM Flang on Windows where it has an `lld-link`, for gdb; for LFortran, its build through its IR, `zfls lfortran-ir`, with clang or llc, and on Windows lld-link, for CodeView; else `-g`), the file's directory on the include path, a directory of its own per source file in zfls's cache (`run` in it) for the program and the module and object files, the modules of conda-forge's ifx (`-I`, `/I` on Windows), and on Windows the link of ifx's, LLVM Flang's and LFortran's programs with zfls's ifx kit (see [ifx without Visual Studio](ifx-kit.md)). It answers the request `zfls/buildCommand`, and the same on the command line:

```sh
zfls build-command hello.f90 [--compiler C] [--compiler-path P] [--output-dir D] [--kit DIR] [-- ARGS...]
```

The request's parameters are `textDocument`, `compiler` (a name looked up on the `PATH`, or a path; `gfortran` by default), `compilerPath` (its file or directory, relative to the workspace), `args` (the build's options in place of the defaults), `outputDirectory` and `env` (values in place of the environment's, such as `{"Path": "${env:Path}"}` for a tasks.json). The answer, `null` when the compiler is not found:

```json
{
  "compiler": "/usr/bin/gfortran",
  "name": "gfortran",
  "debugInfo": "dwarf",
  "debugger": "gdb",
  "runEnv": {},
  "args": ["-g", "-O0", "-I/work", "-o", "/home/me/.cache/zfls/run/hello-1a2b3c4d5e/hello", "/work/hello.f90"],
  "cwd": "/home/me/.cache/zfls/run/hello-1a2b3c4d5e",
  "env": {},
  "program": "/home/me/.cache/zfls/run/hello-1a2b3c4d5e/hello"
}
```

Run `compiler` with `args` in `cwd`, with `env` added to the environment (on Windows, the compiler's directory first on the `PATH`, which MinGW's gfortran needs for its `f951` when it is given by its path, and the kit's `LIB` and `LINK`); when the answer has `linkArgs`, the build is in two steps: `args` compiles (`-c`), and `compiler` with `linkArgs`, run the same way, links. Then run `program` with `runEnv` added (on Windows, the compiler's directory first on the `PATH`, for its runtime libraries). `debugInfo` is the program's debug information (`dwarf`, or `pdb` for Microsoft's) and `debugger` the debugger of `zfls dap` that fits it (`gdb`, `lldb` on macOS, `dbgeng` for a PDB; see [A debugger](debugging.md#a-debugger-zfls-dap)). `note` says why a build links otherwise than it could (no ifx kit, no `lld-link`). Nix's gfortran on macOS builds in two steps: its wrapper sets `DEVELOPER_DIR` to Nix's SDK, so the `dsymutil` that a `-g` build runs after linking finds no tool (`error: tool 'dsymutil' not found`) and the build fails; linked apart, the program has no `.dSYM`, and lldb reads the debug information from the object file, which stays in `cwd`. Without a `textDocument`, the answer has only the compiler's part (`compiler`, `name`, `debugInfo`, `debugger`, `runEnv`), for a program built otherwise.

With Neovim, a command that builds the current file and runs it in a terminal:

```lua
vim.api.nvim_create_user_command("FortranRun", function()
  local client = vim.lsp.get_clients({ name = "zfls", bufnr = 0 })[1]
  client:request("zfls/buildCommand", { textDocument = vim.lsp.util.make_text_document_params() }, function(_, cmd)
    if not cmd then return vim.notify("zfls: no compiler", vim.log.levels.ERROR) end
    local env = vim.tbl_extend("force", vim.fn.environ(), cmd.env, cmd.runEnv)
    local function step(args, after)
      vim.system(vim.list_extend({ cmd.compiler }, args), { cwd = cmd.cwd, env = env, text = true }, vim.schedule_wrap(function(built)
        if built.code ~= 0 then return vim.notify(built.stderr, vim.log.levels.ERROR) end
        after()
      end))
    end
    local function run()
      vim.cmd.split()
      vim.fn.jobstart({ cmd.program }, { term = true, env = cmd.runEnv })
    end
    step(cmd.args, cmd.linkArgs and function() step(cmd.linkArgs, run) end or run)
  end)
end, {})
```

With Emacs, through `compile`:

```elisp
(defun zfls-run-file ()
  "Build the current Fortran file with the command zfls answers, and run it."
  (interactive)
  (let* ((cmd (json-parse-string
               (shell-command-to-string (concat "zfls build-command " (shell-quote-argument buffer-file-name)))
               :object-type 'alist))
         (default-directory (file-name-as-directory (alist-get 'cwd cmd)))
         (process-environment
          (append (mapcar (lambda (v) (format "%s=%s" (car v) (cdr v)))
                          (append (alist-get 'env cmd) (alist-get 'runEnv cmd)))
                  process-environment)))
    (cl-flet ((step (key) (when-let* ((args (alist-get key cmd)))
                            (concat (mapconcat #'shell-quote-argument (cons (alist-get 'compiler cmd) (append args nil)) " ") " && "))))
      (compile (concat (step 'args) (step 'linkArgs) (shell-quote-argument (alist-get 'program cmd)))))))
```

With Helix, a key in `config.toml` (Linux and macOS, where the answer's environments are empty; with `jq`):

```toml
[keys.normal.space]
r = ":run-shell-command zfls build-command %{buffer_name} | jq -r '\"cd \" + (.cwd | @sh) + \" && \" + ([.compiler] + .args | map(@sh) | join(\" \")) + (if .linkArgs then \" && \" + ([.compiler] + .linkArgs | map(@sh) | join(\" \")) else \"\" end) + \" && \" + (.program | @sh)' | sh"
```
