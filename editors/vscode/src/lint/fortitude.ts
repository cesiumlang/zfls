// The pure parts of linting with fortitude (zfls.fortitude.*): its
// arguments, and its JSON output read into problems with their fixes. No
// `vscode` import (see test/unit).

/** A position, 0-based, in characters of the line */
export interface Position {
  line: number;
  character: number;
}

export interface Range {
  start: Position;
  end: Position;
}

export interface Edit {
  range: Range;
  content: string;
}

export interface Fix {
  message: string;
  /** `safe`, `unsafe` or `display-only` */
  applicability: string;
  edits: Edit[];
}

export interface Problem {
  /** The rule's code, `C001` */
  code: string;
  /** The rule's name, `implicit-typing` */
  name: string;
  message: string;
  url?: string;
  range: Range;
  fix?: Fix;
}

/** How to install fortitude, for the message when it is missing */
export const INSTALL_HINT = "pip install fortitude-lint";

/** The arguments of `fortitude check` for the text of `file` on stdin */
export function fortitudeArgs(file: string, extra: readonly string[]): string[] {
  return ["check", "--output-format", "json", ...extra, "--stdin-filename", file, "-"];
}

interface RawLocation {
  row: number;
  column: number;
}

function position(loc: RawLocation | undefined): Position | undefined {
  if (!loc || typeof loc.row !== "number" || typeof loc.column !== "number") {
    return undefined;
  }
  return { line: Math.max(0, loc.row - 1), character: Math.max(0, loc.column - 1) };
}

function range(start: RawLocation | undefined, end: RawLocation | undefined): Range | undefined {
  const s = position(start);
  if (!s) {
    return undefined;
  }
  return { start: s, end: position(end) ?? s };
}

/** The problems of fortitude's JSON output; undefined when it is no JSON
 * array (fortitude failed, and said why on stderr) */
export function parseOutput(stdout: string): Problem[] | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(stdout);
  } catch {
    return undefined;
  }
  if (!Array.isArray(raw)) {
    return undefined;
  }
  const out: Problem[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const o = item as Record<string, unknown>;
    const r = range(o.location as RawLocation, o.end_location as RawLocation);
    if (!r || typeof o.message !== "string") {
      continue;
    }
    const problem: Problem = {
      code: typeof o.code === "string" ? o.code : "",
      name: typeof o.name === "string" ? o.name : "",
      message: o.message,
      range: r,
    };
    if (typeof o.url === "string") {
      // fortitude's links have a doubled slash (`.io//en/`)
      problem.url = o.url.replace(/([^:/])\/\/+/g, "$1/");
    }
    const f = o.fix as Record<string, unknown> | null | undefined;
    if (f && Array.isArray(f.edits)) {
      const edits: Edit[] = [];
      for (const e of f.edits as Record<string, unknown>[]) {
        const er = range(e.location as RawLocation, e.end_location as RawLocation);
        if (er && typeof e.content === "string") {
          edits.push({ range: er, content: e.content });
        }
      }
      if (edits.length > 0) {
        problem.fix = {
          message: typeof f.message === "string" ? f.message : `Fix ${problem.code}`,
          applicability: typeof f.applicability === "string" ? f.applicability : "unsafe",
          edits,
        };
      }
    }
    out.push(problem);
  }
  return out;
}
