// Runs or debugs the Fortran file in the editor (zfls.runFile,
// zfls.debugFile): builds it with a compiler (zfls.run.*) into the
// extension's storage, then runs it in a terminal or starts a debug session
// with the installed debugger extension. zfls.generateLaunchConfig writes
// the same as a tasks.json build task and a launch.json configuration.

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  DEBUGGER_EXTENSIONS,
  DebugType,
  buildArgs,
  chooseDebugger,
  compilerKind,
  launchConfiguration,
  outputDirFor,
  programPath,
  runtimeEnv,
  upsertByKey,
  workspaceRelative,
} from "./run";
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

export function registerRunCommands(context: vscode.ExtensionContext, log: vscode.LogOutputChannel): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("zfls.runFile", (uri?: vscode.Uri) => runOrDebug(context, log, uri, false)),
    vscode.commands.registerCommand("zfls.debugFile", (uri?: vscode.Uri) => runOrDebug(context, log, uri, true)),
    vscode.commands.registerCommand("zfls.generateLaunchConfig", (uri?: vscode.Uri) =>
      generateLaunchConfig(context, uri),
    ),
  );
}

/** Everything about building and running one file */
interface Plan {
  document: vscode.TextDocument;
  folder: vscode.WorkspaceFolder | undefined;
  source: string;
  compiler: string;
  args: string[];
  /** Where the compiler runs and module files go */
  outDir: string;
  program: string;
  programArgs: string[];
  cwd: string;
  env: Record<string, string>;
  msvc: boolean;
  debuggerPreference: string;
  gdbPath?: string;
}

