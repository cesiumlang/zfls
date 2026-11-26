# Notes for coding agents

What a coding agent working on zfls needs to know besides the code, the [readme](readme.md) and the [issues](https://github.com/cesiumlang/zfls/issues). Mistakes that have been made more than once are written down here so that they are not made again.

## Zig 0.17: what not to use

zfls builds with Zig 0.17.1, whose standard library marks many older declarations deprecated in their doc comments. The compiler does not warn about them, so they creep back in. Use the replacement:

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
| `-Doptimize=Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` (build scripts, CI, docs) | `-Doptimize=debug`, `safe`, `fast`, `small` |
| `OptimizeMode` | `std.lang.Optimize` |
| `Build.Step.Run.addArtifactArg(x)`, `addDirectoryArg(x)`, `addOutputFileArg(x)`, `addOutputDirectoryArg(x)` | the `...Arg2(x, .{})` ones |
| `Build.Step.Run.addPrefixedDirectoryArg(p, x)` | `addDirectoryArg2(x, .{ .prefix = p })` |

When in doubt, read the declaration in the Zig installation's `lib/std`: a deprecated one has a doc comment starting with "Deprecated" (or saying that its default initialization is). The list is not complete; the standard library is the reference.

To check a change, ask ZLS: hovering a name shows its declaration's doc comment, so a "Deprecated" there is a deprecated use. (`std.Io.Dir.path` itself is an alias of `std.fs.path` without a doc comment of its own, so ZLS shows the old one's "Deprecated" on it: that one is fine.)

## How the project works

