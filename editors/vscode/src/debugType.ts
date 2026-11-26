// The `fortran` debug type: a launch configuration that the extension
// resolves into zfls's own debugger (`zfls dap`, which runs gdb when there
// is a gdb of the Debug Adapter Protocol, lldb-dap on macOS, or Windows's
// Debugger Engine for MSVC-ABI programs) or one of the debugger extensions installed (C/C++,
// CodeLLDB, CDT GDB), as Debug Fortran File chooses: the program, or an fpm
// target that it builds first, with its arguments, directory and
// environment, and the compiler's runtime libraries on the PATH on
// Windows. launch.json keeps saying `fortran` whichever debugger runs it.
// F5 without a launch.json debugs the file in the editor; the Run and
// Debug view offers a configuration per fpm target. An `attach`
// configuration attaches zfls's debugger to a running program.

import { execFile } from "node:child_process";
import * as path from "node:path";
import * as vscode from "vscode";
import { TargetKind } from "./fpm";
import { FpmProject, buildTarget, debugBuild, findProjects, fpmExecutable, listTargets, projectOf } from "./fpmCommands";
import { initialConfiguration } from "./debugConfigs";
import { attachGdb, findLldbDap, gdbHasDap, hoverExpressionStart } from "./debugSupport";
import { CompilerInfo, adapterArgs, fortranLaunch, parseProcesses } from "./run";
import { chooseInstalledDebugger, compilerInfo, gdbFor, lldbWanted } from "./runFile";
import { expandVariables, programPath } from "./tools";
import { folderVariables } from "./variables";

export const DEBUG_TYPE = "fortran";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];

export function registerDebugType(
  context: vscode.ExtensionContext,
  log: vscode.LogOutputChannel,
  zfls: () => string | undefined,
): void {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory(DEBUG_TYPE, {
      // zfls dap: the configuration's debugger, else its own choice by the
      // program's debug information (Windows's Debugger Engine for a PDB)
      // and the platform (lldb-dap on macOS, gdb elsewhere); the words it
      // shows, in VS Code's language
      createDebugAdapterDescriptor: (session) => {
        const exe = zfls();
        if (!exe) {
          throw new Error(vscode.l10n.t("zfls: no zfls executable found. Set zfls.path, or put zfls on the PATH."));
        }
        const config = session.configuration;
        const debuggerArgs = adapterArgs(config);
        log.info(`[debug] ${exe} dap ${debuggerArgs.join(" ")}`);
        return new vscode.DebugAdapterExecutable(exe, ["dap", ...debuggerArgs, "--text", JSON.stringify(adapterText())]);
      },
    }),
    vscode.languages.registerEvaluatableExpressionProvider(
      LANGUAGES.map((language) => ({ language })),
      { provideEvaluatableExpression: evaluatableExpression },
    ),
    vscode.commands.registerCommand("zfls.pickProcess", () => pickProcess()),
    vscode.debug.registerDebugConfigurationProvider(DEBUG_TYPE, {
      resolveDebugConfigurationWithSubstitutedVariables: (folder, config) => resolve(folder, config, log),
      provideDebugConfigurations: () => [initialConfiguration()],
    }),
    vscode.debug.registerDebugConfigurationProvider(
      DEBUG_TYPE,
      { provideDebugConfigurations: () => fpmConfigurations() },
      vscode.DebugConfigurationProviderTriggerKind.Dynamic,
    ),
  );
}

/** A configuration per executable, example and test of each fpm project,
 * for the Run and Debug view's list */
async function fpmConfigurations(): Promise<vscode.DebugConfiguration[]> {
  const out: vscode.DebugConfiguration[] = [];
  const projects = await findProjects();
  for (const project of projects) {
    const fpm = fpmExecutable(project, true);
    if (!fpm) {
      continue;
    }
    const where = projects.length > 1 ? ` (${project.name})` : "";
    for (const kind of ["executable", "example", "test"] as TargetKind[]) {
      for (const name of await listTargets(project, kind, fpm)) {
        out.push({
          type: DEBUG_TYPE,
          request: "launch",
          name: `fpm ${kind === "executable" ? "" : kind + " "}${name}${where}`,
          fpmTarget: name,
          fpmTargetKind: kind,
          ...(project.folder && project.root !== project.folder.uri.fsPath
            ? { cwd: project.root }
            : {}),
        });
      }
    }
  }
  return out;
}

