// Runs or debugs the Fortran file in the editor (zfls.runFile,
// zfls.debugFile): zfls says how to build it (`zfls/buildCommand`, with the
// zfls.run.* settings), the build runs as a task, then the program runs in
// a terminal or a debug session starts with the debugger chosen.
// zfls.generateLaunchConfig writes the same as a tasks.json build task and
// a launch.json configuration.

import * as path from "node:path";
import * as vscode from "vscode";
import {
  BuildCommand,
  BuildCommandParams,
  CompilerInfo,
  DEBUGGER_EXTENSIONS,
  DebugType,
  chooseDebugger,
  launchConfiguration,
  upsertByKey,
  workspaceRelative,
} from "./run";
import { findLldbDap, gdbHasDap } from "./debugSupport";
import { expandVariables, findExecutable } from "./tools";
import { documentVariables } from "./variables";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];

/** Runs or debugs a file another way (fpm, for the programs of its
 * projects): true when it did, false to build the file by itself */
type FileRunner = (document: vscode.TextDocument, debug: boolean) => Promise<boolean>;

const fileRunners: FileRunner[] = [];

/** Lets `runner` run or debug a file before zfls.run's single-file build */
export function addFileRunner(runner: FileRunner): void {
  fileRunners.push(runner);
}

/** Sends `zfls/buildCommand` to the zfls of a file or folder: undefined
 * when none runs */
export type BuildCommandSender = (
  uri: vscode.Uri,
  params: BuildCommandParams,
) => Promise<BuildCommand | CompilerInfo | null | undefined>;

let sender: BuildCommandSender = async () => undefined;

export function registerRunCommands(context: vscode.ExtensionContext, log: vscode.LogOutputChannel, send: BuildCommandSender): void {
  sender = send;
  context.subscriptions.push(
    // a code lens above a program gives the URI as a string
    vscode.commands.registerCommand("zfls.runFile", (uri?: vscode.Uri | string) => runOrDebug(log, asUri(uri), false)),
    vscode.commands.registerCommand("zfls.debugFile", (uri?: vscode.Uri | string) => runOrDebug(log, asUri(uri), true)),
    vscode.commands.registerCommand("zfls.generateLaunchConfig", (uri?: vscode.Uri) => generateLaunchConfig(uri)),
  );
}

/** What zfls says about a compiler, for a program built otherwise (fpm,
 * launch.json): undefined when it is not found or no zfls runs */
export async function compilerInfo(scope: vscode.Uri, compiler: string, compilerPath = ""): Promise<CompilerInfo | undefined> {
  return (await sender(scope, { compiler, compilerPath })) ?? undefined;
}

function asUri(uri: vscode.Uri | string | undefined): vscode.Uri | undefined {
  return typeof uri === "string" ? vscode.Uri.parse(uri) : uri;
}

/** Everything about building and running one file: zfls's answer, and the
 * settings of running it */
interface Plan {
  document: vscode.TextDocument;
  folder: vscode.WorkspaceFolder | undefined;
  source: string;
  build: BuildCommand;
  programArgs: string[];
  cwd: string;
  msvc: boolean;
  debuggerPreference: string;
  gdbPath?: string;
  /** zfls's debugger runs lldb-dap (`lldbWanted`) */
  lldb: boolean;
}

