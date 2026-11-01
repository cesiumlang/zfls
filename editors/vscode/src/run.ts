// The pure parts of running and debugging a single Fortran file: compiler
// arguments, where the program goes, which debugger to use and its launch
// configuration. No `vscode` import (see test/unit).

import * as crypto from "node:crypto";
import * as path from "node:path";

/** How a compiler takes its options */
export type ArgStyle = "gnu" | "intel-windows";

export interface CompilerKind {
  argStyle: ArgStyle;
  /** Whether its programs use the MSVC ABI and debug info (PDB), which
   * needs the cppvsdbg debugger rather than gdb */
  msvc: boolean;
  /** The arguments when zfls.run.buildArgs is not set: debug info, no
   * optimization */
  defaultArgs: string[];
}

/** The compiler's name without directory, extension or version suffix:
 * `C:\x\ifx.exe` -> `ifx`, `gfortran-14` -> `gfortran`. */
export function compilerName(compiler: string): string {
  const base = path.basename(compiler.replace(/\\/g, "/")).toLowerCase();
  return base.replace(/\.exe$/, "").replace(/-\d+(\.\d+)*$/, "");
}

export function compilerKind(compiler: string, platform: NodeJS.Platform): CompilerKind {
  const name = compilerName(compiler);
  const windows = platform === "win32";
  if ((name === "ifx" || name === "ifort") && windows) {
    return { argStyle: "intel-windows", msvc: true, defaultArgs: ["/Zi", "/Od"] };
  }
  if (name === "lfortran") {
    return { argStyle: "gnu", msvc: windows, defaultArgs: ["-g"] };
  }
  // LLVM Flang targets the MSVC ABI on Windows
  const msvc = windows && (name === "flang" || name === "flang-new");
  return { argStyle: "gnu", msvc, defaultArgs: ["-g", "-O0"] };
}

/**
 * The compiler arguments that build `source` into `exe`, run in the output
 * directory (where module and object files then go). The directory of the
 * source is on the include path, for its include files and modules.
 */
export function buildArgs(
  kind: CompilerKind,
  source: string,
  exe: string,
  userArgs: readonly string[] | undefined,
): string[] {
  const args = userArgs ?? kind.defaultArgs;
  const dir = path.dirname(source);
  if (kind.argStyle === "intel-windows") {
    return ["/nologo", ...args, `/I${dir}`, `/exe:${exe}`, source];
  }
  return [...args, `-I${dir}`, "-o", exe, source];
}

/**
 * The directory for the program built from `source`: under `base` (the
 * extension's storage), a directory per source file, so that files of the
 * same name and their module files do not collide.
 */
export function outputDirFor(base: string, source: string, platform: NodeJS.Platform = process.platform): string {
  const key = platform === "win32" ? source.toLowerCase() : source;
  const hash = crypto.createHash("sha256").update(key).digest("hex").slice(0, 10);
  return pathFor(platform).join(base, `${stem(source, platform)}-${hash}`);
}

/** The program file for `source` in `dir` */
export function programPath(dir: string, source: string, platform: NodeJS.Platform = process.platform): string {
  return pathFor(platform).join(dir, stem(source, platform) + (platform === "win32" ? ".exe" : ""));
}

function pathFor(platform: NodeJS.Platform): path.PlatformPath {
  return platform === "win32" ? path.win32 : path.posix;
}

function stem(file: string, platform: NodeJS.Platform): string {
  const p = pathFor(platform);
  return p.basename(file, p.extname(file));
}

// Debuggers

export type DebugType = "cppdbg" | "cppvsdbg" | "lldb" | "gdb";

export const DEBUGGER_EXTENSIONS: Record<DebugType, { id: string; name: string }> = {
  cppdbg: { id: "ms-vscode.cpptools", name: "C/C++" },
  cppvsdbg: { id: "ms-vscode.cpptools", name: "C/C++" },
  lldb: { id: "vadimcn.vscode-lldb", name: "CodeLLDB" },
  gdb: { id: "eclipse-cdt.cdt-gdb-vscode", name: "CDT GDB Debug Adapter" },
};