async function resolve(
  folder: vscode.WorkspaceFolder | undefined,
  config: vscode.DebugConfiguration,
  log: vscode.LogOutputChannel,
): Promise<vscode.DebugConfiguration | undefined | null> {
  // F5 without a launch.json: the file in the editor, as Debug Fortran File
  if (!config.type && !config.request && !config.name) {
    await vscode.commands.executeCommand("zfls.debugFile");
    return undefined;
  }
  const scope = folder?.uri;
  const run = vscode.workspace.getConfiguration("zfls.run", scope);
  if (config.request === "attach") {
    return attach(folder, config, log);
  }
  let program: string | undefined;
  let cwd: string | undefined = typeof config.cwd === "string" && config.cwd ? config.cwd : undefined;
  const configuredCompiler = typeof config.compiler === "string" && config.compiler ? config.compiler : undefined;
  // `"dbgeng": true` says the program has Microsoft's debug information
  const dbgeng = process.platform === "win32" && config.dbgeng === true;
  if (typeof config.fpmTarget === "string" && config.fpmTarget) {
    const project = await fpmProjectFor(folder, cwd);
    if (!project) {
      void vscode.window.showErrorMessage(vscode.l10n.t("zfls: no fpm.toml for the fpm target {0}.", config.fpmTarget));
      return undefined;
    }
    const build = await debugBuild(project);
    const compiler = configuredCompiler ? await compilerInfo(vscode.Uri.file(project.root), configuredCompiler) : build.compiler;
    const kind: TargetKind = ["executable", "example", "test"].includes(config.fpmTargetKind) ? config.fpmTargetKind : "executable";
    cwd ??= project.root;
    const msvc = (configuredCompiler ? compiler?.debugInfo === "pdb" : build.msvc) || dbgeng;
    const debugType = await pick(run, config, msvc, gdbFor(scope ?? vscode.Uri.file(cwd), compiler?.compiler), usesLldb(config, scope));
    if (!debugType) {
      return undefined;
    }
    program = await buildTarget(project, { kind, name: config.fpmTarget }, build.options, log);
    if (!program) {
      return undefined;
    }
    return finish(config, debugType, program, cwd, compiler, scope, log, msvc);
  }
  if (typeof config.program !== "string" || !config.program) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: a fortran launch configuration needs a program or an fpmTarget."));
    return undefined;
  }
  program = path.resolve(folder?.uri.fsPath ?? "", config.program);
  const configuredPath = expandVariables(run.get<string>("compilerPath", "").trim(), folderVariables(folder));
  const compiler = await compilerInfo(
    scope ?? vscode.Uri.file(path.dirname(program)),
    configuredCompiler ?? run.get<string>("compiler", "gfortran"),
    /[\\/]/.test(configuredPath) ? path.resolve(folder?.uri.fsPath ?? "", configuredPath) : configuredPath,
  );
  cwd ??= path.dirname(program);
  const msvc = compiler?.debugInfo === "pdb" || dbgeng;
  const debugType = await pick(run, config, msvc, gdbFor(scope ?? vscode.Uri.file(cwd), compiler?.compiler), usesLldb(config, scope));
  if (!debugType) {
    return undefined;
  }
  return finish(config, debugType, program, cwd, compiler, scope, log, msvc);
}

/** An attach configuration: zfls's debugger, attached to a process
 * (`processId`) or a gdbserver (`target`) */
