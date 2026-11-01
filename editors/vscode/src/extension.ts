// zfls for VS Code: starts the zfls language server for Fortran files, and
// lints them with a compiler (linter.ts).

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  Location as ProtocolLocation,
  ServerOptions,
} from "vscode-languageclient/node";
import { FORTRAN_FILES, Linter } from "./linter";
import { registerFormatting } from "./formatting";
import { Fortitude } from "./fortitude";
import { toggleComments } from "./comments";
import { namelistGroups } from "./namelist";
import { INJECTION_FILE, isMarkerGrammar, markerGrammarText } from "./commentMarkers";
import { registerRunCommands } from "./runFile";
import { BindC, C_LANGUAGES, identifierAt, isCFile, uniqueByPlace } from "./interop";
import { registerFpm } from "./fpmCommands";
import { registerFpmTests } from "./fpmTests";

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
  const fortitude = new Fortitude(output);
  registerFormatting(context, output);
  registerRunCommands(context, output);
  registerFpm(context, output);
  registerFpmTests(context, output);
  context.subscriptions.push(
    output,
    linter,
    fortitude,
    vscode.commands.registerCommand("zfls.fortitude.fixAll", (uri?: vscode.Uri) => fortitude.fixAll(uri)),
    vscode.commands.registerCommand("zfls.restart", () => restartAll()),
    vscode.commands.registerCommand("zfls.showOutput", () => output?.show()),
    vscode.commands.registerCommand("zfls.showCompileOrder", () => showCompileOrder()),
    vscode.commands.registerCommand("zfls.toggleFixedFormComment", () => toggleFixedFormComment()),
    vscode.languages.registerDocumentSymbolProvider({ language: "FortranNamelist" }, { provideDocumentSymbols: namelistSymbols }),
    vscode.languages.registerDefinitionProvider(
      C_LANGUAGES.map((language) => ({ language })),
      { provideDefinition: fortranOfC },
    ),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (affectsServer(e)) {
        void restartAll();
      }
      if (e.affectsConfiguration("zfls.commentMarkers")) {
        void updateMarkerGrammar(true);
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
  void updateMarkerGrammar(false);
  // compiler diagnostics do not wait for the language server
  linter.activate();
  fortitude.activate();
  for (const doc of vscode.workspace.textDocuments) {
    await ensureClient(doc);
  }
  void checkModernFortran();
}

/** zfls's definitions of a position, and, when it is a BIND(C) procedure
 * (`zfls/bindC`), the declarations of its C name that the C language
 * server gives (VS Code's workspace symbols), each place once */
async function withCDeclarations(
  client: LanguageClient,
  document: vscode.TextDocument,
  position: vscode.Position,
  token: vscode.CancellationToken,
  result: vscode.Definition | vscode.LocationLink[] | null | undefined,
): Promise<vscode.Definition | vscode.LocationLink[] | null | undefined> {
  let bind: BindC | null;
  try {
    bind = await client.sendRequest<BindC | null>(
      "zfls/bindC",
      client.code2ProtocolConverter.asTextDocumentPositionParams(document, position),
      token,
    );
  } catch {
    return result;
  }
  if (!bind || token.isCancellationRequested) {
    return result;
  }
  const symbols =
    (await vscode.commands.executeCommand<vscode.SymbolInformation[] | undefined>(
      "vscode.executeWorkspaceSymbolProvider",
      bind.cName,
    )) ?? [];
  const cName = bind.cName;
  const found = symbols
    .filter((s) => s.name === cName && s.location?.uri && isCFile(s.location.uri.fsPath))
    .map((s) => s.location);
  if (found.length === 0) {
    return result;
  }
  const own: vscode.Location[] = (result === null || result === undefined ? [] : Array.isArray(result) ? result : [result]).map(
    (r) => ("targetUri" in r ? new vscode.Location(r.targetUri, r.targetSelectionRange ?? r.targetRange) : r),
  );
  return uniqueByPlace([...own, ...found], (l) => ({ uri: l.uri.toString(), line: l.range.start.line }));
}

/** Go to definition in a C or C++ file: the Fortran procedures that a
 * name is the C name of (`zfls/bindCTargets`), from every zfls running */
async function fortranOfC(
  document: vscode.TextDocument,
  position: vscode.Position,
  token: vscode.CancellationToken,
): Promise<vscode.Location[] | undefined> {
  const name = identifierAt(document.lineAt(position.line).text, position.character);
  if (!name) {
    return undefined;
  }
  const out: vscode.Location[] = [];
  for (const pending of clients.values()) {
    const client = await pending;
    if (!client?.isRunning() || token.isCancellationRequested) {
      continue;
    }
    try {
      const locations = await client.sendRequest<ProtocolLocation[] | null>("zfls/bindCTargets", { name }, token);
      for (const l of locations ?? []) {
        const location = client.protocol2CodeConverter.asLocation(l);
        if (location) {
          out.push(location);
        }
      }
    } catch {
      // an older zfls, or one stopping
    }
  }
  return out.length ? out : undefined;
}

/** Writes the grammar of zfls.commentMarkers (of the workspace, as grammars
 * are not per folder) when it differs from the one there, and offers to
 * reload the window, which reads grammars once. After an update of the
 * extension, which brings the empty grammar back, it is written again. */
async function updateMarkerGrammar(changed: boolean): Promise<void> {
  const markers = vscode.workspace.getConfiguration("zfls").get<string[]>("commentMarkers", []);
  const file = path.join(context.extensionPath, "syntaxes", INJECTION_FILE);
  const text = markerGrammarText(markers);
  try {
    // a checkout or package may have CRLF line ends: the same grammar
    if (isMarkerGrammar(fs.readFileSync(file, "utf8"), markers)) {
      return;
    }
    fs.writeFileSync(file, text, "utf8");
  } catch (err) {
    output?.warn(`could not write ${file} for zfls.commentMarkers: ${String(err)}`);
    if (changed) {
      void vscode.window.showWarningMessage(
        "zfls: the comment markers could not be highlighted (the extension's grammar is not writable); zfls still reads them as comments.",
      );
    }
    return;
  }
  const reload = "Reload Window";
  const choice = await vscode.window.showInformationMessage(
    "zfls: reload the window to highlight the comments of zfls.commentMarkers.",
    reload,
  );
  if (choice === reload) {
    await vscode.commands.executeCommand("workbench.action.reloadWindow");
  }
}

/** Toggle Line Comment in fixed form with `zfls.fixedFormCommentCharacter`
 * in column 1 (Modern Fortran #535); VS Code's own toggle for `!` */
async function toggleFixedFormComment(): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    return;
  }
  const doc = editor.document;
  const ch = vscode.workspace.getConfiguration("zfls", doc).get<string>("fixedFormCommentCharacter", "!");
  if (doc.languageId !== "FortranFixedForm" || ch === "!") {
    await vscode.commands.executeCommand("editor.action.commentLine");
    return;
  }
  const done = new Set<number>();
  await editor.edit((edit) => {
    for (const sel of editor.selections) {
      // a selection that ends at the start of a line leaves that line out
      const last = sel.end.line > sel.start.line && sel.end.character === 0 ? sel.end.line - 1 : sel.end.line;
      const lines: number[] = [];
      for (let ln = sel.start.line; ln <= last; ln++) {
        if (!done.has(ln)) {
          lines.push(ln);
          done.add(ln);
        }
      }
      const old = lines.map((ln) => doc.lineAt(ln).text);
      toggleComments(old, ch).forEach((text, i) => {
        if (text !== old[i]) {
          edit.replace(doc.lineAt(lines[i]).range, text);
        }
      });
    }
  });
}