async function runOrDebug(log: vscode.LogOutputChannel, uri: vscode.Uri | undefined, debug: boolean): Promise<void> {
  const document = await fortranDocument(uri);
  if (!document) {
    return;
  }
  for (const runner of fileRunners) {
    if (await runner(document, debug)) {
      return;
    }
  }
  const plan = await makePlan(document, log);
  if (!plan) {
    return;
  }
  // choose the debugger first: no point building for a debugger that is not there
  let debugType: DebugType | undefined;
  if (debug) {
    debugType = await pickDebugger(plan);
    if (!debugType) {
      return;
    }
  }
  const { build } = plan;
  log.info(`[run] ${build.compiler} ${build.args.join(" ")} (in ${build.cwd})`);
  const built = await runTask(
    new vscode.Task(
      { type: "zfls", task: "build" },
      plan.folder ?? vscode.TaskScope.Workspace,
      `build ${path.basename(plan.source)}`,
      "zfls",
      new vscode.ProcessExecution(build.compiler, build.args, { cwd: build.cwd, env: build.env }),
      [],
    ),
  );
  if (built !== 0) {
    if (typeof built !== "number") {
      const why = built ? `: ${String(built.error)}` : "";
      void vscode.window.showErrorMessage(
        plan.folder
          ? vscode.l10n.t("zfls: could not run the build task{0}.", why)
          : vscode.l10n.t("zfls: could not run the build task{0}; tasks may need a folder to be open: open the file's folder.", why),
      );
    } else {
      void vscode.window.showErrorMessage(
        vscode.l10n.t("zfls: building {0} failed (exit code {1}); see the terminal.", path.basename(plan.source), built),
      );
    }
    return;
  }
  if (!debug) {
    log.info(`[run] ${build.program} ${plan.programArgs.join(" ")} (in ${plan.cwd})`);
    const run = new vscode.Task(
      { type: "zfls", task: "run" },
      plan.folder ?? vscode.TaskScope.Workspace,
      `run ${path.basename(plan.source)}`,
      "zfls",
      new vscode.ProcessExecution(build.program, plan.programArgs, { cwd: plan.cwd, env: { ...build.runEnv } }),
      [],
    );
    run.presentationOptions = { reveal: vscode.TaskRevealKind.Always, focus: true, clear: true };
    await vscode.tasks.executeTask(run);
    return;
  }
  const config = launchConfiguration({
    name: `Debug ${path.basename(plan.source)}`,
    type: debugType!,
    program: build.program,
    args: plan.programArgs,
    cwd: plan.cwd,
    env: build.runEnv,
    platform: process.platform,
    gdbPath: plan.gdbPath,
    lldb: plan.lldb,
    msvc: plan.msvc,
    sourceRoot: plan.folder?.uri.fsPath ?? path.dirname(plan.source),
  }) as vscode.DebugConfiguration;
  log.info(`[run] debugging with ${JSON.stringify(config)}`);
  const started = await vscode.debug.startDebugging(plan.folder, config);
  if (!started) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: the {0} debugger did not start; see the Debug Console.", debugType!));
  }
}

/** The Fortran document to run: the one given (from the editor title
 * button) or the active one, saved. */
async function fortranDocument(uri: vscode.Uri | undefined): Promise<vscode.TextDocument | undefined> {
  const document = uri
    ? await vscode.workspace.openTextDocument(uri)
    : vscode.window.activeTextEditor?.document;
  if (!document || !LANGUAGES.includes(document.languageId)) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: open a Fortran file to run or debug it."));
    return undefined;
  }
  if (document.isUntitled || document.uri.scheme !== "file") {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: save the file first; only files on disk can be built."));
    return undefined;
  }
  if (document.isDirty && !(await document.save())) {
    return undefined;
  }
  return document;
}

/** The plan of running `document`: zfls's answer for the zfls.run
 * settings, or undefined after saying why there is none. `env`: values in
 * place of the environment's, for the answer's additions. */