async function attach(
  folder: vscode.WorkspaceFolder | undefined,
  config: vscode.DebugConfiguration,
  log: vscode.LogOutputChannel,
): Promise<vscode.DebugConfiguration | undefined> {
  const lldb = usesLldb(config, folder?.uri);
  if (lldb) {
    if (!(await findLldbDap(typeof lldb === "string" ? lldb : undefined))) {
      void vscode.window.showErrorMessage(
        vscode.l10n.t("zfls: its debugger needs lldb-dap, which Xcode's command line tools have (xcode-select --install); or set zfls.run.gdbPath to debug with gdb, or zfls.run.debugger to another debugger."),
      );
      return undefined;
    }
    if (!config.processId) {
      void vscode.window.showErrorMessage(vscode.l10n.t("zfls: a fortran attach configuration with lldb-dap needs a processId."));
      return undefined;
    }
    const resolved = {
      ...config,
      type: DEBUG_TYPE,
      lldb,
      ...(typeof config.program === "string" && config.program ? { program: path.resolve(folder?.uri.fsPath ?? "", config.program) } : {}),
    };
    log.info(`[debug] ${config.name}: ${JSON.stringify(resolved)}`);
    return resolved;
  }
  const gdb = attachGdb(config.gdb, () => gdbFor(folder?.uri ?? vscode.Uri.file(process.cwd()), undefined));
  if (!gdb || !(await gdbHasDap(gdb))) {
    void vscode.window.showErrorMessage(
      vscode.l10n.t("zfls: attaching needs zfls's debugger, which needs gdb 14 or later, built with Python ({0}); set zfls.run.gdbPath.", gdb ?? "gdb"),
    );
    return undefined;
  }
  if (!config.processId && !config.target) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: a fortran attach configuration needs a processId or a target."));
    return undefined;
  }
  const resolved = {
    ...config,
    type: DEBUG_TYPE,
    gdb,
    // the sources zfls dap indexes, for the module variables
    ...(typeof config.sourceRoot !== "string" && folder ? { sourceRoot: folder.uri.fsPath } : {}),
    ...(typeof config.program === "string" && config.program ? { program: path.resolve(folder?.uri.fsPath ?? "", config.program) } : {}),
  };
  log.info(`[debug] ${config.name}: ${JSON.stringify(resolved)}`);
  return resolved;
}

/** Whether a configuration's zfls debugger runs lldb-dap: its `lldb`, else
 * on macOS without its `gdb` as `lldbWanted` says */
function usesLldb(config: vscode.DebugConfiguration, scope: vscode.Uri | undefined): boolean | string {
  if (config.lldb === true || (typeof config.lldb === "string" && config.lldb)) {
    return config.lldb;
  }
  if (config.lldb === false || (typeof config.gdb === "string" && config.gdb)) {
    return false;
  }
  return lldbWanted(scope ?? vscode.Uri.file(process.cwd()));
}

/** The words zfls dap shows, translated (`zfls dap --text`) */
function adapterText(): Record<string, string> {
  return {
    moduleVariables: vscode.l10n.t("Module variables"),
    notAllocated: vscode.l10n.t("not allocated"),
    notAssociated: vscode.l10n.t("not associated"),
    notAvailable: vscode.l10n.t("not available"),
    runtimeErrors: vscode.l10n.t("Fortran runtime errors"),
    runtimeErrorsDescription: vscode.l10n.t(
      "Stop where the Fortran runtime reports an error (bounds checking, allocation, I/O) or ERROR STOP",
    ),
    runtimeError: vscode.l10n.t("Fortran runtime error"),
    errorStop: "ERROR STOP",
    gdbExited: vscode.l10n.t("gdb exited"),
    lldbExited: vscode.l10n.t("lldb-dap exited"),
    endedBySignal: vscode.l10n.t("The program was ended by a signal"),
    engineNoConditions: vscode.l10n.t("Windows's Debugger Engine takes no conditions, hit conditions or log messages yet"),
  };
}

/** The expression under the mouse, while debugging with gdb (which reads
 * Fortran; to lldb and the Visual Studio debugger `p%x` is a remainder): a
 * name with the parents of its component (`p%x`, `a(i)%x`). zfls's debugger
 * with lldb-dap gets VS Code's own. */
