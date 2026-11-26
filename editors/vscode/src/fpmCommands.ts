// fpm (Fortran Package Manager) projects, as zfls finds them
// (`zfls/fpmTargets`): their tasks (type `fpm`), running and debugging
// their targets (zfls.fpm.run, zfls.fpm.debug), and Run and Debug Fortran
// File on the main program of a target. The test explorer is in
// fpmTests.ts.

import * as path from "node:path";
import * as vscode from "vscode";
import {
  BuildOptions,
  FoundProject,
  Target,
  TargetKind,
  TaskCommand,
  fpmDwarfFlags,
  hasDwarf,
  listArgs,
  parseList,
  parseRunnerEcho,
  runArgs,
  targetOfFile,
  taskArgs,
} from "./fpm";
import type { Servers } from "./fpmTests";
import { CompilerInfo, launchConfiguration } from "./run";
import { addFileRunner, chooseInstalledDebugger, compilerInfo, gdbFor, runTask } from "./runFile";
import { expandVariables, findExecutable, runProcess } from "./tools";
import { folderVariables } from "./variables";

/** A directory with an fpm.toml */
export interface FpmProject {
  root: string;
  folder: vscode.WorkspaceFolder | undefined;
  /** fpm.toml's `name`, else the directory's */
  name: string;
  /** Its targets and their main programs, as zfls finds them; empty when
   * not asked */
  targets: (Target & { main: string })[];
}

/** A task of tasks.json, or one this extension provides */
export interface FpmTaskDefinition extends vscode.TaskDefinition {
  type: "fpm";
  command: TaskCommand;
  target?: string;
  example?: boolean;
  profile?: string;
  compiler?: string;
  flags?: string;
  args?: string[];
  programArgs?: string[];
  /** The project's directory, relative to the workspace folder */
  cwd?: string;
}

const PROBLEM_MATCHERS = ["$zfls-gfortran", "$zfls-intel"];
/** The environment of a build whose messages the problem matchers read:
 * the C locale, so that the compiler writes "Error" and "Warning" in English */
const MATCHER_ENV = { LC_ALL: "C" };

/** The zfls servers, which find the projects */
let servers: Servers = async () => [];

export function registerFpm(context: vscode.ExtensionContext, log: vscode.LogOutputChannel, zfls: Servers): void {
  servers = zfls;
  context.subscriptions.push(
    vscode.tasks.registerTaskProvider("fpm", {
      provideTasks: () => provideTasks(),
      resolveTask: (task) => resolveTask(task),
    }),
    vscode.commands.registerCommand("zfls.fpm.run", () => runOrDebugTarget(log, false)),
    vscode.commands.registerCommand("zfls.fpm.debug", () => runOrDebugTarget(log, true)),
  );
  addFileRunner(async (document, debug) => {
    if (!vscode.workspace.getConfiguration("zfls.fpm", document.uri).get<boolean>("runFile", true)) {
      return false;
    }
    const project = await projectOf(document.uri);
    const target = project && targetOfFile(project.targets, document.uri.fsPath);
    if (!target) {
      return false;
    }
    await (debug ? debugTarget(project, target, log) : runTarget(project, target));
    return true;
  });
}

/** The fpm project of a file: the nearest directory above it with an
 * fpm.toml, as zfls finds the projects */
export async function projectOf(uri: vscode.Uri): Promise<FpmProject | undefined> {
  if (uri.scheme !== "file") {
    return undefined;
  }
  const inside = (p: FpmProject): boolean => {
    const rel = path.relative(p.root, uri.fsPath);
    return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
  };
  // the innermost: the longest root
  return (await findProjects()).filter(inside).sort((a, b) => b.root.length - a.root.length)[0];
}

/** A project by its directory, without asking zfls for its targets */
export function projectAt(root: string): FpmProject {
  return { root, folder: vscode.workspace.getWorkspaceFolder(vscode.Uri.file(root)), name: path.basename(root), targets: [] };
}

/** The fpm projects of the workspace, as the zfls servers find them */
export async function findProjects(): Promise<FpmProject[]> {
  const byRoot = new Map<string, FpmProject>();
  for (const client of await servers()) {
    const found = (await client.sendRequest<FoundProject[] | null>("zfls/fpmTargets", {})) ?? [];
    for (const p of found) {
      const root = vscode.Uri.parse(p.uri).fsPath;
      byRoot.set(root, {
        root,
        folder: vscode.workspace.getWorkspaceFolder(vscode.Uri.file(root)),
        name: p.name,
        targets: p.targets.map((x) => ({ kind: x.kind, name: x.name, main: vscode.Uri.parse(x.uri).fsPath })),
      });
    }
  }
  return [...byRoot.values()].sort((a, b) => a.root.localeCompare(b.root));
}

