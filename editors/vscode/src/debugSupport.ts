// What the extension itself needs for debugging with zfls's debugger
// (`zfls dap`, which runs gdb and shows the program as Fortran): whether a
// gdb can serve it, to choose the debugger, and the expression under the
// mouse, for VS Code's hovers. No `vscode` import (see test/unit).

import { execFile } from "node:child_process";
import * as path from "node:path";

/** gdb's version of `gdb --version`, the end of its first line:
 * `GNU gdb (GDB) 17.2` -> [17, 2] */
export function gdbVersion(text: string): [number, number] | undefined {
  const m = /^GNU gdb\b.*\s(\d+)\.(\d+)\S*\s*$/m.exec(text.split(/\r?\n/)[0] ?? "");
  return m ? [Number(m[1]), Number(m[2])] : undefined;
}

const dapSupport = new Map<string, Promise<boolean>>();

/** Whether a gdb has the Debug Adapter Protocol: gdb 14 or later, built
 * with Python (asked once per gdb). zfls dap checks it too, and says why
 * when it has not. */
export function gdbHasDap(gdb: string): Promise<boolean> {
  let known = dapSupport.get(gdb);
  if (!known) {
    known = (async () => {
      const version = gdbVersion(await output(gdb, ["--version"]));
      if (!version || version[0] < 14) {
        return false;
      }
      // the modules its DAP needs, which another Python's library lacks
      const check = "python import json, struct, threading; print(6*7)";
      return (await output(gdb, ["-nx", "-q", "-batch", "-ex", check])).trim() === "42";
    })();
    dapSupport.set(gdb, known);
  }
  return known;
}

function output(exe: string, args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile(exe, args, { timeout: 10000, windowsHide: true, env: gdbEnv(exe, process.env) }, (error, stdout) =>
      resolve(error ? "" : stdout),
    );
  });
}

/** gdb's environment: its own directory first on the PATH. gdb's Python
 * finds its library by the `python3` on the PATH, and another one there
 * first (a virtual environment, conda, pyenv, CI's) breaks it ("No module
 * named '_struct'"); next to gdb is the one it was built with. */
export function gdbEnv(gdb: string, base: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const dir = path.isAbsolute(gdb) ? path.dirname(gdb) : undefined;
  if (!dir) {
    return base;
  }
  const key = Object.keys(base).find((k) => k.toUpperCase() === "PATH") ?? "PATH";
  const current = base[key] ?? "";
  return { ...base, [key]: current ? `${dir}${path.delimiter}${current}` : dir };
}

/** The start of the expression that ends with the name at `start`..`end`
 * of `line`: its components' parents (`p%x`, `a(i)%x`), for hovers */
export function hoverExpressionStart(line: string, start: number): number {
  let at = start;
  for (;;) {
    let i = at - 1;
    while (i >= 0 && line[i] === " ") {
      i--;
    }
    if (line[i] !== "%") {
      return at;
    }
    i--;
    while (i >= 0 && line[i] === " ") {
      i--;
    }
    // a subscript: back to its opening parenthesis
    if (line[i] === ")") {
      let depth = 0;
      for (; i >= 0; i--) {
        if (line[i] === ")") {
          depth++;
        } else if (line[i] === "(" && --depth === 0) {
          break;
        }
      }
      if (i < 0) {
        return at;
      }
      i--;
    }
    let j = i;
    while (j >= 0 && /\w/.test(line[j])) {
      j--;
    }
    if (j === i || !/[a-z]/i.test(line[j + 1])) {
      return at;
    }
    at = j + 1;
  }
}