async function makePlan(
  document: vscode.TextDocument,
  log?: vscode.LogOutputChannel,
  env?: Record<string, string>,
): Promise<Plan | undefined> {
  const config = vscode.workspace.getConfiguration("zfls.run", document.uri);
  const ctx = documentVariables(document.uri);
  const source = document.uri.fsPath;
  const base = ctx.workspaceFolder ?? path.dirname(source);
  const compilerName = config.get<string>("compiler", "gfortran").trim() || "gfortran";
  const configuredPath = expandVariables(config.get<string>("compilerPath", "").trim(), ctx);
  const configuredArgs = config.get<string[] | null>("buildArgs", null);
  const configuredOut = expandVariables(config.get<string>("outputDirectory", "").trim(), ctx);
  const answer = await sender(document.uri, {
    textDocument: { uri: document.uri.toString() },
    compiler: compilerName,
    // a path relative to the file's workspace folder; a bare name, on the PATH
    compilerPath: /[\\/]/.test(configuredPath) ? path.resolve(base, configuredPath) : configuredPath,
    ...(configuredArgs ? { args: configuredArgs.map((a) => expandVariables(a, ctx)) } : {}),
    ...(configuredOut ? { outputDirectory: path.resolve(base, configuredOut) } : {}),
    ...(env ? { env } : {}),
  });
  if (answer === undefined) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: the zfls language server is not running; Run Fortran File needs it to build {0}.", path.basename(source)));
    return undefined;
  }
  if (answer === null || !("program" in answer)) {
    void vscode.window
      .showErrorMessage(
        configuredPath
          ? vscode.l10n.t(
              "zfls: the compiler {0} was not found in {1} (zfls.run.compilerPath). Install it, or set zfls.run.compiler and zfls.run.compilerPath.",
              compilerName,
              configuredPath,
            )
          : vscode.l10n.t(
              "zfls: the compiler {0} was not found on the PATH. Install it, or set zfls.run.compiler and zfls.run.compilerPath.",
              compilerName,
            ),
        vscode.l10n.t("Open Settings"),
      )
      .then((choice) => {
        if (choice) {
          void vscode.commands.executeCommand("workbench.action.openSettings", "zfls.run");
        }
      });
    return undefined;
  }
  if (answer.note) {
    log?.info(`[run] ${answer.note}`);
  }
  const cwdSetting = expandVariables(config.get<string>("cwd", "${fileDirname}").trim() || "${fileDirname}", ctx);
  return {
    document,
    folder: vscode.workspace.getWorkspaceFolder(document.uri),
    source,
    build: answer,
    programArgs: config.get<string[]>("programArgs", []).map((a) => expandVariables(a, ctx)),
    cwd: path.resolve(path.dirname(source), cwdSetting),
    msvc: answer.debugInfo === "pdb",
    debuggerPreference: config.get<string>("debugger", "auto"),
    gdbPath: gdbFor(document.uri, answer.compiler),
    lldb: lldbWanted(document.uri),
  };
}

/** The debugger to use, or undefined (with a message) when none is installed */
async function pickDebugger(plan: Plan): Promise<DebugType | undefined> {
  return chooseInstalledDebugger(plan.debuggerPreference, plan.msvc, plan.gdbPath, plan.lldb);
}

/** The debugger of `preference` (zfls.run.debugger) for a program, MSVC-ABI
 * or not, or undefined (with a message) when none is installed; `gdb`: the
 * gdb that zfls's debugger would run, unless it runs lldb-dap (`lldb`:
 * true, or the lldb-dap configured) */