/** The fpm executable of zfls.fpm.path, or undefined with a message */
export function fpmExecutable(project: FpmProject, quiet = false): string | undefined {
  const scope = vscode.Uri.file(project.root);
  const configured = expandVariables(
    vscode.workspace.getConfiguration("zfls.fpm", scope).get<string>("path", "").trim(),
    folderVariables(project.folder),
  );
  const fpm = findExecutable("fpm", configured, project.folder?.uri.fsPath);
  if (!fpm && !quiet) {
    void vscode.window
      .showErrorMessage(
        configured
          ? vscode.l10n.t(
              "zfls: fpm was not found at {0} (zfls.fpm.path). Install it (https://fpm.fortran-lang.org/install), or set zfls.fpm.path.",
              configured,
            )
          : vscode.l10n.t(
              "zfls: fpm was not found on the PATH. Install it (https://fpm.fortran-lang.org/install), or set zfls.fpm.path.",
            ),
        vscode.l10n.t("Open Settings"),
      )
      .then((choice) => {
        if (choice) {
          void vscode.commands.executeCommand("workbench.action.openSettings", "zfls.fpm");
        }
      });
  }
  return fpm;
}

/** A target's debug build: its options, the compiler zfls finds, and
 * whether its programs have Microsoft's debug information only */
export interface DebugBuild {
  options: BuildOptions;
  compiler: CompilerInfo | undefined;
  msvc: boolean;
}

/** The debug build of the project's targets: zfls.fpm's options, with DWARF
 * for LLVM Flang on Windows (`fpmDwarfFlags`) where zfls says it links with
 * lld-link; its programs have Microsoft's debug information only when zfls
 * says so of the compiler and the flags do not ask for DWARF */
export async function debugBuild(project: FpmProject): Promise<DebugBuild> {
  const opts = buildOptions(project);
  const compiler = await fpmCompiler(project);
  const flags = fpmDwarfFlags(opts.flags, compiler, process.platform);
  const options = { ...opts, flags };
  return { options, compiler, msvc: compiler?.debugInfo === "pdb" && !(compiler.name === "flang" && hasDwarf(flags)) };
}

/** zfls.fpm.profile, compiler, flags and args */
export function buildOptions(project: FpmProject): BuildOptions {
  const config = vscode.workspace.getConfiguration("zfls.fpm", vscode.Uri.file(project.root));
  const ctx = folderVariables(project.folder);
  const value = (key: string): string | undefined =>
    expandVariables(config.get<string>(key, "").trim(), ctx) || undefined;
  return {
    profile: value("profile"),
    compiler: value("compiler"),
    flags: value("flags"),
    args: config.get<string[]>("args", []).map((a) => expandVariables(a, ctx)),
  };
}

/** The names of the project's targets of a kind, from fpm */
export async function listTargets(project: FpmProject, kind: TargetKind, fpm: string): Promise<string[]> {
  const result = await runProcess(fpm, listArgs(kind), { cwd: project.root, timeout: 300_000 });
  return parseList(result.stdout + "\n" + result.stderr);
}

/** The task of `def` in `project` */
export function fpmTask(project: FpmProject, def: FpmTaskDefinition, name: string, fpm: string): vscode.Task {
  const args = taskArgs(def, buildOptions(project));
  const task = new vscode.Task(
    def,
    project.folder ?? vscode.TaskScope.Workspace,
    name,
    "fpm",
    new vscode.ProcessExecution(fpm, args, {
      cwd: project.root,
      env: def.command === "build" || def.command === "install" ? MATCHER_ENV : undefined,
    }),
    def.command === "clean" ? [] : PROBLEM_MATCHERS,
  );
  if (def.command === "build" || def.command === "install") {
    task.group = vscode.TaskGroup.Build;
  } else if (def.command === "test") {
    task.group = vscode.TaskGroup.Test;
  }
  return task;
}

