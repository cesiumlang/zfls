// Reading pFUnit projects: the suites and tests of `.pf` files, the test
// programs that CMake's `add_pfunit_ctest` makes of them, the programs'
// commands from `ctest --show-only=json-v1`, and the results a program
// writes with `-x -o FILE` (JUnit-style XML). No `vscode` import (see
// test/unit).

export interface PfTest {
  name: string;
  /** 0-based line of its `@test` */
  line: number;
  /** run once per parameter (`testParameters`, `cases`, `@testCase`), so
   * reported under names of its own */
  parameterized: boolean;
}

export interface PfSuite {
  /** As pFUnit names it: `@suite(name=...)`, else the module's name, else
   * the file's, with `_suite` */
  name: string;
  /** 0-based line of its `module` (or 0) */
  line: number;
  tests: PfTest[];
}

/** The suite and tests of a `.pf` file, read as funitproc reads them: the
 * first `subroutine` after each `@test` is a test */
export function parsePf(text: string, baseName: string): PfSuite {
  let suite: string | undefined;
  let module: string | undefined;
  let moduleLine = 0;
  let pending: { line: number; parameterized: boolean } | undefined;
  let caseParameterized = false;
  const tests: PfTest[] = [];
  text.split(/\r?\n/).forEach((line, i) => {
    const named = /^\s*@suite\s*\(\s*name\s*=\s*(["'])(\w+)\1\s*\)\s*$/i.exec(line);
    if (named) {
      suite = named[2];
      return;
    }
    if (/^\s*@testcase\b/i.test(line)) {
      caseParameterized = /\b(testParameters|cases)\s*=/i.test(line);
      return;
    }
    if (/^\s*@testparameter\b/i.test(line)) {
      caseParameterized = true;
      return;
    }
    const at = /^\s*@(?:mpi)?test\s*(\(.*\))?\s*$/i.exec(line);
    if (at) {
      pending = { line: i, parameterized: /\b(testParameters|cases|npes)\s*=/i.test(at[1] ?? "") };
      return;
    }
    const mod = /^\s*module\s+(\w+)\s*(!.*)?$/i.exec(line);
    if (mod && !module && !/^procedure$/i.test(mod[1])) {
      module = mod[1];
      moduleLine = i;
      return;
    }
    const sub = /^\s*subroutine\s+(\w+)/i.exec(line);
    if (sub && pending) {
      tests.push({ name: sub[1], line: pending.line, parameterized: pending.parameterized || caseParameterized });
      pending = undefined;
    }
  });
  return { name: suite ?? `${module ?? baseName}_suite`, line: module ? moduleLine : 0, tests };
}

export interface PfunitTarget {
  /** The test's name: CMake's target and CTest's test */
  name: string;
  /** The `.pf` files, as written (relative to the CMakeLists.txt's
   * directory, or absolute) */
  sources: string[];
}

const KEYWORDS = new Set([
  "TEST_SOURCES",
  "OTHER_SOURCES",
  "LINK_LIBRARIES",
  "REGISTRY",
  "EXTRA_USE",
  "EXTRA_INITIALIZE",
  "EXTRA_FINALIZE",
  "MAX_PES",
  "WORKING_DIRECTORY",
  "LABELS",
  "TIMEOUT",
  "ENV",
  "PROPERTIES",
]);

/** The `add_pfunit_ctest` calls of a CMakeLists.txt, with their
 * TEST_SOURCES; `${var}` of a plain `set(var ...)` in the same file is
 * expanded, and `${CMAKE_CURRENT_SOURCE_DIR}/` dropped */
export function parseAddPfunitCtest(cmake: string): PfunitTarget[] {
  const text = cmake.replace(/#.*$/gm, "");
  const vars = new Map<string, string[]>();
  for (const m of text.matchAll(/\bset\s*\(\s*(\w+)\s+([^)]*)\)/gi)) {
    vars.set(m[1], words(m[2]));
  }
  const expand = (w: string, depth = 0): string[] => {
    const only = /^\$\{(\w+)\}$/.exec(w);
    if (only && vars.has(only[1]) && depth < 5) {
      return vars.get(only[1])!.flatMap((v) => expand(v, depth + 1));
    }
    return [w.replace(/^\$\{CMAKE_CURRENT_(?:SOURCE|LIST)_DIR\}\//, "")];
  };
  const out: PfunitTarget[] = [];
  for (const m of text.matchAll(/\badd_pfunit_ctest\s*\(([^)]*)\)/gi)) {
    const [name, ...rest] = words(m[1]);
    if (!name) {
      continue;
    }
    const sources: string[] = [];
    let inSources = false;
    for (const w of rest) {
      if (KEYWORDS.has(w.toUpperCase())) {
        inSources = w.toUpperCase() === "TEST_SOURCES";
      } else if (inSources) {
        sources.push(...expand(w).filter((s) => /\.pf$/i.test(s)));
      }
    }
    out.push({ name, sources });
  }
  return out;
}

/** The words of CMake arguments, without quotes */
function words(args: string): string[] {
  return [...args.matchAll(/"([^"]*)"|(\S+)/g)].map((m) => m[1] ?? m[2]);
}

export interface CtestCommand {
  command: string[];
  workingDirectory?: string;
}

/** The command of each test of `ctest --show-only=json-v1` */
export function parseCtestJson(output: string): Map<string, CtestCommand> {
  const out = new Map<string, CtestCommand>();
  let data: unknown;
  try {
    data = JSON.parse(output.slice(Math.max(0, output.indexOf("{"))));
  } catch {
    return out;
  }
  const tests = (data as { tests?: unknown }).tests;
  if (!Array.isArray(tests)) {
    return out;
  }
  for (const t of tests as { name?: unknown; command?: unknown; properties?: unknown }[]) {
    if (typeof t.name !== "string" || !Array.isArray(t.command) || !t.command.length) {
      continue;
    }
    const props = Array.isArray(t.properties) ? (t.properties as { name?: unknown; value?: unknown }[]) : [];
    const wd = props.find((p) => p.name === "WORKING_DIRECTORY")?.value;
    out.set(t.name, { command: t.command.map(String), workingDirectory: typeof wd === "string" ? wd : undefined });
  }
  return out;
}

export interface PfResult {
  /** `suite.test` (with a parameter's suffix, if any) */
  name: string;
  status: "passed" | "failed" | "errored";
  /** seconds */
  time?: number;
  messages: { text: string; file?: string; line?: number }[];
}

/** The results of pFUnit's XML output (`-x`): `<testcase>` elements in a
 * `<testsuite>` each (pFUnit 4.19 on) or all in one, named `suite.test`
 * (before) */
export function parsePfunitXml(xml: string): PfResult[] {
  const out: PfResult[] = [];
  let suite = "";
  const re = /<testsuite\s[^>]*?name="([^"]*)"[^>]*>|<testcase\s([^>]*?)(\/?)>([\s\S]*?)(?=<testcase\s|<\/testsuite>|<testsuite\s|$)/g;
  for (const m of xml.matchAll(re)) {
    if (m[1] !== undefined) {
      suite = unescapeXml(m[1]);
      continue;
    }
    const attrs = m[2];
    const name = unescapeXml(/\bname="([^"]*)"/.exec(attrs)?.[1] ?? "").trim();
    if (!name) {
      continue;
    }
    const time = Number(/\btime="([^"]*)"/.exec(attrs)?.[1]);
    const body = m[3] === "/" ? "" : m[4];
    const found = [...body.matchAll(/<(failure|error)\b[^>]*?message="([^"]*)"/g)];
    const messages = found.map((f) => failureMessage(unescapeXml(f[2])));
    const status: PfResult["status"] = found.some((f) => f[1] === "failure")
      ? "failed"
      : found.length
        ? "errored"
        : "passed";
    const full = name.includes(".") || !suite ? name : `${suite}.${name}`;
    out.push({ name: full, status, time: Number.isFinite(time) ? time : undefined, messages });
  }
  return out;
}

