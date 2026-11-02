// The `fortran` debug type: a launch configuration that the extension
// resolves into zfls's own debugger (gdbAdapter.ts, when there is a gdb of
// the Debug Adapter Protocol) or one of the debugger extensions installed
// (C/C++, CodeLLDB, CDT GDB), as Debug Fortran File chooses: the program,
// or an fpm target that it builds first, with its arguments, directory and
// environment, and the compiler's runtime libraries on the PATH on
// Windows. launch.json keeps saying `fortran` whichever debugger runs it.
// F5 without a launch.json debugs the file in the editor; the Run and
// Debug view offers a configuration per fpm target. An `attach`
// configuration attaches zfls's debugger to a running program.

import { execFile } from "node:child_process";
import * as path from "node:path";
import * as vscode from "vscode";
import type { LanguageClient } from "vscode-languageclient/node";
import { TargetKind } from "./fpm";
import { FpmProject, buildTarget, findProjects, fpmCompiler, fpmExecutable, listTargets, projectOf } from "./fpmCommands";
import { hoverExpressionStart } from "./fortranDebug";
import { AdapterText, GdbAdapter, gdbHasDap } from "./gdbAdapter";
import { ModuleVariable } from "./moduleVariables";
import { compilerKind, fortranLaunch, parseProcesses, runtimeEnv } from "./run";
import { chooseInstalledDebugger, gdbFor } from "./runFile";
import { expandVariables, findExecutable } from "./tools";
import { folderVariables } from "./variables";

export const DEBUG_TYPE = "fortran";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];

export function registerDebugType(
  context: vscode.ExtensionContext,
  log: vscode.LogOutputChannel,
  clientFor: (uri: vscode.Uri) => Promise<LanguageClient | undefined>,
): void {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory(DEBUG_TYPE, {
      createDebugAdapterDescriptor: (session) =>
        new vscode.DebugAdapterInlineImplementation(
          new GdbAdapter({
            gdb: typeof session.configuration.gdb === "string" && session.configuration.gdb ? session.configuration.gdb : "gdb",
            moduleVariables: (file, line) => moduleVariables(clientFor, file, line),
            text: adapterText(),
            log: (line) => log.info(line),
          }),
        ),
    }),
    vscode.languages.registerEvaluatableExpressionProvider(
      LANGUAGES.map((language) => ({ language })),
      { provideEvaluatableExpression: evaluatableExpression },
    ),
    vscode.commands.registerCommand("zfls.pickProcess", () => pickProcess()),
    vscode.debug.registerDebugConfigurationProvider(DEBUG_TYPE, {
      resolveDebugConfigurationWithSubstitutedVariables: (folder, config) => resolve(folder, config, log),
      provideDebugConfigurations: () => [
        {
          type: DEBUG_TYPE,
          request: "launch",
          name: "Debug Fortran program",
          program: "${workspaceFolder}/a.out",
          args: [],
          cwd: "${workspaceFolder}",
        },
      ],
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
    const where = projects.length > 1 ? ` (${project.manifest.name ?? path.basename(project.root)})` : "";
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
  let compilerName: string;
  let compilerExe: string | undefined;
  let cwd: string | undefined = typeof config.cwd === "string" && config.cwd ? config.cwd : undefined;
  if (typeof config.fpmTarget === "string" && config.fpmTarget) {
    const project = fpmProjectFor(folder, cwd);
    if (!project) {
      void vscode.window.showErrorMessage(vscode.l10n.t("zfls: no fpm.toml for the fpm target {0}.", config.fpmTarget));
      return undefined;
    }
    const compiler = fpmCompiler(project);
    compilerName = typeof config.compiler === "string" ? config.compiler : compiler.name;
    compilerExe = findExecutable(compilerName) ?? compiler.exe;
    const kind: TargetKind = ["executable", "example", "test"].includes(config.fpmTargetKind) ? config.fpmTargetKind : "executable";
    cwd ??= project.root;
    const debugType = await pick(run, config, compilerExe ?? compilerName, gdbFor(scope ?? vscode.Uri.file(cwd), compilerExe));
    if (!debugType) {
      return undefined;
    }
    program = await buildTarget(project, { kind, name: config.fpmTarget }, log);
    if (!program) {
      return undefined;
    }
    return finish(config, debugType, program, cwd, compilerExe, scope, log);
  }
  if (typeof config.program !== "string" || !config.program) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: a fortran launch configuration needs a program or an fpmTarget."));
    return undefined;
  }
  program = path.resolve(folder?.uri.fsPath ?? "", config.program);
  compilerName = typeof config.compiler === "string" && config.compiler ? config.compiler : run.get<string>("compiler", "gfortran");
  const configuredPath = expandVariables(run.get<string>("compilerPath", "").trim(), folderVariables(folder));
  compilerExe = findExecutable(compilerName, configuredPath, folder?.uri.fsPath);
  cwd ??= path.dirname(program);
  const debugType = await pick(run, config, compilerExe ?? compilerName, gdbFor(scope ?? vscode.Uri.file(cwd), compilerExe));
  if (!debugType) {
    return undefined;
  }
  return finish(config, debugType, program, cwd, compilerExe, scope, log);
}

/** An attach configuration: zfls's debugger, attached to a process
 * (`processId`) or a gdbserver (`target`) */
async function attach(
  folder: vscode.WorkspaceFolder | undefined,
  config: vscode.DebugConfiguration,
  log: vscode.LogOutputChannel,
): Promise<vscode.DebugConfiguration | undefined> {
  const gdb = gdbFor(folder?.uri ?? vscode.Uri.file(process.cwd()), undefined);
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
    gdb: typeof config.gdb === "string" && config.gdb ? config.gdb : gdb,
    ...(typeof config.program === "string" && config.program ? { program: path.resolve(folder?.uri.fsPath ?? "", config.program) } : {}),
  };
  log.info(`[debug] ${config.name}: ${JSON.stringify(resolved)}`);
  return resolved;
}