/** The outline of a namelist file: its groups and the variables they set */
function namelistSymbols(doc: vscode.TextDocument): vscode.DocumentSymbol[] {
  const lines = Array.from({ length: doc.lineCount }, (_, i) => doc.lineAt(i).text);
  return namelistGroups(lines).map((g) => {
    const name = new vscode.Range(g.line, g.column, g.line, g.column + g.name.length);
    const group = new vscode.DocumentSymbol(
      g.name,
      "namelist group",
      vscode.SymbolKind.Namespace,
      new vscode.Range(g.line, 0, g.endLine, doc.lineAt(g.endLine).text.length),
      name,
    );
    group.children = g.variables.map((v) => {
      const range = new vscode.Range(v.line, v.column, v.line, v.column + v.name.length);
      return new vscode.DocumentSymbol(v.name, "", vscode.SymbolKind.Variable, range, range);
    });
    return group;
  });
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
/** The folder and root directory of the server that serves `doc` */
function serverRoot(doc: vscode.TextDocument): { folder?: vscode.WorkspaceFolder; root: vscode.Uri } | undefined {
  if (doc.uri.scheme === "file") {
    const inFolder = vscode.workspace.getWorkspaceFolder(doc.uri);
    const folder = inFolder ? outermost(inFolder) : undefined;
    return { folder, root: folder ? folder.uri : vscode.Uri.file(path.dirname(doc.uri.fsPath)) };
  }
  if (doc.uri.scheme === "untitled") {
    const folder = untitledFolder();
    return { folder, root: folder ? folder.uri : untitledRoot() };
  }
  return undefined;
}

async function ensureClient(doc: vscode.TextDocument): Promise<void> {
  if (!LANGUAGES.includes(doc.languageId)) {
    return;
  }
  const where = serverRoot(doc);
  if (!where) {
    return;
  }
  const { folder, root } = where;
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

interface CompileOrder {
  order: { name: string; kind: string; uri: string }[];
  cycles: string[][];
}

/** Opens the module compile order of the active document's server (each
 * module after those it uses), and the modules that use each other */
async function showCompileOrder(): Promise<void> {
  const doc = vscode.window.activeTextEditor?.document;
  let client: LanguageClient | undefined;
  if (doc && LANGUAGES.includes(doc.languageId)) {
    await ensureClient(doc);
    const where = serverRoot(doc);
    client = where ? await clients.get(where.root.toString()) : undefined;
  }
  client ??= await [...clients.values()][0];
  if (!client) {
    void vscode.window.showInformationMessage("zfls: open a Fortran file first.");
    return;
  }
  const res = await client.sendRequest<CompileOrder>("zfls/compileOrder", {});
  const lines = ["# Module compile order", ""];
  res.order.forEach((u, i) => {
    const file = vscode.workspace.asRelativePath(vscode.Uri.parse(u.uri));
    lines.push(`${i + 1}. \`${u.name}\` (${u.kind}) in ${file}`);
  });
  if (res.cycles.length > 0) {
    lines.push("", "## Modules that use each other", "");
    for (const c of res.cycles) {
      lines.push(`- ${c.map((n) => `\`${n}\``).join(", ")}`);
    }
  }
  const md = await vscode.workspace.openTextDocument({ language: "markdown", content: lines.join("\n") + "\n" });
  await vscode.window.showTextDocument(md, { preview: true });
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
    middleware: {
      // a BIND(C) procedure: its declarations from the C language server too
      provideDefinition: async (document, position, token, next) => {
        const result = await next(document, position, token);
        return withCDeclarations(client, document, position, token, result);
      },
    },
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
