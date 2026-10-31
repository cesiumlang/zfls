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
import { FORTRAN_FILES, Linter } from "./linter";
import { registerFormatting } from "./formatting";
import { registerRunCommands } from "./runFile";

import { affectsServer, serverArguments } from "./options";

const MODERN_FORTRAN = "fortran-lang.linter-gfortran";
const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];

/** The running servers: one per outermost workspace folder (keyed by its
 * URI), and one per directory of a Fortran file outside every folder (keyed
 * by the directory's URI), as in VS Code's multi-root language server sample */
const clients = new Map<string, Promise<LanguageClient | undefined>>();
/** The file watchers of each client, disposed when it stops */
const watchers = new Map<string, vscode.Disposable[]>();
/** The files whose change restarts the server that reads them */
const SERVER_CONFIG_FILES = "{.fortlsrc,.fortls.json,.fortls,fpm.toml,compile_commands.json,build/compile_commands.json}";
/** Restarts after configuration files change, waiting for them to settle */
const CONFIG_RESTART_DELAY_MS = 1000;
let restartTimer: NodeJS.Timeout | undefined;
let output: vscode.LogOutputChannel | undefined;
let context: vscode.ExtensionContext;

export async function activate(ctx: vscode.ExtensionContext): Promise<void> {
  context = ctx;
  output = vscode.window.createOutputChannel("zfls", { log: true });
  const linter = new Linter(context, output);
  registerFormatting(context, output);
  registerRunCommands(context, output);
  context.subscriptions.push(
    output,
    linter,
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
  // compiler diagnostics do not wait for the language server
  linter.activate();
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
  disposeWatchers(key);
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

/** The workspace folder whose server takes untitled files: the first */
function untitledFolder(): vscode.WorkspaceFolder | undefined {
  const first = vscode.workspace.workspaceFolders?.[0];
  return first ? outermost(first) : undefined;
}

/** The root of the server of untitled files when no folder is open: an
 * empty directory, so that it indexes nothing */
function untitledRoot(): vscode.Uri {
  const root = vscode.Uri.joinPath(context.globalStorageUri, "untitled");
  fs.mkdirSync(root.fsPath, { recursive: true });
  return root;
}

/** Starts the server for a Fortran file, unless it has one */
async function ensureClient(doc: vscode.TextDocument): Promise<void> {
  if (!LANGUAGES.includes(doc.languageId)) {
    return;
  }
  let folder: vscode.WorkspaceFolder | undefined;
  let root: vscode.Uri;
  if (doc.uri.scheme === "file") {
    const inFolder = vscode.workspace.getWorkspaceFolder(doc.uri);
    folder = inFolder ? outermost(inFolder) : undefined;
    root = folder ? folder.uri : vscode.Uri.file(path.dirname(doc.uri.fsPath));
  } else if (doc.uri.scheme === "untitled") {
    folder = untitledFolder();
    root = folder ? folder.uri : untitledRoot();
  } else {
    return;
  }
  const key = root.toString();
  if (clients.has(key)) {
    return;
  }
  // untitled files go to the server of the first workspace folder, or to
  // one of their own
  const untitled = folder ? folder.uri.toString() === untitledFolder()?.uri.toString() : doc.uri.scheme === "untitled";
  // the start in progress is recorded, so that files opened meanwhile share it
  const client = startClient(root, folder, untitled);
  clients.set(key, client);
  if (!(await client)) {
    clients.delete(key);
    disposeWatchers(key);
  }
}

function disposeWatchers(key: string): void {
  for (const w of watchers.get(key) ?? []) {
    w.dispose();
  }
  watchers.delete(key);
}

async function startClient(
  root: vscode.Uri,
  folder: vscode.WorkspaceFolder | undefined,
  untitled: boolean,
): Promise<LanguageClient | undefined> {
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
  // the server follows Fortran files changed outside the editor, and is
  // restarted when a file it reads its configuration from changes
  const sourceWatcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(root, folder ? `**/${FORTRAN_FILES}` : FORTRAN_FILES),
  );
  const configWatcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(root, SERVER_CONFIG_FILES));
  const restartSoon = (): void => {
    clearTimeout(restartTimer);
    restartTimer = setTimeout(() => {
      output?.info("A configuration file changed: restarting zfls");
      void restartAll();
    }, CONFIG_RESTART_DELAY_MS);
  };
  configWatcher.onDidCreate(restartSoon);
  configWatcher.onDidChange(restartSoon);
  configWatcher.onDidDelete(restartSoon);
  watchers.set(root.toString(), [sourceWatcher, configWatcher]);
  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      ...LANGUAGES.map((language) => ({ scheme: "file", language, pattern })),
      ...(untitled ? LANGUAGES.map((language) => ({ scheme: "untitled", language })) : []),
    ],
    workspaceFolder: folder ?? { uri: root, name: path.basename(root.fsPath), index: -1 },
    synchronize: { fileEvents: sourceWatcher },
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

/** zfls replaces the Modern Fortran extension: both register the same
 * Fortran languages, grammars and snippets, Modern Fortran starts its own
 * language server (fortls), and both lint with a compiler. Recommend
 * disabling it; extensions cannot disable one another, so this opens its
 * page where the user can. Keeping it with its fortls and linter turned off
 * stays possible. */
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
    "The Modern Fortran extension is also enabled. zfls replaces it: the language server, formatting, " +
      "compiler diagnostics, run and debug, syntax highlighting, snippets and breakpoints. With both, two " +
      "language servers, two linters and two sets of grammars compete for Fortran files, so " +
      "disable Modern Fortran.",
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
