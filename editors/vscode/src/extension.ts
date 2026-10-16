// zfls for VS Code: starts the zfls language server for Fortran files.

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

import { affectsServer, serverArguments } from "./options";

const MODERN_FORTRAN = "fortran-lang.linter-gfortran";
const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];

/** The running servers: one per outermost workspace folder (keyed by its
 * URI), and one per directory of a Fortran file outside every folder (keyed
 * by the directory's URI), as in VS Code's multi-root language server sample */
const clients = new Map<string, Promise<LanguageClient | undefined>>();
let output: vscode.LogOutputChannel | undefined;
let context: vscode.ExtensionContext;

export async function activate(ctx: vscode.ExtensionContext): Promise<void> {
  context = ctx;
  output = vscode.window.createOutputChannel("zfls", { log: true });
  context.subscriptions.push(
    output,
    vscode.commands.registerCommand("zfls.restart", () => restartAll()),
    vscode.commands.registerCommand("zfls.showOutput", () => output?.show()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (affectsServer(e)) {
        void restartAll();
      }
    }),
    vscode.workspace.onDidOpenTextDocument((doc) => void ensureClient(doc)),
    vscode.workspace.onDidChangeWorkspaceFolders((e) => {
      for (const folder of e.removed) {
        void stopClient(folder.uri.toString());
      }
      // a folder that now contains a separately served file takes it over
      void restartAll();
    }),
  );
  for (const doc of vscode.workspace.textDocuments) {
    await ensureClient(doc);
  }
  void checkModernFortran();
}

export async function deactivate(): Promise<void> {
  await Promise.all([...clients.keys()].map((key) => stopClient(key)));
}

async function stopClient(key: string): Promise<void> {
  const client = clients.get(key);
  clients.delete(key);
  await (await client)?.stop();
}

async function restartAll(): Promise<void> {
  await deactivate();
  for (const doc of vscode.workspace.textDocuments) {
    await ensureClient(doc);
  }
}

/** The outermost workspace folder containing `folder` (a nested folder is
 * served by the server of the folder it is in) */
function outermost(folder: vscode.WorkspaceFolder): vscode.WorkspaceFolder {
  let best = folder;
  for (const f of vscode.workspace.workspaceFolders ?? []) {
    const root = f.uri.toString().replace(/\/?$/, "/");
    if (folder.uri.toString().startsWith(root) && f.uri.toString().length < best.uri.toString().length) {
      best = f;
    }
  }
  return best;
}

/** Starts the server for a Fortran file, unless it has one */
async function ensureClient(doc: vscode.TextDocument): Promise<void> {
  if (!LANGUAGES.includes(doc.languageId) || doc.uri.scheme !== "file") {
    return;
  }
  const inFolder = vscode.workspace.getWorkspaceFolder(doc.uri);
  const folder = inFolder ? outermost(inFolder) : undefined;
  const root = folder ? folder.uri : vscode.Uri.file(path.dirname(doc.uri.fsPath));
  const key = root.toString();
  if (clients.has(key)) {
    return;
  }
  // the start in progress is recorded, so that files opened meanwhile share it
  const client = startClient(root, folder);
  clients.set(key, client);
  if (!(await client)) {
    clients.delete(key);
  }
}

async function startClient(root: vscode.Uri, folder: vscode.WorkspaceFolder | undefined): Promise<LanguageClient | undefined> {
  const config = vscode.workspace.getConfiguration("zfls", folder?.uri);
  const command = findServer(context, config.get<string>("path", ""));
  if (!command) {
    const choice = await vscode.window.showErrorMessage(
      "zfls: no zfls executable found. Set zfls.path, or put zfls on the PATH.",
      "Open Settings",
    );
    if (choice) {
      await vscode.commands.executeCommand("workbench.action.openSettings", "zfls.path");
    }
    return undefined;
  }
  const args = serverArguments(folder);
  output?.info(`Starting ${command} ${args.join(" ")} for ${root.fsPath}`);

  // no `transport`: stdio is the default, and TransportKind.stdio would
  // also pass --stdio, which zfls (like fortls) does not accept
  const executable = { command, args, options: { cwd: root.fsPath } };
  const serverOptions: ServerOptions = { run: executable, debug: executable };
  // a folder's server takes the files under it; a directory's server only
  // the files directly in it
  const pattern = folder ? `${root.fsPath}/**/*` : `${root.fsPath}/*`;
  const clientOptions: LanguageClientOptions = {
    documentSelector: LANGUAGES.map((language) => ({ scheme: "file", language, pattern })),
    workspaceFolder: folder ?? { uri: root, name: path.basename(root.fsPath), index: -1 },
    outputChannel: output,
  };
  const name = folder ? `zfls (${folder.name})` : `zfls (${root.fsPath})`;
  const client = new LanguageClient("zfls", name, serverOptions, clientOptions);
  try {
    await client.start();
  } catch (err) {
    void vscode.window.showErrorMessage(`zfls failed to start: ${String(err)}`);
    return undefined;
  }
  return client;
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

/** Modern Fortran starts fortls for the same files; offer to turn that off
 * so that only one language server answers. */
async function checkModernFortran(): Promise<void> {
  const config = vscode.workspace.getConfiguration("zfls");
  if (config.get<boolean>("disableModernFortranCheck", false)) {
    return;
  }
  if (!vscode.extensions.getExtension(MODERN_FORTRAN)) {
    return;
  }
  const fortran = vscode.workspace.getConfiguration("fortran");
  if (fortran.get<boolean>("fortls.disabled", false)) {
    return;
  }
  const disable = "Turn off its fortls";
  const never = "Don't ask again";
  const choice = await vscode.window.showInformationMessage(
    "The Modern Fortran extension also runs a Fortran language server (fortls). " +
      "Turn it off so that zfls alone answers? Modern Fortran keeps its other features.",
    disable,
    never,
  );
  if (choice === disable) {
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
