// Helpers for running external tools (formatters, compilers): expanding
// variables in configured paths and arguments, finding an executable, and
// running a process with its input on stdin. No `vscode` import, so that
// plain Node.js unit tests can load this module.

import * as cp from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/** What `${...}` variables in a setting stand for. */
export interface VariableContext {
  /** The workspace folder of the file, or the first one */
  workspaceFolder?: string;
  /** All workspace folders by name, for `${workspaceFolder:name}` */
  workspaceFolders?: Record<string, string>;
  /** The file the tool runs on */
  file?: string;
  env?: NodeJS.ProcessEnv;
  home?: string;
}

/**
 * Expands, as VS Code does in tasks and launch configurations,
 * `${workspaceFolder}`, `${workspaceFolder:name}`, `${workspaceFolderBasename}`,
 * `${userHome}`, `${env:NAME}`, `${file}`, `${fileDirname}`, `${fileBasename}`,
 * `${fileBasenameNoExtension}`, `${fileExtname}` and `${pathSeparator}`, and a
 * leading `~` (followed by a separator or alone). An unknown variable, or one
 * without a value here, is left as it is.
 */
export function expandVariables(value: string, ctx: VariableContext): string {
  const env = ctx.env ?? process.env;
  const home = ctx.home ?? os.homedir();
  const file = ctx.file;
  const expanded = value.replace(/\$\{([^}]+)\}/g, (whole, name: string) => {
    let result: string | undefined;
    if (name.startsWith("env:")) {
      result = lookupEnv(env, name.slice(4)) ?? "";
    } else if (name.startsWith("workspaceFolder:")) {
      result = ctx.workspaceFolders?.[name.slice("workspaceFolder:".length)];
    } else {
      switch (name) {
        case "workspaceFolder":
        case "workspaceRoot":
          result = ctx.workspaceFolder;
          break;
        case "workspaceFolderBasename":
          result = ctx.workspaceFolder && path.basename(ctx.workspaceFolder);
          break;
        case "userHome":
          result = home;
          break;
        case "pathSeparator":
          result = path.sep;
          break;
        case "file":
          result = file;
          break;
        case "fileDirname":
          result = file && path.dirname(file);
          break;
        case "fileBasename":
          result = file && path.basename(file);
          break;
        case "fileExtname":
          result = file && path.extname(file);
          break;
        case "fileBasenameNoExtension":
          result = file && path.basename(file, path.extname(file));
          break;
      }
    }
    return result ?? whole;
  });
  if (expanded === "~") {
    return home;
  }
  if (expanded.startsWith("~/") || expanded.startsWith("~\\")) {
    return path.join(home, expanded.slice(2));
  }
  return expanded;
}

/** An environment variable; case-insensitive on Windows, as there. */
function lookupEnv(env: NodeJS.ProcessEnv, name: string): string | undefined {
  if (env[name] !== undefined || process.platform !== "win32") {
    return env[name];
  }
  const key = Object.keys(env).find((k) => k.toUpperCase() === name.toUpperCase());
  return key === undefined ? undefined : env[key];
}

/**
 * The executable to run for `name`.
 *
 * `configured`, when not empty, is the executable itself or a directory that
 * holds it; a relative one is taken relative to `baseDir`. Otherwise `name` is
 * looked up on the PATH. On Windows the PATHEXT extensions (`.exe`, ...) are
 * tried too. Undefined when there is no such file.
 */
export function findExecutable(
  name: string,
  configured: string,
  baseDir: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const pathMod = platform === "win32" ? path.win32 : path.posix;
  const exts =
    platform === "win32"
      ? ["", ...(lookupEnv(env, "PATHEXT") ?? ".COM;.EXE;.BAT;.CMD").split(";").filter(Boolean)]
      : [""];
  const tryFile = (file: string): string | undefined => {
    for (const ext of exts) {
      const candidate = file + ext.toLowerCase();
      if (isFile(candidate)) {
        return candidate;
      }
    }
    return undefined;
  };
  if (configured) {
    const full =
      pathMod.isAbsolute(configured) || !baseDir ? configured : pathMod.resolve(baseDir, configured);
    if (isDirectory(full)) {
      return tryFile(pathMod.join(full, name));
    }
    return tryFile(full);
  }
  if (pathMod.isAbsolute(name)) {
    return tryFile(name);
  }
  const dirs = (lookupEnv(env, "PATH") ?? "").split(platform === "win32" ? ";" : ":");
  for (const dir of dirs) {
    if (dir) {
      const found = tryFile(pathMod.join(dir, name));
      if (found) {
        return found;
      }
    }
  }
  return undefined;
}

function isFile(file: string): boolean {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function isDirectory(file: string): boolean {
  try {
    return fs.statSync(file).isDirectory();
  } catch {
    return false;
  }
}

export interface ProcessResult {
  /** The exit code, or null when killed by a signal */
  code: number | null;
  stdout: string;
  stderr: string;
  /** Set when the process could not be started, or was cancelled or timed out */
  error?: Error;
}

export interface RunOptions {
  cwd?: string;
  /** Written to the process's stdin, which is then closed */
  input?: string;
  /** Milliseconds before the process is killed; none when 0 or undefined */
  timeout?: number;
  /** Kills the process when aborted */
  signal?: AbortSignal;
  env?: NodeJS.ProcessEnv;
}

/**
 * Runs `command` with `args` without a shell, so that arguments need no
 * quoting, and collects its output as UTF-8.
 */
export function runProcess(command: string, args: string[], opts: RunOptions = {}): Promise<ProcessResult> {
  return new Promise((resolve) => {
    let child: cp.ChildProcess;
    try {
      child = cp.spawn(command, args, {
        cwd: opts.cwd,
        env: opts.env,
        signal: opts.signal,
        timeout: opts.timeout || undefined,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (err) {
      resolve({ code: null, stdout: "", stderr: "", error: err as Error });
      return;
    }
    const out: Buffer[] = [];
    const errOut: Buffer[] = [];
    let error: Error | undefined;
    let timedOut = false;
    child.stdout?.on("data", (d: Buffer) => out.push(d));
    child.stderr?.on("data", (d: Buffer) => errOut.push(d));
    child.on("error", (err) => {
      error ??= err;
    });
    child.on("exit", (_code, signal) => {
      if (signal && opts.timeout && !opts.signal?.aborted) {
        timedOut = true;
      }
    });
    child.on("close", (code) => {
      if (timedOut && !error) {
        error = new Error(`timed out after ${opts.timeout} ms`);
      }
      resolve({
        code,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(errOut).toString("utf8"),
        error,
      });
    });
    // a process that exits without reading its input closes the pipe
    child.stdin?.on("error", () => undefined);
    child.stdin?.end(opts.input ?? "", "utf8");
  });
}