export type DebuggerChoice =
  | { type: DebugType }
  /** `missing`: the debug type configured, else any debugger (`msvc`: for
   * MSVC-ABI programs) */
  | { missing: DebugType | "any" | "msvc"; extensions: string[] };

/**
 * The debugger for a program: the configured one (`auto` or a debug type),
 * else the first installed of C/C++ (cppvsdbg for MSVC-ABI programs, else
 * cppdbg), CodeLLDB and CDT GDB. For an MSVC-ABI program only C/C++ will
 * do. When the chosen one's extension is not installed, which to install.
 */
export function chooseDebugger(
  preference: string,
  installed: (extensionId: string) => boolean,
  msvc: boolean,
): DebuggerChoice {
  if (preference in DEBUGGER_EXTENSIONS) {
    const type = preference as DebugType;
    const ext = DEBUGGER_EXTENSIONS[type];
    return installed(ext.id) ? { type } : { missing: type, extensions: [ext.id] };
  }
  const candidates: DebugType[] = msvc ? ["cppvsdbg"] : ["cppdbg", "lldb", "gdb"];
  for (const type of candidates) {
    if (installed(DEBUGGER_EXTENSIONS[type].id)) {
      return { type };
    }
  }
  return {
    missing: msvc ? "msvc" : "any",
    extensions: [...new Set(candidates.map((t) => DEBUGGER_EXTENSIONS[t].id))],
  };
}

export interface LaunchSpec {
  name: string;
  type: DebugType;
  program: string;
  args: string[];
  cwd: string;
  /** Extra environment of the program */
  env: Record<string, string>;
  platform: NodeJS.Platform;
  /** gdb for cppdbg and CDT GDB; empty: the debugger's default */
  gdbPath?: string;
  preLaunchTask?: string;
}

/** A launch configuration for the debugger extension of `spec.type`. */
export function launchConfiguration(spec: LaunchSpec): Record<string, unknown> {
  const config: Record<string, unknown> = {
    name: spec.name,
    type: spec.type,
    request: "launch",
    program: spec.program,
  };
  const envList = Object.entries(spec.env).map(([name, value]) => ({ name, value }));
  switch (spec.type) {
    case "cppdbg":
      Object.assign(config, {
        args: spec.args,
        cwd: spec.cwd,
        stopAtEntry: false,
        externalConsole: false,
        // gdb, except on macOS, where gfortran programs are debugged with lldb
        MIMode: spec.platform === "darwin" ? "lldb" : "gdb",
      });
      if (spec.platform !== "darwin") {
        config.setupCommands = [
          { description: "Enable pretty-printing for gdb", text: "-enable-pretty-printing", ignoreFailures: true },
        ];
        if (spec.gdbPath) {
          config.miDebuggerPath = spec.gdbPath;
        }
      }
      if (envList.length) {
        config.environment = envList;
      }
      break;
    case "cppvsdbg":
      Object.assign(config, { args: spec.args, cwd: spec.cwd, stopAtEntry: false, console: "integratedTerminal" });
      if (envList.length) {
        config.environment = envList;
      }
      break;
    case "lldb":
      Object.assign(config, { args: spec.args, cwd: spec.cwd });
      if (envList.length) {
        config.env = spec.env;
      }
      break;
    case "gdb":
      Object.assign(config, { arguments: spec.args.map(quoteGdbArg).join(" "), cwd: spec.cwd });
      if (spec.gdbPath) {
        config.gdb = spec.gdbPath;
      }
      if (envList.length) {
        config.environment = spec.env;
      }
      break;
  }
  if (spec.preLaunchTask) {
    config.preLaunchTask = spec.preLaunchTask;
  }
  return config;
}