/** The module variables a line of a Fortran file sees, from its server */
async function moduleVariables(
  clientFor: (uri: vscode.Uri) => Promise<LanguageClient | undefined>,
  file: string,
  line: number,
): Promise<ModuleVariable[]> {
  const uri = vscode.Uri.file(file);
  try {
    const doc = await vscode.workspace.openTextDocument(uri);
    if (!LANGUAGES.includes(doc.languageId)) {
      return [];
    }
  } catch {
    return [];
  }
  const client = await clientFor(uri);
  return (
    (await client?.sendRequest<ModuleVariable[] | null>("zfls/moduleVariables", {
      textDocument: { uri: client.code2ProtocolConverter.asUri(uri) },
      position: { line: line - 1, character: 0 },
    })) ?? []
  );
}

function adapterText(): AdapterText {
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
  };
}

/** The expression under the mouse, while debugging with gdb (which reads
 * Fortran; to lldb and the Visual Studio debugger `p%x` is a remainder): a
 * name with the parents of its component (`p%x`, `a(i)%x`) */
function evaluatableExpression(document: vscode.TextDocument, position: vscode.Position): vscode.EvaluatableExpression | undefined {
  const session = vscode.debug.activeDebugSession;
  const gdb =
    session?.type === DEBUG_TYPE ||
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
  const text = await new Promise<string>((resolve) =>
    execFile(
      windows ? "tasklist" : "ps",
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

function fpmProjectFor(folder: vscode.WorkspaceFolder | undefined, cwd: string | undefined): FpmProject | undefined {
  const dir = cwd ?? folder?.uri.fsPath;
  return dir ? projectOf(vscode.Uri.file(path.join(dir, "fpm.toml"))) : undefined;
}

/** The debugger: the configuration's, else zfls.run.debugger's, among
 * those installed; MSVC-ABI programs (ifx, LLVM Flang on Windows) need
 * the Visual Studio debugger */
function pick(
  run: vscode.WorkspaceConfiguration,
  config: vscode.DebugConfiguration,
  compiler: string,
  gdb: string | undefined,
): ReturnType<typeof chooseInstalledDebugger> {
  const preference = typeof config.debugger === "string" ? config.debugger : run.get<string>("debugger", "auto");
  const configured = typeof config.gdb === "string" && config.gdb ? config.gdb : undefined;
  return chooseInstalledDebugger(preference, compilerKind(compiler, process.platform).msvc, configured ?? gdb);
}

function finish(
  config: vscode.DebugConfiguration,
  type: Parameters<typeof fortranLaunch>[1]["type"],
  program: string,
  cwd: string,
  compilerExe: string | undefined,
  scope: vscode.Uri | undefined,
  log: vscode.LogOutputChannel,
): vscode.DebugConfiguration {
  const resolved = fortranLaunch(config, {
    type,
    program,
    cwd,
    runtimeEnv: compilerExe ? runtimeEnv(compilerExe, process.platform, process.env) : {},
    platform: process.platform,
    gdbPath: gdbFor(scope ?? vscode.Uri.file(cwd), compilerExe),
  }) as vscode.DebugConfiguration;
  log.info(`[debug] ${config.name}: ${JSON.stringify(resolved)}`);
  return resolved;
}
