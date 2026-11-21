// The pure parts of running and debugging a single Fortran file: what
// zfls answers about building it (`zfls/buildCommand`), which debugger to
// use and its launch configuration. zfls chooses the compiler's
// arguments, where the program goes and how it links; this module only
// turns its answer into VS Code's. No `vscode` import (see test/unit).

import * as path from "node:path";

/** What concerns the compiler, in zfls's answer: also without a file */
export interface CompilerInfo {
  /** The compiler's executable */
  compiler: string;
  /** The compiler zfls knows it as (`gfortran`, `flang`, ...) */
  name: string | null;
  /** The format of its programs' debug information */
  debugInfo: "dwarf" | "pdb";
  /** The debugger of `zfls dap` that fits its programs */
  debugger: "gdb" | "lldb" | "dbgeng";
  /** The program's environment beyond the editor's (its runtime libraries) */
  runEnv: Record<string, string>;
}

/** zfls's answer to `zfls/buildCommand` for a file */
export interface BuildCommand extends CompilerInfo {
  args: string[];
  /** A build in two steps: `args` compiles, then the compiler with these
   * links (Nix's gfortran on macOS) */
  linkArgs?: string[];
  /** Where the build runs and module files go */
  cwd: string;
  /** The build's environment beyond the editor's */
  env: Record<string, string>;
  program: string;
  /** Why the build links otherwise than it could */
  note?: string;
}

export interface BuildCommandParams {
  /** Without one, the answer is only the compiler's part */
  textDocument?: { uri: string };
  compiler?: string;
  compilerPath?: string;
  args?: string[];
  outputDirectory?: string;
  /** Values in place of the environment's, for the answer's additions */
  env?: Record<string, string>;
}

// Debuggers

/** The debuggers of other extensions */
export type ExtensionDebugType = "cppdbg" | "cppvsdbg" | "lldb" | "gdb";

/** `zfls`: zfls's own debug adapter (`zfls dap`, in front of gdb's Debug
 * Adapter Protocol or Windows's Debugger Engine), behind the `fortran`
 * debug type */
export type DebugType = ExtensionDebugType | "zfls";

export const DEBUGGER_EXTENSIONS: Record<ExtensionDebugType, { id: string; name: string }> = {
  cppdbg: { id: "ms-vscode.cpptools", name: "C/C++" },
  cppvsdbg: { id: "ms-vscode.cpptools", name: "C/C++" },
  lldb: { id: "vadimcn.vscode-lldb", name: "CodeLLDB" },
  gdb: { id: "eclipse-cdt.cdt-gdb-vscode", name: "CDT GDB Debug Adapter" },
};

export type DebuggerChoice =
  | { type: DebugType }
  /** `missing`: the debug type configured, else any debugger (`msvc`: for
   * MSVC-ABI programs); `zfls`: no gdb of the Debug Adapter Protocol */
  | { missing: DebugType | "any" | "msvc"; extensions: string[] };

/**
 * The debugger for a program: the configured one (`auto` or a debug type),
 * else zfls's own when there is a gdb of the Debug Adapter Protocol (gdb
 * 14 or later, with Python), else the first installed of C/C++ (cppvsdbg
 * for MSVC-ABI programs, else cppdbg), CodeLLDB and CDT GDB. For an
 * MSVC-ABI program only C/C++ will do (gdb cannot read its debug
 * information). When the chosen one's extension is not installed, which
 * to install.
 */
export function chooseDebugger(
  preference: string,
  installed: (extensionId: string) => boolean,
  msvc: boolean,
  gdbDap = false,
  dbgeng = false,
): DebuggerChoice {
  // zfls's own: in front of gdb, or for MSVC-ABI programs of Windows's
  // Debugger Engine (zfls dap)
  const own = msvc ? dbgeng : gdbDap;
  if (preference === "zfls") {
    return own ? { type: "zfls" } : { missing: "zfls", extensions: [] };
  }
  if (preference in DEBUGGER_EXTENSIONS) {
    const type = preference as ExtensionDebugType;
    const ext = DEBUGGER_EXTENSIONS[type];
    return installed(ext.id) ? { type } : { missing: type, extensions: [ext.id] };
  }
  if (own) {
    return { type: "zfls" };
  }
  const candidates: ExtensionDebugType[] = msvc ? ["cppvsdbg"] : ["cppdbg", "lldb", "gdb"];
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
  /** gdb for zfls, cppdbg and CDT GDB; empty: the debugger's default */
  gdbPath?: string;
  /** zfls's debugger runs lldb-dap, not gdb (the default on macOS) */
  lldb?: boolean;
  preLaunchTask?: string;
  /** Where the program's input and output go: the Debug Console (no
   * input), VS Code's terminal, or a terminal of its own */
  console?: "internalConsole" | "integratedTerminal" | "externalTerminal";
  /** An MSVC-ABI program: zfls's debugger is Windows's Debugger Engine */
  msvc?: boolean;
  /** For zfls's debugger: the sources to index, for the declarations */
  sourceRoot?: string;
}

