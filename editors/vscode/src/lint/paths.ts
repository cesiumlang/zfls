// Variables and glob patterns in the linter's path settings. No VS Code
// here, so that test/unit can run it with plain Node.js.

import * as fs from "node:fs";
import * as path from "node:path";
import { VariableContext, expandVariables } from "../tools";

/** A path setting with its variables resolved, made absolute against `base`
 * (the workspace folder, or the file's directory) */
export function resolvePath(value: string, ctx: VariableContext, base: string): string {
  const resolved = expandVariables(value.trim(), ctx);
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

/** Whether two paths name the same file (case-insensitively on Windows
 * and macOS, whose file systems usually are) */
export function samePath(a: string, b: string): boolean {
  const na = path.resolve(a);
  const nb = path.resolve(b);
  return process.platform === "win32" || process.platform === "darwin"
    ? na.toLowerCase() === nb.toLowerCase()
    : na === nb;
}
