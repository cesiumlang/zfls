// Reading Codee's output (zfls.codee.*): `codee checks --json` reports a
// `Checks` list whose items have a `Check` (PWR068, PWD002, RMK010, ...), a
// `Location` (`file:line:column`), a `Title` and a `Suggestion`, as Codee's
// documentation of its Neovim integration reads them. Codee is a
// commercial tool that zfls has not been tested with: this follows its
// documentation, best-effort. No `vscode` import (see test/unit).

export interface CodeeCheck {
  code: string;
  /** As Codee gives it, relative to its working directory or absolute */
  file: string;
  /** 0-based */
  line: number;
  character: number;
  message: string;
  severity: "error" | "warning" | "hint";
  url?: string;
}

/** The arguments of `codee checks` for `file`: `--json`, the user's, then
 * the file, unless the user's name it as `${file}` (before `--` and a
 * compile command, for instance) */
export function codeeArgs(file: string, userArgs: readonly string[]): string[] {
  const named = userArgs.some((a) => a.includes("${file}"));
  const args = userArgs.map((a) => a.split("${file}").join(file));
  return ["checks", "--json", ...args, ...(named ? [] : [file])];
}

/** The severity of a check from its kind: PWD (defects) are errors, PWR
 * (recommendations) warnings, RMK (remarks) hints, as in Codee's own
 * editor integrations */
export function codeeSeverity(code: string): CodeeCheck["severity"] {
  if (/^PWD\d/.test(code)) return "error";
  if (/^RMK\d/.test(code)) return "hint";
  return "warning";
}

/** The page of a check in Codee's Open Catalog */
export function checkUrl(code: string): string | undefined {
  return /^(PWD|PWR|RMK)\d{3}$/.test(code) ? `https://open-catalog.codee.com/Checks/${code}/` : undefined;
}

/** The checks of Codee's JSON output; undefined when it is not that */
export function parseCodee(output: string): CodeeCheck[] | undefined {
  let data: unknown;
  try {
    // anything Codee prints before its report (a banner, a license notice)
    const start = output.indexOf("{");
    data = JSON.parse(start > 0 ? output.slice(start) : output);
  } catch {
    return undefined;
  }
  const checks = (data as { Checks?: unknown }).Checks;
  if (!Array.isArray(checks)) {
    return undefined;
  }
  const out: CodeeCheck[] = [];
  for (const c of checks as Record<string, unknown>[]) {
    const where = /^(.+):(\d+):(\d+)$/.exec(String(c.Location ?? ""));
    if (!where) {
      continue;
    }
    const code = String(c.Check ?? "");
    const title = String(c.Title ?? "").trim();
    const suggestion = String(c.Suggestion ?? "").trim();
    out.push({
      code,
      file: where[1],
      line: Math.max(0, Number(where[2]) - 1),
      character: Math.max(0, Number(where[3]) - 1),
      message: suggestion ? `${title}\n${suggestion}` : title,
      severity: codeeSeverity(code),
      url: checkUrl(code),
    });
  }
  return out;
}
