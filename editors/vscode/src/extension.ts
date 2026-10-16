// zfls for VS Code: starts the zfls language server for Fortran files, and
// lints them with a compiler (linter.ts).

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";
import { Linter } from "./linter";
import { registerRunCommands } from "./runFile";

const MODERN_FORTRAN = "fortran-lang.linter-gfortran";
/** The default of `zfls.arguments` (package.json), as Modern Fortran starts fortls */
const defaultArguments = ["--incremental_sync", "--use_signature_help", "--enable_code_actions", "--hover_signature"];

let client: LanguageClient | undefined;
let output: vscode.LogOutputChannel | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  output = vscode.window.createOutputChannel("zfls", { log: true });
  const linter = new Linter(context, output);
  registerRunCommands(context, output);
  context.subscriptions.push(
    output,
    linter,
    vscode.commands.registerCommand("zfls.restart", () => restart(context)),
    vscode.commands.registerCommand("zfls.showOutput", () => output?.show()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("zfls.path") || e.affectsConfiguration("zfls.arguments")) {
        void restart(context);
      }
    }),
  );
  // compiler diagnostics do not wait for the language server
  linter.activate();
  await start(context);
  void checkModernFortran();
}

export async function deactivate(): Promise<void> {
  await client?.stop();
  client = undefined;
}

async function restart(context: vscode.ExtensionContext): Promise<void> {
  await client?.stop();
  client = undefined;
  await start(context);
}

async function start(context: vscode.ExtensionContext): Promise<void> {
  const config = vscode.workspace.getConfiguration("zfls");
  const command = findServer(context, config.get<string>("path", ""));
  if (!command) {
    const choice = await vscode.window.showErrorMessage(
      "zfls: no zfls executable found. Set zfls.path, or put zfls on the PATH.",
      "Open Settings",
    );
    if (choice) {
      await vscode.commands.executeCommand("workbench.action.openSettings", "zfls.path");
    }
    return;
  }
  const args = config.get<string[]>("arguments", defaultArguments);
  output?.info(`Starting ${command} ${args.join(" ")}`);

  // no `transport`: stdio is the default, and TransportKind.stdio would
  // also pass --stdio, which zfls (like fortls) does not accept
  const executable = { command, args };
  const serverOptions: ServerOptions = { run: executable, debug: executable };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "FortranFreeForm" },
      { scheme: "file", language: "FortranFixedForm" },
    ],
    outputChannel: output,
  };
  client = new LanguageClient("zfls", "zfls", serverOptions, clientOptions);
  try {
    await client.start();
  } catch (err) {
    void vscode.window.showErrorMessage(`zfls failed to start: ${String(err)}`);
  }
}

/** The zfls to run: the configured one, else the bundled one, else `zfls`
 * on the PATH. */
function findServer(context: vscode.ExtensionContext, configured: string): string | undefined {
  const exe = process.platform === "win32" ? "zfls.exe" : "zfls";
  if (configured) {
    return configured;
  }
  const bundled = context.asAbsolutePath(path.join("bin", exe));
  if (fs.existsSync(bundled)) {
    ensureExecutable(bundled);
    return bundled;
  }
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    const candidate = path.join(dir, exe);
    if (dir && fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return undefined;
}

/** Restores the executable bit of the bundled zfls should unpacking the
 * extension have dropped it. */
function ensureExecutable(file: string): void {
  if (process.platform === "win32") {
    return;
  }
  try {
    fs.accessSync(file, fs.constants.X_OK);
  } catch {
    try {
      fs.chmodSync(file, 0o755);
    } catch (err) {
      output?.warn(`cannot make ${file} executable: ${String(err)}`);
    }
  }
}

/** zfls replaces the Modern Fortran extension: both register the same
 * Fortran languages, grammars and snippets, Modern Fortran starts its own
 * language server (fortls), and both lint with a compiler. Recommend
 * disabling it; extensions cannot disable one another, so this opens its
 * page where the user can. Keeping it with its fortls and linter turned off
 * stays possible, for the features zfls does not have yet. */
async function checkModernFortran(): Promise<void> {
  const config = vscode.workspace.getConfiguration("zfls");
  if (config.get<boolean>("disableModernFortranCheck", false)) {
    return;
  }
  // only an enabled extension is found
  if (!vscode.extensions.getExtension(MODERN_FORTRAN)) {
    return;
  }
  const fortran = vscode.workspace.getConfiguration("fortran");
  const fortlsOn = !fortran.get<boolean>("fortls.disabled", false);
  // both linting would show each compiler message twice
  const lintOn = config.get<string>("linter.compiler", "gfortran") !== "Disabled" &&
    fortran.get<string>("linter.compiler", "gfortran") !== "Disabled";
  if (!fortlsOn && !lintOn) {
    // kept on purpose, with its language server and linter off
    return;
  }
  const disable = "Disable Modern Fortran...";
  const keep = "Keep it, turn off its fortls and linter";
  const never = "Don't ask again";
  const choice = await vscode.window.showWarningMessage(
    "The Modern Fortran extension is also enabled. zfls replaces it: the language server, " +
      "compiler diagnostics, syntax highlighting, snippets and breakpoints. With both, two " +
      "language servers, two linters and two sets of grammars compete for Fortran files, so " +
      "disable Modern Fortran. (zfls does not have its formatting yet.)",
    disable,
    keep,
    never,
  );
  if (choice === disable) {
    await vscode.commands.executeCommand("extension.open", MODERN_FORTRAN);
    void vscode.window.showInformationMessage(
      'Select "Disable" on the Modern Fortran page, then reload the window.',
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
      "Modern Fortran's fortls is turned off; reload the window to stop it.",
      "Reload Window",
    );
    if (reload) {
      await vscode.commands.executeCommand("workbench.action.reloadWindow");
    }
  } else if (choice === never) {
    await config.update("disableModernFortranCheck", true, vscode.ConfigurationTarget.Global);
  }
}
