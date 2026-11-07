// Running pFUnit's test programs: their commands from
// `ctest --show-only=json-v1`, their arguments, and the results a program
// writes with `-x -o FILE` (JUnit-style XML); and the tests zfls finds of
// them (`zfls/pfunitTests`). No `vscode` import (see test/unit).

import type { Located } from "./fpm";

/** A `@test` procedure of a `.pf` file, at its `@test` */
export interface PfTest extends Located {
  /** run once per parameter (`testParameters`, `cases`, `@testCase`), so
   * reported under names of its own */
  parameterized: boolean;
}

/** The suite of a `.pf` file, at its module: as pFUnit names it,
 * `@suite(name=...)`, else the module's name, else the file's, with
 * `_suite` */
export interface PfSuite extends Located {
  tests: PfTest[];
}

/** A test program of `add_pfunit_ctest`, at its name in the CMakeLists.txt */
export interface PfProgram extends Located {
  suites: PfSuite[];
}

/** The tests zfls finds (`zfls/pfunitTests`): the test programs, and the
 * suites of the `.pf` files no `add_pfunit_ctest` lists */
export interface PfunitTests {
  programs: PfProgram[];
  unlisted: PfSuite[];
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
