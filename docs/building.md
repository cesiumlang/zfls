# Building

zfls needs Zig 0.17.1.

```sh
git clone --recurse-submodules <repository>
cd zfls
zig build -Doptimize=fast
```

The executable is `zig-out/bin/zfls` (`zfls.exe` on Windows). `zig build` also generates the API documentation in `zig-out/docs`; `zig build bin` installs only the executable.

Each release also publishes `zfls-v<version>-src.tar.gz`, the sources with its submodules included (`zig build source-archive -- [OUT_DIR]`), and `zfls-v<version>-conda-recipe.yaml`, the conda-forge recipe that builds it. `zig build conda-recipe -- --release ARCHIVE OUT_DIR` writes that recipe from the template in `packaging/conda-forge` (`--local` instead builds from the archive itself). CI builds and tests the recipe on Linux, macOS and Windows for every change.

## VS Code extension

`editors/vscode` is a VS Code extension that runs zfls for Fortran files and adds syntax highlighting. Each release publishes it as `zfls-vscode-v<version>-<platform>.vsix`, one per VS Code platform with that platform's zfls inside (`zig build package-vscode -- DIST`, from the release archives in DIST), plus a `universal` one that runs `zfls` from the `PATH`. To install one, use "Extensions: Install from VSIX..." in VS Code. The release also publishes the platform packages, as `cesiumlang.zfls`, to the Visual Studio Marketplace and to Open VSX (VSCodium and other VS Code derivatives), and the universal one to the Marketplace for the platforms without their own. Each registry has its own workflow, which the release job starts and which takes the packages from the release: "Publish to the Marketplace" (`.github/workflows/marketplace.yml`) uses Marketplace Trusted Publishing (`vsce publish --oidc`: the publisher's Trusted Publishing policy names this repository and that workflow file), and falls back, with a warning, to a Microsoft Entra managed identity that is a member of the publisher (the `AZURE_*` repository variables; the "Marketplace identity" workflow shows the ID to add); and "Publish to Open VSX" (`.github/workflows/open-vsx.yml`) is the workflow whose OIDC token Open VSX trusts for the `cesiumlang` namespace (trusted publishing; the `OVSX_PAT` repository secret is used only if that is refused, with a warning). No stored token is needed. Either workflow can be run by hand, on `main`, for any released version; versions already published are skipped, so a failed run can simply be run again.

The extension replaces the Modern Fortran extension (it registers the same Fortran languages, grammars and snippets, with zfls instead of fortls) and recommends disabling Modern Fortran when both are enabled; see its [README](https://github.com/cesiumlang/zfls/blob/main/editors/vscode/README.md#replacing-modern-fortran).

To work on it: Node.js is the version in `.node-version`, which the `.envrc` selects through [fnm](https://github.com/Schniz/fnm) when [direnv](https://direnv.net) is installed (CI's workflows read it too).

```sh
cd editors/vscode
npm ci
npm run typecheck
ZFLS_PATH=../../zig-out/bin/zfls npm test   # in a downloaded VS Code
```

- `engines.vscode` is zfls's oldest supported VS Code (1.102); `@types/vscode` matches it, and `@types/node` and esbuild's target follow its Node.js (22).
- Dependencies are pinned to exact versions and kept free of `npm audit` findings.
- `overrides` in `package.json` forces `minimatch` 11.0.9: `@vscode/vsce` 4.1.1 and `vscode-languageclient` 11.0.0 ask for `^10.2.6`, which has [GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249) (fixed in 11.0.1). Drop the override once they depend on a fixed version.