async function provideTasks(): Promise<vscode.Task[]> {
  const tasks: vscode.Task[] = [];
  const projects = await findProjects();
  for (const project of projects) {
    const fpm = fpmExecutable(project, true) ?? "fpm";
    const rel = project.folder ? path.relative(project.folder.uri.fsPath, project.root) : "";
    const suffix = projects.length > 1 && rel ? ` (${rel.split(path.sep).join("/")})` : "";
    const base = { type: "fpm" as const, ...(rel ? { cwd: rel.split(path.sep).join("/") } : {}) };
    const defs: [FpmTaskDefinition, string][] = [
      [{ ...base, command: "build" }, "build"],
      [{ ...base, command: "build", profile: "release" }, "build --profile release"],
      [{ ...base, command: "run" }, "run"],
      [{ ...base, command: "test" }, "test"],
      [{ ...base, command: "install" }, "install"],
      [{ ...base, command: "clean" }, "clean"],
    ];
    for (const [def, name] of defs) {
      tasks.push(fpmTask(project, def, name + suffix, fpm));
    }
  }
  return tasks;
}

function resolveTask(task: vscode.Task): vscode.Task | undefined {
  const def = task.definition as FpmTaskDefinition;
  if (def.type !== "fpm" || !def.command) {
    return undefined;
  }
  const folder = typeof task.scope === "object" ? task.scope : vscode.workspace.workspaceFolders?.[0];
  if (!folder) {
    return undefined;
  }
  const project = projectAt(def.cwd ? path.resolve(folder.uri.fsPath, def.cwd) : folder.uri.fsPath);
  return fpmTask(project, def, task.name, fpmExecutable(project, true) ?? "fpm");
}

/** zfls.fpm.run and zfls.fpm.debug: a target of the project of the active
 * file (or the only project, or one picked), picked from fpm's list */
async function runOrDebugTarget(log: vscode.LogOutputChannel, debug: boolean): Promise<void> {
  const project = await pickProject();
  if (!project) {
    return;
  }
  const fpm = fpmExecutable(project);
  if (!fpm) {
    return;
  }
  const kinds: TargetKind[] = debug ? ["executable", "example", "test"] : ["executable", "example"];
  const targets = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Window, title: vscode.l10n.t("zfls: listing fpm targets") },
    async () => {
      const all: Target[] = [];
      for (const kind of kinds) {
        for (const name of await listTargets(project, kind, fpm)) {
          all.push({ kind, name });
        }
      }
      return all;
    },
  );
  if (!targets.length) {
    void vscode.window.showErrorMessage(
      debug
        ? vscode.l10n.t("zfls: fpm lists no executables, examples or tests in {0}.", project.root)
        : vscode.l10n.t("zfls: fpm lists no executables or examples in {0}.", project.root),
    );
    return;
  }
  const editor = vscode.window.activeTextEditor?.document;
  const current = editor && targetOfFile(project.targets, editor.uri.fsPath);
  const items = targets.map((t) => ({ label: t.name, description: t.kind, target: t }));
  items.sort((a, b) => Number(isTarget(b.target, current)) - Number(isTarget(a.target, current)));
  const picked =
    items.length === 1
      ? items[0]
      : await vscode.window.showQuickPick(items, { placeHolder: debug ? vscode.l10n.t("Target to debug") : vscode.l10n.t("Target to run") });
  if (!picked) {
    return;
  }
  await (debug ? debugTarget(project, picked.target, log) : runTarget(project, picked.target));
}

function isTarget(a: Target, b: Target | undefined): boolean {
  return !!b && a.kind === b.kind && a.name === b.name;
}

async function pickProject(): Promise<FpmProject | undefined> {
  const active = vscode.window.activeTextEditor?.document.uri;
  const own = active && (await projectOf(active));
  if (own) {
    return own;
  }
  const projects = await findProjects();
  if (projects.length <= 1) {
    if (!projects.length) {
      void vscode.window.showErrorMessage(vscode.l10n.t("zfls: there is no fpm.toml in the workspace."));
    }
    return projects[0];
  }
  const picked = await vscode.window.showQuickPick(
    projects.map((p) => ({ label: p.name, description: p.root, project: p })),
    { placeHolder: vscode.l10n.t("fpm project") },
  );
  return picked?.project;
}

/** The program arguments of zfls.run.programArgs */
function programArgs(project: FpmProject): string[] {
  return vscode.workspace
    .getConfiguration("zfls.run", vscode.Uri.file(project.root))
    .get<string[]>("programArgs", [])
    .map((a) => expandVariables(a, folderVariables(project.folder)));
}

