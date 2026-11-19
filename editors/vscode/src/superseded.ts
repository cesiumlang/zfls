// The extensions that zfls replaces: when one is enabled, zfls recommends
// disabling it, since both would serve Fortran files.

import * as vscode from "vscode";

const MODERN_FORTRAN = "fortran-lang.linter-gfortran";

/** An extension zfls replaces: its name, and why to disable it */
interface Superseded {
  id: string;
  name: string;
  message: () => string;
}

/** The extensions zfls replaces, with what each duplicates */
const SUPERSEDED: readonly Superseded[] = [
  {
    // registers the same languages, grammars and snippets, starts fortls
    // and lints with a compiler
    id: MODERN_FORTRAN,
    name: "Modern Fortran",
    message: () =>
      vscode.l10n.t(
        "The Modern Fortran extension is also enabled. zfls replaces it: the language server, formatting, " +
          "compiler diagnostics, run and debug, syntax highlighting, snippets and breakpoints. With both, two " +
          "language servers, two linters and two sets of grammars compete for Fortran files, so " +
          "disable Modern Fortran.",
      ),
  },
  {
    // Modern Fortran's id before fortran-lang took it over
    id: "krvajalm.linter-gfortran",
    name: "Modern Fortran (krvajalm.linter-gfortran)",
    message: () =>
      vscode.l10n.t(
        "The old Modern Fortran extension (krvajalm.linter-gfortran) is also enabled. It registers the same " +
          "Fortran languages and grammars as zfls and lints with gfortran, so Fortran files get two sets of " +
          "grammars and each compiler message twice; disable it.",
      ),
  },
  {
    id: "hansec.fortran-ls",
    name: "FORTRAN IntelliSense",
    message: () =>
      vscode.l10n.t(
        "The FORTRAN IntelliSense extension is also enabled. It starts a language server of its own (fortls) " +
          "for Fortran files, so every completion and hover comes twice; zfls replaces it, so disable " +
          "FORTRAN IntelliSense.",
      ),
  },
  {
    id: "ekibun.fortranbreaker",
    name: "Fortran Breakpoint Support",
    message: () =>
      vscode.l10n.t(
        "The Fortran Breakpoint Support extension is also enabled. zfls lets you set breakpoints in Fortran " +
          "files itself, so it is not needed; disable it.",
      ),
  },
];

/** Recommends disabling each enabled extension that zfls replaces.
 * Extensions cannot disable one another, so this opens its page where the
 * user can. Keeping Modern Fortran with its fortls and linter turned off
 * stays possible. "Don't ask again" (`zfls.disableModernFortranCheck`)
 * stops the checks of them all. */
export async function checkSuperseded(): Promise<void> {
  for (const ext of SUPERSEDED) {
    if (vscode.workspace.getConfiguration("zfls").get<boolean>("disableModernFortranCheck", false)) {
      return;
    }
    // only an enabled extension is found
    if (vscode.extensions.getExtension(ext.id)) {
      await recommendDisabling(ext);
    }
  }
}

async function recommendDisabling(ext: Superseded): Promise<void> {
  const config = vscode.workspace.getConfiguration("zfls");
  const modernFortran = ext.id === MODERN_FORTRAN;
  const fortran = vscode.workspace.getConfiguration("fortran");
  const fortlsOn = !fortran.get<boolean>("fortls.disabled", false);
  // both linting would show each compiler message twice
  const lintOn = config.get<string>("linter.compiler", "gfortran") !== "Disabled" &&
    fortran.get<string>("linter.compiler", "gfortran") !== "Disabled";
  if (modernFortran && !fortlsOn && !lintOn) {
    // kept on purpose, with its language server and linter off
    return;
  }
  const disable = vscode.l10n.t("Disable {0}...", ext.name);
  const keep = vscode.l10n.t("Keep it, turn off its fortls and linter");
  const never = vscode.l10n.t("Don't ask again");
  const choice = await vscode.window.showWarningMessage(ext.message(), disable, ...(modernFortran ? [keep] : []), never);
  if (choice === disable) {
    await vscode.commands.executeCommand("extension.open", ext.id);
    void vscode.window.showInformationMessage(
      vscode.l10n.t('Select "Disable" on the page of {0}, then reload the window.', ext.name),
    );
  } else if (choice === keep) {
    if (lintOn) {
      await fortran.update("linter.compiler", "Disabled", vscode.ConfigurationTarget.Global);
    }
    if (!fortlsOn) {
      return;
    }
    await fortran.update("fortls.disabled", true, vscode.ConfigurationTarget.Global);
    const reload = await vscode.window.showInformationMessage(
      vscode.l10n.t("Modern Fortran's fortls is turned off; reload the window to stop it."),
      vscode.l10n.t("Reload Window"),
    );
    if (reload) {
      await vscode.commands.executeCommand("workbench.action.reloadWindow");
    }
  } else if (choice === never) {
    await config.update("disableModernFortranCheck", true, vscode.ConfigurationTarget.Global);
  }
}