/** CDT GDB takes the program arguments as one string, split by gdb */
function quoteGdbArg(arg: string): string {
  return /^[\w@%+=:,./-]+$/.test(arg) ? arg : `"${arg.replace(/(["\\$`])/g, "\\$1")}"`;
}

/**
 * The environment additions for running a program built by `compiler` on
 * Windows: its directory first on the PATH, for the compiler's runtime
 * libraries (libgfortran-5.dll and the like) when it is not on the PATH.
 */
export function runtimeEnv(
  compilerExe: string,
  platform: NodeJS.Platform,
  env: NodeJS.ProcessEnv,
): Record<string, string> {
  if (platform !== "win32") {
    return {};
  }
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH") ?? "Path";
  const dir = path.win32.dirname(compilerExe);
  const current = env[key] ?? "";
  const entries = current.split(";").map((e) => e.replace(/[\\/]+$/, "").toLowerCase());
  if (entries.includes(dir.replace(/[\\/]+$/, "").toLowerCase())) {
    return {};
  }
  return { [key]: current ? `${dir};${current}` : dir };
}

/** Upserts `entry` into `list` by the value of `key`. */
export function upsertByKey<T extends Record<string, unknown>>(list: readonly T[], entry: T, key: string): T[] {
  const result = list.filter((e) => e[key] !== entry[key]);
  const at = list.findIndex((e) => e[key] === entry[key]);
  result.splice(at < 0 ? result.length : at, 0, entry);
  return result;
}

/**
 * `file` with the workspace folder replaced by `${workspaceFolder}` when it
 * is inside it, for launch.json and tasks.json, which VS Code expands.
 */
export function workspaceRelative(file: string, folder: string | undefined): string {
  if (!folder) {
    return file;
  }
  const rel = path.relative(folder, file);
  if (rel === "") {
    return "${workspaceFolder}";
  }
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    return file;
  }
  return `\${workspaceFolder}/${rel.split(path.sep).join("/")}`;
}

// The `fortran` debug type

/** What a `fortran` launch configuration takes, beyond `name` */
export const FORTRAN_LAUNCH_KEYS = [
  "type",
  "request",
  "name",
  "program",
  "fpmTarget",
  "fpmTargetKind",
  "args",
  "cwd",
  "env",
  "debugger",
  "compiler",
  "stopAtEntry",
  "preLaunchTask",
] as const;

/** How a `fortran` configuration was resolved */
export interface FortranResolution {
  type: DebugType;
  program: string;
  cwd: string;
  /** The compiler's runtime libraries on the PATH (Windows) */
  runtimeEnv: Record<string, string>;
  platform: NodeJS.Platform;
  gdbPath?: string;
}

/**
 * The launch configuration of the chosen debugger for a `fortran` one: its
 * program, arguments, directory and environment (its own after the
 * compiler's runtime PATH), `stopAtEntry`, and every key it has that the
 * `fortran` type does not know (`MIMode`, `setupCommands`, ...), as they
 * are, for the debugger.
 */
export function fortranLaunch(config: Record<string, unknown>, r: FortranResolution): Record<string, unknown> {
  const env = { ...r.runtimeEnv, ...((config.env as Record<string, string> | undefined) ?? {}) };
  const out = launchConfiguration({
    name: String(config.name ?? "Fortran"),
    type: r.type,
    program: r.program,
    args: Array.isArray(config.args) ? config.args.map(String) : [],
    cwd: r.cwd,
    env,
    platform: r.platform,
    gdbPath: r.gdbPath,
    preLaunchTask: typeof config.preLaunchTask === "string" ? config.preLaunchTask : undefined,
  });
  // CodeLLDB's name for it; CDT GDB has none
  if (config.stopAtEntry === true && r.type !== "gdb") {
    out[r.type === "lldb" ? "stopOnEntry" : "stopAtEntry"] = true;
  }
  for (const [k, v] of Object.entries(config)) {
    if (!(FORTRAN_LAUNCH_KEYS as readonly string[]).includes(k)) {
      out[k] = v;
    }
  }
  return out;
}