/** Runs a target with `fpm run` (or `fpm test`) in a terminal */
export async function runTarget(project: FpmProject, target: Target): Promise<void> {
  const fpm = fpmExecutable(project);
  if (!fpm) {
    return;
  }
  const def: FpmTaskDefinition = {
    type: "fpm",
    command: target.kind === "test" ? "test" : "run",
    target: target.name,
    ...(target.kind === "example" ? { example: true } : {}),
    programArgs: programArgs(project),
  };
  const task = fpmTask(project, def, `${def.command} ${target.name}`, fpm);
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, focus: true, clear: true };
  await vscode.tasks.executeTask(task);
}

/** The compiler that fpm builds with (zfls.fpm.compiler, else FPM_FC, else
 * gfortran), as zfls finds it */
export function fpmCompiler(project: FpmProject): Promise<CompilerInfo | undefined> {
  const name = buildOptions(project).compiler ?? process.env.FPM_FC ?? "gfortran";
  return compilerInfo(vscode.Uri.file(project.root), name);
}

/**
 * Builds a target with fpm for debugging (`debugBuild`'s options), in a
 * terminal where its errors are seen, and gives its program (from
 * `--runner echo`), or undefined after saying why.
 */
export async function buildTarget(
  project: FpmProject,
  target: Target,
  options: BuildOptions,
  log: vscode.LogOutputChannel,
): Promise<string | undefined> {
  const fpm = fpmExecutable(project);
  if (!fpm) {
    return undefined;
  }
  const echo = runArgs(target, options, [], "echo");
  log.info(`[fpm] ${fpm} ${echo.join(" ")} (in ${project.root})`);
  const build = new vscode.Task(
    { type: "fpm", command: "build", target: target.name } as FpmTaskDefinition,
    project.folder ?? vscode.TaskScope.Workspace,
    `build ${target.name}`,
    "fpm",
    new vscode.ProcessExecution(fpm, echo, { cwd: project.root }),
    PROBLEM_MATCHERS,
  );
  const built = await runTask(build);
  if (built !== 0) {
    void vscode.window.showErrorMessage(
      typeof built === "number"
        ? vscode.l10n.t("zfls: building {0} with fpm failed (exit code {1}); see the terminal.", target.name, built)
        : vscode.l10n.t("zfls: could not run fpm's build task."),
    );
    return undefined;
  }
  const result = await runProcess(fpm, echo, { cwd: project.root, timeout: 300_000 });
  const programs = parseRunnerEcho(result.stdout);
  if (programs.length !== 1) {
    void vscode.window.showErrorMessage(
      programs.length
        ? vscode.l10n.t("zfls: fpm did not give the program of {0} (it gave {1}).", target.name, programs.length)
        : vscode.l10n.t("zfls: fpm did not give the program of {0}.", target.name),
    );
    log.error(`[fpm] ${result.stdout}${result.stderr}`);
    return undefined;
  }
  return path.resolve(project.root, programs[0]);
}

/**
 * Builds a target with fpm, then debugs its program with the debugger of
 * zfls.run.debugger, in the project's directory (where `fpm run` runs it).
 * `extraArgs` go to the program after zfls.run.programArgs. True when the
 * debug session started.
 */
export async function debugTarget(
  project: FpmProject,
  target: Target,
  log: vscode.LogOutputChannel,
  extraArgs: string[] = [],
): Promise<boolean> {
  if (!fpmExecutable(project)) {
    return false;
  }
  const build = await debugBuild(project);
  const scope = vscode.Uri.file(project.root);
  const preference = vscode.workspace.getConfiguration("zfls.run", scope).get<string>("debugger", "auto");
  const gdbPath = gdbFor(scope, build.compiler?.compiler);
  // choose the debugger first: no point building for a debugger that is not there
  const debugType = await chooseInstalledDebugger(preference, build.msvc, gdbPath);
  if (!debugType) {
    return false;
  }
  const program = await buildTarget(project, target, build.options, log);
  if (!program) {
    return false;
  }
  const config = launchConfiguration({
    name: `Debug ${target.name}`,
    type: debugType,
    program,
    args: [...programArgs(project), ...extraArgs],
    cwd: project.root,
    env: build.compiler?.runEnv ?? {},
    platform: process.platform,
    gdbPath,
    msvc: build.msvc,
    sourceRoot: project.root,
  }) as vscode.DebugConfiguration;
  log.info(`[fpm] debugging with ${JSON.stringify(config)}`);
  const started = await vscode.debug.startDebugging(project.folder, config);
  if (!started) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: the {0} debugger did not start; see the Debug Console.", debugType));
  }
  return started;
}
