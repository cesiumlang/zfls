// The `fortran` debug type: a launch configuration that the extension
// resolves into one of the debugger extensions installed (C/C++, CodeLLDB,
// CDT GDB), as Debug Fortran File chooses: the program, or an fpm target
// that it builds first, with its arguments, directory and environment, and
// the compiler's runtime libraries on the PATH on Windows. launch.json
// keeps saying `fortran` whichever debugger runs it. F5 without a
// launch.json debugs the file in the editor; the Run and Debug view offers
// a configuration per fpm target.

import * as path from "node:path";
import * as vscode from "vscode";
import { TargetKind } from "./fpm";
import { FpmProject, buildTarget, findProjects, fpmCompiler, fpmExecutable, listTargets, projectOf } from "./fpmCommands";
import { compilerKind, fortranLaunch, runtimeEnv } from "./run";
import { chooseInstalledDebugger, gdbFor } from "./runFile";
import { expandVariables, findExecutable } from "./tools";
import { folderVariables } from "./variables";

export const DEBUG_TYPE = "fortran";

export function registerDebugType(context: vscode.ExtensionContext, log: vscode.LogOutputChannel): void {
  context.subscriptions.push(
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
  let program: string | undefined;
  let compilerName: string;
  let compilerExe: string | undefined;
  let cwd: string | undefined = typeof config.cwd === "string" && config.cwd ? config.cwd : undefined;
  if (typeof config.fpmTarget === "string" && config.fpmTarget) {
    const project = fpmProjectFor(folder, cwd);
    if (!project) {
      void vscode.window.showErrorMessage(`zfls: no fpm.toml for the fpm target ${config.fpmTarget}.`);
      return undefined;
    }
    const compiler = fpmCompiler(project);
    compilerName = typeof config.compiler === "string" ? config.compiler : compiler.name;
    compilerExe = findExecutable(compilerName) ?? compiler.exe;
    const kind: TargetKind = ["executable", "example", "test"].includes(config.fpmTargetKind) ? config.fpmTargetKind : "executable";
    cwd ??= project.root;
    const debugType = await pick(run, config, compilerExe ?? compilerName);
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
    void vscode.window.showErrorMessage("zfls: a fortran launch configuration needs a program or an fpmTarget.");
    return undefined;
  }
  program = path.resolve(folder?.uri.fsPath ?? "", config.program);
  compilerName = typeof config.compiler === "string" && config.compiler ? config.compiler : run.get<string>("compiler", "gfortran");
  const configuredPath = expandVariables(run.get<string>("compilerPath", "").trim(), folderVariables(folder));
  compilerExe = findExecutable(compilerName, configuredPath, folder?.uri.fsPath);
  const debugType = await pick(run, config, compilerExe ?? compilerName);
  if (!debugType) {
    return undefined;
  }
  return finish(config, debugType, program, cwd ?? path.dirname(program), compilerExe, scope, log);
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
): ReturnType<typeof chooseInstalledDebugger> {
  const preference = typeof config.debugger === "string" ? config.debugger : run.get<string>("debugger", "auto");
  return chooseInstalledDebugger(preference, compilerKind(compiler, process.platform).msvc);
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