export async function chooseInstalledDebugger(
  preference: string,
  msvc: boolean,
  gdb: string | undefined,
  lldb: boolean | string = false,
): Promise<DebugType | undefined> {
  const own = !msvc && (preference === "auto" || preference === "zfls");
  const dap = own && lldb
    ? (await findLldbDap(typeof lldb === "string" ? lldb : undefined)) !== undefined
    : own && gdb ? await gdbHasDap(gdb) : false;
  // MSVC-ABI programs: Windows's Debugger Engine, which every Windows has
  const dbgeng = msvc && process.platform === "win32";
  const choice = chooseDebugger(
    preference,
    (id) => vscode.extensions.getExtension(id) !== undefined,
    msvc,
    dap,
    dbgeng,
  );
  if ("type" in choice) {
    return choice.type;
  }
  if (choice.missing === "zfls") {
    const settings = vscode.l10n.t("Open Settings");
    const picked = await vscode.window.showErrorMessage(
      msvc
        ? vscode.l10n.t("zfls: its debugger runs gdb, which cannot debug a program without DWARF debug information (ifx's, ifort's, or LLVM Flang's built with -g on Windows); set zfls.run.debugger to cppvsdbg.")
        : lldb
          ? vscode.l10n.t("zfls: its debugger needs lldb-dap, which Xcode's command line tools have (xcode-select --install); or set zfls.run.gdbPath to debug with gdb, or zfls.run.debugger to another debugger.")
          : vscode.l10n.t("zfls: its debugger needs gdb 14 or later, built with Python ({0}); set zfls.run.gdbPath, or zfls.run.debugger to another debugger.", gdb ?? "gdb"),
      settings,
    );
    if (picked === settings) {
      await vscode.commands.executeCommand("workbench.action.openSettings", "zfls.run");
    }
    return undefined;
  }
  const names = choice.extensions.map((id) => {
    const ext = Object.values(DEBUGGER_EXTENSIONS).find((e) => e.id === id);
    return `${ext?.name ?? id} (${id})`;
  });
  const install = vscode.l10n.t("Show Extension");
  const list = names.join(", ");
  const picked = await vscode.window.showErrorMessage(
    choice.missing === "any"
      ? vscode.l10n.t("zfls: debugging needs a debugger. Install one of: {0}.", list)
      : choice.missing === "msvc"
        ? vscode.l10n.t("zfls: debugging needs a debugger for MSVC-ABI programs. Install one of: {0}.", list)
        : vscode.l10n.t("zfls: debugging needs the {0} debugger. Install one of: {1}.", choice.missing, list),
    install,
  );
  if (picked === install) {
    await vscode.commands.executeCommand("workbench.extensions.search", choice.extensions.map((id) => `@id:${id}`).join(" "));
  }
  return undefined;
}

/** Whether zfls's debugger runs lldb-dap rather than gdb: on macOS, where
 * gdb does not run on Apple silicon and must be code-signed on Intel,
 * unless zfls.run.gdbPath names a gdb */
export function lldbWanted(uri: vscode.Uri): boolean {
  return process.platform === "darwin" && !vscode.workspace.getConfiguration("zfls.run", uri).get<string>("gdbPath", "").trim();
}

/** The gdb of zfls.run.gdbPath, else the one next to `compiler`, else on
 * the PATH */
export function gdbFor(uri: vscode.Uri, compiler: string | undefined): string | undefined {
  const ctx = documentVariables(uri);
  const gdbSetting = expandVariables(
    vscode.workspace.getConfiguration("zfls.run", uri).get<string>("gdbPath", "").trim(),
    ctx,
  );
  if (gdbSetting) {
    return findExecutable("gdb", gdbSetting, ctx.workspaceFolder) ?? gdbSetting;
  }
  return (compiler ? findExecutable("gdb", path.dirname(compiler), undefined) : undefined) ?? findExecutable("gdb");
}

/** Runs a task to its end: its exit code, undefined when there is none, or
 * the error when it did not start */
export async function runTask(task: vscode.Task): Promise<number | undefined | { error: unknown }> {
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, clear: true, showReuseMessage: false };
  return new Promise((resolve) => {
    let execution: vscode.TaskExecution | undefined;
    // a process can end before executeTask resolves
    const ends: vscode.TaskProcessEndEvent[] = [];
    const settle = (): void => {
      const end = ends.find((e) => e.execution === execution);
      if (execution && end) {
        ended.dispose();
        resolve(end.exitCode);
      }
    };
    const ended = vscode.tasks.onDidEndTaskProcess((e) => {
      ends.push(e);
      settle();
    });
    vscode.tasks.executeTask(task).then(
      (started) => {
        execution = started;
        settle();
      },
      (error: unknown) => {
        ended.dispose();
        resolve({ error });
      },
    );
  });
}