/** A launch configuration for the debugger of `spec.type`: zfls's is the
 * `fortran` type itself, resolved. */
export function launchConfiguration(spec: LaunchSpec): Record<string, unknown> {
  const config: Record<string, unknown> = {
    name: spec.name,
    type: spec.type === "zfls" ? "fortran" : spec.type,
    request: "launch",
    program: spec.program,
  };
  const envList = Object.entries(spec.env).map(([name, value]) => ({ name, value }));
  const terminal = spec.console && spec.console !== "internalConsole";
  switch (spec.type) {
    case "zfls":
      Object.assign(config, { args: spec.args, cwd: spec.cwd, debugger: "zfls" });
      if (spec.msvc) {
        // Windows's Debugger Engine, through zfls dap
        config.dbgeng = true;
      } else if (spec.lldb) {
        config.lldb = true;
      } else if (spec.gdbPath) {
        config.gdb = spec.gdbPath;
      }
      if (spec.sourceRoot) {
        config.sourceRoot = spec.sourceRoot;
      }
      if (envList.length) {
        config.env = spec.env;
      }
      if (spec.console) {
        config.console = spec.console;
      }
      break;
    case "cppdbg":
      Object.assign(config, {
        args: spec.args,
        cwd: spec.cwd,
        stopAtEntry: false,
        externalConsole: spec.console === "externalTerminal",
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
      Object.assign(config, {
        args: spec.args,
        cwd: spec.cwd,
        stopAtEntry: false,
        console: spec.console === "externalTerminal" ? "externalTerminal" : "integratedTerminal",
      });
      if (envList.length) {
        config.environment = envList;
      }
      break;
    case "lldb":
      Object.assign(config, { args: spec.args, cwd: spec.cwd });
      if (envList.length) {
        config.env = spec.env;
      }
      if (terminal) {
        config.terminal = spec.console === "externalTerminal" ? "external" : "integrated";
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

export interface ProcessInfo {
  pid: number;
  name: string;
  command: string;
}

/** The processes of `tasklist /fo csv /nh` (Windows) or `ps -A -o pid=,args=` */
export function parseProcesses(text: string, platform: NodeJS.Platform): ProcessInfo[] {
  const out: ProcessInfo[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (platform === "win32") {
      const m = /^"([^"]*)","(\d+)"/.exec(line.trim());
      if (m) {
        out.push({ pid: Number(m[2]), name: m[1], command: m[1] });
      }
    } else {
      const m = /^\s*(\d+)\s+(.+)$/.exec(line);
      if (m) {
        const exe = m[2].split(/\s+/)[0];
        out.push({ pid: Number(m[1]), name: path.posix.basename(exe), command: m[2].trim() });
      }
    }
  }
  return out;
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

/** The debugger's options of `zfls dap`, for a configuration: `--dbgeng`,
 * `--lldb [PATH]` or `--gdb PATH`; none when it names no debugger: zfls dap
 * chooses by the program's debug information (Windows's Debugger Engine
 * for a PDB), else lldb-dap on macOS and gdb elsewhere */
export function adapterArgs(config: Record<string, unknown>): string[] {
  if (config.dbgeng === true) {
    return ["--dbgeng"];
  }
  if (config.lldb === true || (typeof config.lldb === "string" && config.lldb)) {
    return typeof config.lldb === "string" ? ["--lldb", config.lldb] : ["--lldb"];
  }
  if (typeof config.gdb === "string" && config.gdb) {
    return ["--gdb", config.gdb];
  }
  return config.lldb === false ? ["--gdb", "gdb"] : [];
}

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
  "console",
] as const;

const CONSOLES = ["internalConsole", "integratedTerminal", "externalTerminal"] as const;

/** How a `fortran` configuration was resolved */
export interface FortranResolution {
  type: DebugType;
  program: string;
  cwd: string;
  /** An MSVC-ABI program (zfls's debugger: Windows's Debugger Engine) */
  msvc?: boolean;
  /** The sources zfls's debugger indexes, for the variables' declarations */
  sourceRoot?: string;
  /** The compiler's runtime libraries on the PATH (Windows) */
  runtimeEnv: Record<string, string>;
  platform: NodeJS.Platform;
  gdbPath?: string;
  /** zfls's debugger runs lldb-dap */
  lldb?: boolean;
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
    lldb: r.lldb,
    preLaunchTask: typeof config.preLaunchTask === "string" ? config.preLaunchTask : undefined,
    console: CONSOLES.find((c) => c === config.console),
    msvc: r.msvc,
    sourceRoot: typeof config.sourceRoot === "string" ? config.sourceRoot : r.sourceRoot,
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