/** `Location: [file.pf:12], message` */
function failureMessage(text: string): PfResult["messages"][number] {
  const m = /^\s*Location:\s*\[([^\]]*?)(?::(\d+))?\],?\s*([\s\S]*)$/.exec(text);
  if (!m) {
    return { text: text.trim() };
  }
  const file = m[1] && m[1] !== "<unknown location>" && m[1] !== "<unknown file>" ? m[1] : undefined;
  return { text: m[3].trim() || text.trim(), file, line: m[2] ? Number(m[2]) : undefined };
}

function unescapeXml(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCharCode(Number(n)))
    .replace(/&amp;/g, "&");
}

/** Whether a result is of a test: its name, or one of its parameters' */
export function resultOf(result: string, suite: string, test: string): boolean {
  const full = `${suite}.${test}`.toLowerCase();
  const r = result.toLowerCase();
  return r === full || (r.startsWith(full) && !/[\w]/.test(r[full.length]));
}

/** The arguments of a test program: CTest's, without `--verbose` (whose
 * lines would go into the XML file), the XML results into `xmlFile`, and
 * the one test picked, when there is one and it is not parameterized
 * (pFUnit's `-f` matches a name as a substring before 4.16, a regex on Unix
 * and a glob on Windows since: the full name matches it in each) */
export function pfunitArgs(
  ctestArgs: readonly string[],
  xmlFile: string,
  only: string | undefined,
  userArgs: readonly string[],
): string[] {
  const own = ctestArgs.filter((a) => !["-v", "-d", "--verbose", "--debug"].includes(a));
  return [...own, "-x", "-o", xmlFile, ...(only ? ["-f", only] : []), ...userArgs];
}