- **Zig over other languages.** Anything that does not need another language is written in Zig: build steps (`build/`), generators, test drivers (`tests/*.zig`), tools. The only Python left runs fortls's own code (`tests/fortls_parity.py`, `tests/differential.py`, `tests/issues/upstream_check.py`). The VS Code extension is TypeScript, but code other editors could use belongs in the server, not in it. The agents' Roadmap scripts in `tools/agent/` are bash, as they only drive `gh`.
- **Branches.** Work goes on a branch, in its own git worktree when other sessions may be working in the main checkout, and reaches `dev` through a pull request. `main` only takes releases, from `dev`.
- **The backlog is the [issues](https://github.com/cesiumlang/zfls/issues), and their order is the project [zfls Roadmap](https://github.com/orgs/cesiumlang/projects/2)** (emanspeaks, 2026-11-26, as skein does): its rows are in priority order, the next thing to work is the first that is not done, and a new issue goes in at its place, not at the end. Each issue is one task, landed in one pull request; split a larger plan into one issue per step. The pull request closes the issue with `Closes #N` in its description: GitHub does that only for merges into the default branch, so the `close-issues` workflow (the organization's, cesiumlang/.github) does it for merges into `dev`, with a comment naming the pull request, and closing it sets the row Done.
- **The Roadmap's scripts** (`tools/agent/`, bash over `gh`, run with the app's token or none): `board.sh` lists the rows not done, in order; `file-issue.sh TITLE BODY_FILE LABELS AFTER [BLOCKER...]` files an issue (body ending with `_Filed by Claude at the request of emanspeaks._`) in the next version's milestone (or `MILESTONE="upstream backlog"`) with `agent`, after the row of `AFTER` (or `top`), with its "blocked by" links; `place.sh N AFTER` adds or moves a row; after a batch, `next-action.sh` brings "Next action" and the `agent` label in line with the assignees.
- **Milestones are release versions** (`v0.5.1`), and every open issue is in the next one, but for those waiting on a project zfls can neither work around nor influence (conda-forge's review, an LLVM release), which are in `upstream backlog` (emanspeaks, 2026-11-26, as rstd does) and move into a release's milestone once that project moves. Work waiting on a compiler zfls supports (LFortran) stays in the next version: it can be worked around, or its direction influenced. The Roadmap, not the `dev` to `main` pull request, tracks the issues, so its description lists none.
- **Whose action is next** is said three ways, kept the same: emanspeaks is the assignee only where he must answer or do something an agent cannot; everything else is the agent's, with no assignee, the label `agent`, and "Next action: agent" on the Roadmap.
- **Labels:** `blocked` with a `**Blocked:**` line naming the outside cause, `upstream: <project>` for work waiting on or following another project, `compiler: <name>` (`gfortran`, `ifx`, `ifort`, `flang`, `nvfortran`, `nagfor`, `lfortran`) for work specific to one compiler, `awaiting input` for a decision the user makes, `housekeeping` for readability and structure work. `**Needs:**` links the issues that must land first. Upstream issues are cited as in the readme (`FL #438`), ours as `#N`. Don't open issues for follow-ups on your own; report them. Pull requests take the release-note labels of `.github/release.yml` (`fix`, `feature`, `performance`, `tests`, `refactor`, `ci`, `skip-changelog`); their titles are the release notes.
- **GitHub: the Cesium Agent app.** On GitHub, act as the GitHub App Cesium Agent (`cesium-agent[bot]`), not as the maintainer (cesium-workspace#6; cesium-workspace's CLAUDE.md has the details). Prefix `gh` commands with `GH_TOKEN="$(bash /c/scratch/github-apps/app-token.sh cesiumlang)"`, and run git commands that commit or push as `bash /c/scratch/github-apps/app-git.sh cesiumlang <git arguments>`. Never print, copy or commit anything in `C:\scratch\github-apps\cesiumlang\`. The app merges pull requests into `dev`; the `dev` to `main` pull request is merged by the maintainer, or on his word.
- **The debug options' output is ours.** What `--debug_*` prints serves zfls's own testing; it need not match fortls's, so change it as tests need.
- **Generated files.** After changing the options in `src/settings.zig` or the extension's user-visible strings, run `zig build generated` (CI runs `zig build check-generated`).
- **Release signing.** `ci.yml`'s `sign-windows` (Azure Artifact Signing) and `sign-macos` (Developer ID, notarytool) jobs sit between `compile` and `build`; each is skipped while its configuration is unset (`SIGN_AZURE_CLIENT_ID` and the other `SIGN_*` repository variables; `APPLE_SIGNING` and the `APPLE_*` secrets), and a failed one fails the run. The signing identity needs the Artifact Signing Certificate Profile Signer role on the signing account itself: on the identity's own page or another scope it gets a 403 after a successful login. Each repository that signs needs its own federated credential (pull request, `main`, and a test branch). Agents cannot set repository variables or secrets as the Cesium Agent app; the maintainer does. Signing a local build for a Defender test is the global `sign-local` skill's job, never a build step.
- **Checks before a pull request.** `zig build test`, `zig fmt --check build build.zig src tests tools`, `zig build check-generated`, and for the extension `npx tsc --noEmit -p .` in `editors/vscode`. Do not run the extension's `npm test` locally: it opens VS Code windows. CI runs it. CI does not run on pull requests into `dev` (only on those into `main`, and when started by hand: `gh workflow run ci.yml --ref BRANCH`), so these checks, with `zig build test-differential` and `zig build test-parity` for changes to the server, are what stands between a change and `dev`: run them after merging `origin/dev` into the branch, and say in the pull request which were run.
- **Compilers for local tests** live in `.toolchains/` at the root of the checkout, which git ignores (emanspeaks, 2026-11-26): pixi environments `flang/` (LLVM Flang) and `ifx/` (`.pixi/envs/default/Library/bin/flang.exe`, `ifx.exe`; recreate one with `pixi install --manifest-path .toolchains/<name>/pixi.toml --frozen`, never by moving it, as conda prefixes are baked in), `llvm-tools/` (`llvm-objdump`, `llvm-pdbutil` and others, with the DLLs they need), and `lldb-23.1.6/bin/` (lldb-dap 23.1.6, from `LLVM-23.1.6-win64.msi`, unpacked with 7-Zip; it needs a `python3.dll` on the `PATH`, as Python 3.12's in `C:scratchminiforge3`). Nothing for zfls goes in `C:\scratch` outside the checkout.
- **File size.** Keep source files under about 900 lines; split larger ones by concern, as `src/server/` and `src/dap/` are ("Part of `Server` (server.zig): each function takes it as `self`").
- **`vendor/rstd` is another project's**, with a strict no-AI policy: make no commits there and put no AI attribution in it. Changes to it are left staged on a branch for its maintainer.
