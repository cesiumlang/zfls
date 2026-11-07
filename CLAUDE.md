# Notes for coding agents

What a coding agent working on zfls needs to know besides the code, the
[readme](readme.md) and the [roadmap](todo.md). Mistakes that have been made
more than once are written down here so that they are not made again.

## Zig 0.17: what not to use

zfls builds with Zig 0.17.0, whose standard library marks many older
declarations deprecated in their doc comments. The compiler does not warn
about them, so they creep back in. Use the replacement:

| Deprecated | Use |
| --- | --- |
| `std.fmt.allocPrint(a, fmt, args)` | `a.print(fmt, args)` |
| `std.fmt.allocPrintSentinel` | `a.printSentinel` |
| `std.fmt.bufPrint(buf, fmt, args)` | `std.mem.print(buf, fmt, args)` |
| `std.mem.indexOf`, `indexOfPos`, `indexOfScalar`, `indexOfScalarPos`, `indexOfAny`, `indexOfNone`, `indexOfSentinel` | `std.mem.find`, `findPos`, `findScalar`, `findScalarPos`, `findAny`, `findNone`, `findSentinel` |
| `std.mem.lastIndexOf`, `lastIndexOfScalar`, `lastIndexOfAny` | `std.mem.findLast`, `findScalarLast`, `findLastAny` |
| `std.mem.indexOfMin`, `indexOfMinMax` | `std.mem.findMin`, `findMinMax` |
| `std.fs.path` | `std.Io.Dir.path` |
| `std.fs.path.resolve` | `std.Io.Dir.path.resolveAlloc` |
| `std.fs.max_path_bytes`, `max_name_bytes` | `std.Io.Dir.max_path_bytes`, `max_name_bytes` |
| `std.StringArrayHashMapUnmanaged` | `std.array_hash_map.String` |
| a hash map or `EnumMap` initialized with `.{}` | `.empty` |
| `std.ArrayList(T).getLast()` | `items[items.len - 1]` |
| `std.mem.copyForwards`, `copyBackwards` | `@memmove` |
| `std.meta.fieldNames(T)` | `@typeInfo(T).@"enum".field_names` (or `.@"struct"`, `.@"union"`) |
| `std.builtin` | `std.lang` |
| `builtin.os`, `builtin.cpu`, `builtin.abi`, `builtin.object_format` | `builtin.target.os`, `.cpu`, `.abi`, `.ofmt` |
| `builtin.mode` | `builtin.optimize` |
| `.Debug`, `.ReleaseSafe`, `.ReleaseFast`, `.ReleaseSmall` (`std.lang.Optimize`) | `.debug`, `.safe`, `.fast`, `.small` |
| `OptimizeMode` | `std.lang.Optimize` |
| `Build.Step.Run.addArtifactArg(x)`, `addDirectoryArg(x)`, `addOutputFileArg(x)`, `addOutputDirectoryArg(x)` | the `...Arg2(x, .{})` ones |
| `Build.Step.Run.addPrefixedDirectoryArg(p, x)` | `addDirectoryArg2(x, .{ .prefix = p })` |

When in doubt, read the declaration in the Zig installation's `lib/std`: a
deprecated one has a doc comment starting with "Deprecated" (or saying
that its default initialization is). The list is not complete; the
standard library is the reference.

To check a change, ask ZLS: hovering a name shows its declaration's doc
comment, so a "Deprecated" there is a deprecated use. (`std.Io.Dir.path`
itself is an alias of `std.fs.path` without a doc comment of its own, so
ZLS shows the old one's "Deprecated" on it: that one is fine.)

## How the project works

- **Zig over other languages.** Anything that does not need another
  language is written in Zig: build steps (`build/`), generators, test
  drivers (`tests/*.zig`), tools. The only Python left runs fortls's own
  code (`tests/fortls_parity.py`, `tests/differential.py`,
  `tests/issues/upstream_check.py`). The VS Code extension is TypeScript,
  but code other editors could use belongs in the server, not in it.
- **Branches.** Work goes on a branch, in its own git worktree when other
  sessions may be working in the main checkout, and reaches `dev` through
  a pull request. `main` only takes releases, from `dev`.
- **The roadmap is [todo.md](todo.md).** Mark an item `[~]` when work on it
  starts and `[x]` in the pull request that finishes it; ideas not
  scheduled yet are under "Proposed".
- **The debug options' output is ours.** What `--debug_*` prints serves
  zfls's own testing; it need not match fortls's, so change it as tests
  need.
- **Generated files.** After changing the options in `src/settings.zig` or
  the extension's user-visible strings, run `zig build generated` (CI runs
  `zig build check-generated`).
- **Checks before a pull request.** `zig build test`, `zig fmt --check
  build build.zig src tests tools`, `zig build check-generated`, and for the
  extension `npx tsc --noEmit -p .` in `editors/vscode`. Do not run the
  extension's `npm test` locally: it opens VS Code windows. CI runs it.
- **File size.** Keep source files under about 900 lines; split larger ones
  by concern, as `src/server/` and `src/dap/` are ("Part of `Server`
  (server.zig): each function takes it as `self`").
- **`vendor/rstd` is another project's**, with a strict no-AI policy: make
  no commits there and put no AI attribution in it. Changes to it are left
  staged on a branch for its maintainer.