function evaluatableExpression(document: vscode.TextDocument, position: vscode.Position): vscode.EvaluatableExpression | undefined {
  const session = vscode.debug.activeDebugSession;
  const gdb =
    (session?.type === DEBUG_TYPE && !usesLldb(session.configuration, session.workspaceFolder?.uri)) ||
    session?.type === "gdb" ||
    (session?.type === "cppdbg" && session.configuration.MIMode !== "lldb");
  if (!gdb) {
    return undefined;
  }
  const word = document.getWordRangeAtPosition(position, /[A-Za-z_]\w*/);
  if (!word) {
    return undefined;
  }
  const line = document.lineAt(position.line).text;
  // not in a comment
  if (/^[^'"]*!/.test(line.slice(0, word.start.character))) {
    return undefined;
  }
  const start = hoverExpressionStart(line, word.start.character);
  const range = new vscode.Range(position.line, start, position.line, word.end.character);
  return new vscode.EvaluatableExpression(range, line.slice(start, word.end.character).replace(/\s+/g, ""));
}

/** A process to attach to, picked from those running: its id */
async function pickProcess(): Promise<string | undefined> {
  const windows = process.platform === "win32";
  const lister = programPath(windows ? "tasklist" : "ps");
  const text = await new Promise<string>((resolve) =>
    execFile(
      lister ?? "",
      windows ? ["/fo", "csv", "/nh"] : ["-A", "-o", "pid=,args="],
      { maxBuffer: 16 * 1024 * 1024, windowsHide: true },
      (error, stdout) => resolve(error ? "" : stdout),
    ),
  );
  const items = parseProcesses(text, process.platform)
    .filter((p) => p.pid !== process.pid)
    .map((p) => ({ label: p.name, description: String(p.pid), detail: p.command, pid: p.pid }));
  const picked = await vscode.window.showQuickPick(items, {
    placeHolder: vscode.l10n.t("The process to attach to"),
    matchOnDescription: true,
    matchOnDetail: true,
  });
  return picked ? String(picked.pid) : undefined;
}

function fpmProjectFor(folder: vscode.WorkspaceFolder | undefined, cwd: string | undefined): Promise<FpmProject | undefined> {
  const dir = cwd ?? folder?.uri.fsPath;
  return dir ? projectOf(vscode.Uri.file(path.join(dir, "fpm.toml"))) : Promise.resolve(undefined);
}

/** The debugger: the configuration's, else zfls.run.debugger's, among
 * those installed; programs with Microsoft's debug information only (as
 * zfls says of the compiler, or `"dbgeng": true`) need Windows's Debugger
 * Engine or the Visual Studio debugger */
function pick(
  run: vscode.WorkspaceConfiguration,
  config: vscode.DebugConfiguration,
  msvc: boolean,
  gdb: string | undefined,
  lldb: boolean | string,
): ReturnType<typeof chooseInstalledDebugger> {
  const preference = typeof config.debugger === "string" ? config.debugger : run.get<string>("debugger", "auto");
  const configured = typeof config.gdb === "string" && config.gdb ? config.gdb : undefined;
  return chooseInstalledDebugger(preference, msvc, configured ?? gdb, lldb);
}

function finish(
  config: vscode.DebugConfiguration,
  type: Parameters<typeof fortranLaunch>[1]["type"],
  program: string,
  cwd: string,
  compiler: CompilerInfo | undefined,
  scope: vscode.Uri | undefined,
  log: vscode.LogOutputChannel,
  msvc: boolean,
): vscode.DebugConfiguration {
  const resolved = fortranLaunch(config, {
    type,
    program,
    cwd,
    runtimeEnv: compiler?.runEnv ?? {},
    platform: process.platform,
    gdbPath: gdbFor(scope ?? vscode.Uri.file(cwd), compiler?.compiler),
    lldb: usesLldb(config, scope) !== false,
    msvc,
    sourceRoot: scope?.fsPath,
  }) as vscode.DebugConfiguration;
  log.info(`[debug] ${config.name}: ${JSON.stringify(resolved)}`);
  return resolved;
}