async function runOrDebug(
  context: vscode.ExtensionContext,
  log: vscode.LogOutputChannel,
  uri: vscode.Uri | undefined,
  debug: boolean,
): Promise<void> {
  const document = await fortranDocument(uri);
  if (!document) {
    return;
  }
  for (const runner of fileRunners) {
    if (await runner(document, debug)) {
      return;
    }
  }
  const plan = makePlan(context, document);
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
  fs.mkdirSync(plan.outDir, { recursive: true });
  log.info(`[run] ${plan.compiler} ${plan.args.join(" ")} (in ${plan.outDir})`);
  const built = await runTask(
    new vscode.Task(
      { type: "zfls", task: "build" },
      plan.folder ?? vscode.TaskScope.Workspace,
      `build ${path.basename(plan.source)}`,
      "zfls",
      new vscode.ProcessExecution(plan.compiler, plan.args, { cwd: plan.outDir }),
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
    log.info(`[run] ${plan.program} ${plan.programArgs.join(" ")} (in ${plan.cwd})`);
    const env = { ...plan.env };
    const run = new vscode.Task(
      { type: "zfls", task: "run" },
      plan.folder ?? vscode.TaskScope.Workspace,
      `run ${path.basename(plan.source)}`,
      "zfls",
      new vscode.ProcessExecution(plan.program, plan.programArgs, { cwd: plan.cwd, env }),
      [],
    );
    run.presentationOptions = { reveal: vscode.TaskRevealKind.Always, focus: true, clear: true };
    await vscode.tasks.executeTask(run);
    return;
  }
  const config = launchConfiguration({
    name: `Debug ${path.basename(plan.source)}`,
    type: debugType!,
    program: plan.program,
    args: plan.programArgs,
    cwd: plan.cwd,
    env: plan.env,
    platform: process.platform,
    gdbPath: plan.gdbPath,
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

function makePlan(context: vscode.ExtensionContext, document: vscode.TextDocument): Plan | undefined {
  const config = vscode.workspace.getConfiguration("zfls.run", document.uri);
  const ctx = documentVariables(document.uri);
  const source = document.uri.fsPath;
  const compilerName = config.get<string>("compiler", "gfortran").trim() || "gfortran";
  const configuredPath = expandVariables(config.get<string>("compilerPath", "").trim(), ctx);
  const compiler = findExecutable(compilerName, configuredPath, ctx.workspaceFolder);
  if (!compiler) {
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
  const kind = compilerKind(compiler, process.platform);
  const userArgs = config.get<string[] | null>("buildArgs", null);
  const configuredOut = expandVariables(config.get<string>("outputDirectory", "").trim(), ctx);
  const outDir = configuredOut
    ? path.resolve(ctx.workspaceFolder ?? path.dirname(source), configuredOut)
    : outputDirFor(path.join(context.globalStorageUri.fsPath, "run"), source);
  const program = programPath(outDir, source);
  const cwdSetting = expandVariables(config.get<string>("cwd", "${fileDirname}").trim() || "${fileDirname}", ctx);
  const gdbPath = gdbFor(document.uri, compiler);
  return {
    document,
    folder: vscode.workspace.getWorkspaceFolder(document.uri),
    source,
    compiler,
    args: buildArgs(kind, source, program, userArgs ? userArgs.map((a) => expandVariables(a, ctx)) : undefined),
    outDir,
    program,
    programArgs: config.get<string[]>("programArgs", []).map((a) => expandVariables(a, ctx)),
    cwd: path.resolve(path.dirname(source), cwdSetting),
    env: runtimeEnv(compiler, process.platform, process.env),
    msvc: kind.msvc,
    debuggerPreference: config.get<string>("debugger", "auto"),
    gdbPath,
  };
}

/** The debugger to use, or undefined (with a message) when none is installed */
async function pickDebugger(plan: Plan): Promise<DebugType | undefined> {
  return chooseInstalledDebugger(plan.debuggerPreference, plan.msvc);
}

/** The debugger of `preference` (zfls.run.debugger) for a program, MSVC-ABI
 * or not, or undefined (with a message) when none is installed */
export async function chooseInstalledDebugger(preference: string, msvc: boolean): Promise<DebugType | undefined> {
  const choice = chooseDebugger(
    preference,
    (id) => vscode.extensions.getExtension(id) !== undefined,
    msvc,
  );
  if ("type" in choice) {
    return choice.type;
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

/** The gdb of zfls.run.gdbPath, else the one next to `compiler`, else on
 * the PATH */
export function gdbFor(uri: vscode.Uri, compiler: string | undefined): string | undefined {
  const ctx = documentVariables(uri);
  const gdbSetting = expandVariables(
    vscode.workspace.getConfiguration("zfls.run", uri).get<string>("gdbPath", "").trim(),
    ctx,
  );
  return (
    findExecutable("gdb", gdbSetting, ctx.workspaceFolder) ??
    (compiler ? findExecutable("gdb", path.dirname(compiler), undefined) : undefined) ??
    (gdbSetting || undefined)
  );
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

async function generateLaunchConfig(context: vscode.ExtensionContext, uri: vscode.Uri | undefined): Promise<void> {
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
  const plan = makePlan(context, document);
  if (!plan) {
    return;
  }
  const debugType = await pickDebugger(plan);
  if (!debugType) {
    return;
  }
  fs.mkdirSync(plan.outDir, { recursive: true });
  const root = folder.uri.fsPath;
  const rel = (p: string): string => workspaceRelative(p, root);
  const base = path.basename(plan.source);
  const label = `zfls: build ${base}`;
  const compilerName = vscode.workspace.getConfiguration("zfls.run", document.uri).get<string>("compiler", "gfortran");
  // the compiler as configured when it is on the PATH, so the task works on
  // other machines too
  const command = findExecutable(compilerName, "", undefined) === plan.compiler ? compilerName : plan.compiler;
  const task: Record<string, unknown> = {
    label,
    type: "process",
    command,
    args: plan.args.map((a) => replaceAll(a, [plan.source, plan.program, path.dirname(plan.source)], rel)),
    options: { cwd: rel(plan.outDir) },
    group: "build",
    problemMatcher: [],
  };
  const launch = launchConfiguration({
    name: `Debug ${base}`,
    type: debugType,
    program: rel(plan.program),
    args: plan.programArgs,
    cwd: rel(plan.cwd),
    // the PATH of the machine running it, not this one's
    env: Object.fromEntries(
      Object.keys(plan.env).map((key) => [key, `${path.dirname(plan.compiler)};\${env:${key}}`]),
    ),
    platform: process.platform,
    gdbPath: plan.gdbPath,
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