async function generateLaunchConfig(uri: vscode.Uri | undefined): Promise<void> {
  const document = await fortranDocument(uri);
  if (!document) {
    return;
  }
  const folder = vscode.workspace.getWorkspaceFolder(document.uri);
  if (!folder) {
    void vscode.window.showErrorMessage(
      vscode.l10n.t("zfls: launch.json and tasks.json belong to a workspace folder; open the folder of this file first."),
    );
    return;
  }
  // the environment of the machine running the task, not this one's
  const pathKey = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") ?? "Path";
  const plan = await makePlan(document, undefined, { [pathKey]: `\${env:${pathKey}}`, LIB: "${env:LIB}", LINK: "${env:LINK}" });
  if (!plan) {
    return;
  }
  const debugType = await pickDebugger(plan);
  if (!debugType) {
    return;
  }
  const { build } = plan;
  const root = folder.uri.fsPath;
  const rel = (p: string): string => workspaceRelative(p, root);
  const base = path.basename(plan.source);
  const label = `zfls: build ${base}`;
  const compilerName = vscode.workspace.getConfiguration("zfls.run", document.uri).get<string>("compiler", "gfortran");
  // the compiler as configured when it is on the PATH, so the task works on
  // other machines too
  const command = findExecutable(compilerName, "", undefined) === build.compiler ? compilerName : build.compiler;
  const task: Record<string, unknown> = {
    label,
    type: "process",
    command,
    args: build.args.map((a) => replaceAll(a, [plan.source, build.program, path.dirname(plan.source)], rel)),
    options: { cwd: rel(build.cwd), ...(Object.keys(build.env).length > 0 ? { env: build.env } : {}) },
    group: "build",
    problemMatcher: [],
  };
  const launch = launchConfiguration({
    name: `Debug ${base}`,
    type: debugType,
    program: rel(build.program),
    args: plan.programArgs,
    cwd: rel(plan.cwd),
    env: build.runEnv,
    platform: process.platform,
    gdbPath: plan.gdbPath,
    lldb: plan.lldb,
    preLaunchTask: label,
  });

  const tasksConfig = vscode.workspace.getConfiguration("tasks", folder.uri);
  const tasks = (tasksConfig.inspect<Record<string, unknown>[]>("tasks")?.workspaceFolderValue ?? []);
  if (!tasksConfig.inspect<string>("version")?.workspaceFolderValue) {
    await tasksConfig.update("version", "2.0.0", vscode.ConfigurationTarget.WorkspaceFolder);
  }
  await tasksConfig.update("tasks", upsertByKey(tasks, task, "label"), vscode.ConfigurationTarget.WorkspaceFolder);
  const launchConfig = vscode.workspace.getConfiguration("launch", folder.uri);
  const configs = launchConfig.inspect<Record<string, unknown>[]>("configurations")?.workspaceFolderValue ?? [];
  if (!launchConfig.inspect<string>("version")?.workspaceFolderValue) {
    await launchConfig.update("version", "0.2.0", vscode.ConfigurationTarget.WorkspaceFolder);
  }
  await launchConfig.update(
    "configurations",
    upsertByKey(configs, launch, "name"),
    vscode.ConfigurationTarget.WorkspaceFolder,
  );
  const open = vscode.l10n.t("Open launch.json");
  const choice = await vscode.window.showInformationMessage(
    vscode.l10n.t(
      'zfls: added the build task "{0}" to tasks.json and the configuration "Debug {1}" to launch.json.',
      label,
      base,
    ),
    open,
  );
  if (choice === open) {
    await vscode.window.showTextDocument(vscode.Uri.joinPath(folder.uri, ".vscode", "launch.json"));
  }
}

/** `arg` with a leading or embedded path from `paths` made workspace-relative */
function replaceAll(arg: string, paths: string[], rel: (p: string) => string): string {
  for (const p of paths) {
    const i = arg.indexOf(p);
    if (i >= 0) {
      return arg.slice(0, i) + rel(p) + arg.slice(i + p.length);
    }
  }
  return arg;
}
