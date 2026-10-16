// Variables, glob patterns and executables in the linter's path settings.
// No VS Code here, so that test/unit can run it with plain Node.js.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export interface Folder {
  name: string;
  path: string;
}

/** What `${...}` variables in a setting stand for */
export interface VariableContext {
  /** The workspace folders, the first being `${workspaceFolder}` unless
   * `folder` is given */
  folders: Folder[];
  /** The workspace folder of the file being linted */
  folder?: Folder;
  /** The file being linted */
  file?: string;
  env: NodeJS.ProcessEnv;
}

/** Replaces `${workspaceFolder}`, `${workspaceFolder:name}`,
 * `${workspaceFolderBasename}`, `${env:VAR}`, `${userHome}`, `${file}`,
 * `${fileDirname}`, `${fileBasename}`, `${fileBasenameNoExtension}` and a
 * leading `~`. Unknown variables are left as they are. */
export function resolveVariables(value: string, ctx: VariableContext): string {
  const folder = ctx.folder ?? ctx.folders[0];
  let out = value.replace(/\$\{([^}]+)\}/g, (whole, name: string) => {
    const [kind, arg] = splitOnce(name, ":");
    switch (kind) {
      case "workspaceFolder":
        if (arg !== undefined) {
          return ctx.folders.find((f) => f.name === arg)?.path ?? whole;
        }
        return folder?.path ?? whole;
      case "workspaceFolderBasename":
        return folder ? path.basename(folder.path) : whole;
      case "env":
        return arg !== undefined ? envValue(ctx.env, arg) : whole;
      case "userHome":
        return os.homedir();
      case "file":
        return ctx.file ?? whole;
      case "fileDirname":
        return ctx.file ? path.dirname(ctx.file) : whole;
      case "fileBasename":
        return ctx.file ? path.basename(ctx.file) : whole;
      case "fileBasenameNoExtension":
        return ctx.file ? path.parse(ctx.file).name : whole;
      default:
        return whole;
    }
  });
  if (out === "~" || out.startsWith("~/") || out.startsWith("~\\")) {
    out = os.homedir() + out.slice(1);
  }
  return out;
}

function splitOnce(s: string, sep: string): [string, string | undefined] {
  const i = s.indexOf(sep);
  return i < 0 ? [s, undefined] : [s.slice(0, i), s.slice(i + 1)];
}

/** Environment variables are case-insensitive on Windows */
function envValue(env: NodeJS.ProcessEnv, name: string): string {
  if (env[name] !== undefined) {
    return env[name] ?? "";
  }
  if (process.platform === "win32") {
    const key = Object.keys(env).find((k) => k.toLowerCase() === name.toLowerCase());
    return key ? env[key] ?? "" : "";
  }
  return "";
}

/** A path setting with its variables resolved, made absolute against `base`
 * (the workspace folder, or the file's directory) */
export function resolvePath(value: string, ctx: VariableContext, base: string): string {
  const resolved = resolveVariables(value.trim(), ctx);
  return path.resolve(base, resolved);
}

const GLOB_CHARS = /[*?[]/;
/** Directories that a `**` does not descend into */
const SKIP_DIRS = new Set([".git", "node_modules", ".svn", ".hg"]);
const MAX_DIRS = 10_000;

/** The directories matching a glob pattern (`*`, `?`, `[abc]`, `**`), or the
 * pattern itself when it has no glob characters. Only directories match:
 * include paths are directories. */
export function expandDirectoryGlob(pattern: string): string[] {
  if (!GLOB_CHARS.test(pattern)) {
    return [pattern];
  }
  const parts = pattern.split(/[\\/]+/);
  // the leading literal part: "/", "C:" or a relative start
  let i = 0;
  const literal: string[] = [];
  while (i < parts.length && !GLOB_CHARS.test(parts[i])) {
    literal.push(parts[i]);
    i++;
  }
  let root = literal.join(path.sep);
  if (root === "" && pattern.startsWith("/")) {
    root = path.sep;
  } else if (/^[A-Za-z]:$/.test(root)) {
    root += path.sep;
  }
  const found: string[] = [];
  const budget = { dirs: 0 };
  walk(root || ".", parts.slice(i), found, budget);
  return [...new Set(found)];
}

function walk(dir: string, rest: string[], found: string[], budget: { dirs: number }): void {
  if (budget.dirs++ > MAX_DIRS) {
    return;
  }
  if (rest.length === 0) {
    found.push(dir);
    return;
  }
  const [head, ...tail] = rest;
  if (head === "**") {
    // zero directories, or one more and still under **
    walk(dir, tail, found, budget);
    for (const sub of subdirectories(dir)) {
      if (!SKIP_DIRS.has(sub)) {
        walk(path.join(dir, sub), rest, found, budget);
      }
    }
    return;
  }
  if (!GLOB_CHARS.test(head)) {
    const next = path.join(dir, head);
    if (isDirectory(next)) {
      walk(next, tail, found, budget);
    }
    return;
  }
  const re = globSegment(head);
  for (const sub of subdirectories(dir)) {
    if (re.test(sub)) {
      walk(path.join(dir, sub), tail, found, budget);
    }
  }
}

/** A regular expression for one path segment of a glob */
export function globSegment(segment: string): RegExp {
  let re = "";
  for (let i = 0; i < segment.length; i++) {
    const c = segment[i];
    if (c === "*") {
      re += "[^/\\\\]*";
    } else if (c === "?") {
      re += "[^/\\\\]";
    } else if (c === "[") {
      const end = segment.indexOf("]", i + 1);
      if (end < 0) {
        re += "\\[";
      } else {
        const body = segment.slice(i + 1, end).replace(/^!/, "^").replace(/\\/g, "\\\\");
        re += `[${body}]`;
        i = end;
      }
    } else {
      re += c.replace(/[.+^${}()|\\]/g, "\\$&");
    }
  }
  return new RegExp(`^${re}$`, process.platform === "win32" ? "i" : "");
}

function subdirectories(dir: string): string[] {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name)
      .sort();
  } catch {
    return [];
  }
}

function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** The absolute path of an executable: `name` itself when it contains a
 * directory, else the first match on the PATH (with PATHEXT on Windows) */
export function findExecutable(name: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  const exts = process.platform === "win32"
    ? ["", ...(envValue(env, "PATHEXT") || ".COM;.EXE;.BAT;.CMD").split(";").filter(Boolean)]
    : [""];
  const candidates = (dir: string): string[] => exts.map((e) => path.join(dir, name + e));
  const isFile = (p: string): boolean => {
    try {
      return fs.statSync(p).isFile();
    } catch {
      return false;
    }
  };
  if (name.includes("/") || name.includes("\\")) {
    return exts.map((e) => name + e).find(isFile);
  }
  for (const dir of envValue(env, "PATH").split(path.delimiter)) {
    if (!dir) {
      continue;
    }
    const hit = candidates(dir).find(isFile);
    if (hit) {
      return hit;
    }
  }
  return undefined;
}

/** Whether two paths name the same file (case-insensitively on Windows
 * and macOS, whose file systems usually are) */
export function samePath(a: string, b: string): boolean {
  const na = path.resolve(a);
  const nb = path.resolve(b);
  return process.platform === "win32" || process.platform === "darwin"
    ? na.toLowerCase() === nb.toLowerCase()
    : na === nb;
}
