// The pure parts of the fpm (Fortran Package Manager) support: the targets
// of fpm.toml, the arguments of fpm commands, and reading fpm's and
// test-drive's output. No `vscode` import (see test/unit).

import * as path from "node:path";

export type TargetKind = "executable" | "test" | "example";

/** A target of the project: an executable, a test or an example */
export interface Target {
  kind: TargetKind;
  name: string;
}

/** A `[[executable]]`, `[[test]]` or `[[example]]` table of fpm.toml */
export interface ManifestTarget extends Target {
  sourceDir: string;
  main: string;
}

export interface Manifest {
  name?: string;
  targets: ManifestTarget[];
  /** `auto-executables`, `auto-tests` and `auto-examples` of `[build]` */
  auto: Record<TargetKind, boolean>;
}

/** Where fpm looks for the programs of each kind of target */
export const DEFAULT_DIRS: Record<TargetKind, string> = { executable: "app", test: "test", example: "example" };

const TABLES: Record<string, TargetKind> = { executable: "executable", test: "test", example: "example" };

/**
 * The targets of fpm.toml and its `[build]` switches. Enough of TOML for
 * them: `[[kind]]` tables of string keys, and booleans in `[build]`.
 */
export function parseManifest(text: string): Manifest {
  const manifest: Manifest = { targets: [], auto: { executable: true, test: true, example: true } };
  let table = "";
  let target: Partial<ManifestTarget> | undefined;
  const finish = (): void => {
    if (target?.kind && target.name) {
      manifest.targets.push({
        kind: target.kind,
        name: target.name,
        sourceDir: target.sourceDir ?? DEFAULT_DIRS[target.kind],
        main: target.main ?? "main.f90",
      });
    }
    target = undefined;
  };
  for (const raw of text.split(/\r?\n/)) {
    const line = stripComment(raw).trim();
    if (!line) {
      continue;
    }
    const header = /^\[\[\s*([\w-]+)\s*\]\]$/.exec(line) ?? /^\[\s*([\w.-]+)\s*\]$/.exec(line);
    if (header) {
      finish();
      table = header[1];
      if (line.startsWith("[[") && table in TABLES) {
        target = { kind: TABLES[table] };
      }
      continue;
    }
    const kv = /^([\w-]+)\s*=\s*(.+)$/.exec(line);
    if (!kv) {
      continue;
    }
    const [, key, value] = kv;
    const str = /^"([^"]*)"$|^'([^']*)'$/.exec(value);
    const text = str ? (str[1] ?? str[2]) : undefined;
    if (target) {
      if (key === "name" && text !== undefined) {
        target.name = text;
      } else if (key === "source-dir" && text !== undefined) {
        target.sourceDir = text;
      } else if (key === "main" && text !== undefined) {
        target.main = text;
      }
    } else if (table === "" && key === "name" && text !== undefined) {
      manifest.name = text;
    } else if (table === "build" && /^auto-(executables|tests|examples)$/.test(key)) {
      const kind: TargetKind = key === "auto-executables" ? "executable" : key === "auto-tests" ? "test" : "example";
      manifest.auto[kind] = value.trim() !== "false";
    }
  }
  finish();
  return manifest;
}

/** `line` without a `#` comment outside strings */
function stripComment(line: string): string {
  let quote = "";
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === quote) {
        quote = "";
      }
    } else if (c === '"' || c === "'") {
      quote = c;
    } else if (c === "#") {
      return line.slice(0, i);
    }
  }
  return line;
}

/** Whether `text` is a main program (fpm makes a target of each in `app`,
 * `test` and `example`) */
export function isProgram(text: string): boolean {
  return /^[ \t]*program[ \t]+\w+/im.test(text);
}

/**
 * The target that `file` (a main program) is the source of: a target of
 * fpm.toml whose `main` it is, else, when fpm finds targets by themselves,
 * the program in `app`, `test` or `example` (or a directory below), named
 * after the file.
 */
export function targetOfFile(
  manifest: Manifest,
  root: string,
  file: string,
  pathMod: path.PlatformPath = path,
): Target | undefined {
  const same = (a: string, b: string): boolean =>
    pathMod === path.win32 ? a.toLowerCase() === b.toLowerCase() : a === b;
  for (const t of manifest.targets) {
    if (same(pathMod.resolve(root, t.sourceDir, t.main), pathMod.resolve(file))) {
      return { kind: t.kind, name: t.name };
    }
  }
  const rel = pathMod.relative(root, file).split(pathMod.sep);
  for (const kind of Object.keys(DEFAULT_DIRS) as TargetKind[]) {
    if (manifest.auto[kind] && rel.length > 1 && same(rel[0], DEFAULT_DIRS[kind])) {
      return { kind, name: pathMod.basename(file, pathMod.extname(file)) };
    }
  }
  return undefined;
}

/** The source files that may hold the main program of `target`: its
 * `main`, or the files named after it in its kind's directory */
export function sourcesOfTarget(manifest: Manifest, target: Target): { file?: string; dir: string; stem?: string } {
  const t = manifest.targets.find((m) => m.kind === target.kind && m.name === target.name);
  if (t) {
    return { file: path.join(t.sourceDir, t.main), dir: t.sourceDir };
  }
  return { dir: DEFAULT_DIRS[target.kind], stem: target.name };
}

/** What to pass to every fpm command that builds */
export interface BuildOptions {
  /** `--profile` (`debug`, `release` or a feature profile) */
  profile?: string;
  /** `--compiler` */
  compiler?: string;
  /** `--flag`, the compiler flags */
  flags?: string;
  /** Anything else, before the command's own */
  args?: string[];
}

/** The fpm command that lists the names of the targets of a kind */
export function listArgs(kind: TargetKind): string[] {
  switch (kind) {
    case "executable":
      return ["run", "--list"];
    case "test":
      return ["test", "--list"];
    case "example":
      return ["run", "--example", "--list"];
  }
}

/** The fpm arguments that run `target` (or every target of its kind when
 * it has no name), with `programArgs` for the program after `--`, and
 * `runner` (`echo` prints the program's path) */
export function runArgs(
  target: { kind: TargetKind; name?: string },
  opts: BuildOptions,
  programArgs: readonly string[] = [],
  runner?: string,
): string[] {
  const args = [target.kind === "test" ? "test" : "run"];
  if (target.kind === "example") {
    args.push("--example");
  }
  if (target.name) {
    args.push(target.name);
  }
  args.push(...buildOptionArgs(opts));
  if (runner) {
    args.push("--runner", runner);
  }
  if (programArgs.length) {
    args.push("--", ...programArgs);
  }
  return args;
}

/** `--profile`, `--compiler` and `--flag`, then the extra arguments */
export function buildOptionArgs(opts: BuildOptions): string[] {
  const args: string[] = [];
  if (opts.profile) {
    args.push("--profile", opts.profile);
  }
  if (opts.compiler) {
    args.push("--compiler", opts.compiler);
  }
  if (opts.flags) {
    args.push("--flag", opts.flags);
  }
  return [...args, ...(opts.args ?? [])];
}

export type TaskCommand = "build" | "run" | "test" | "install" | "clean";

/** The parts of an `fpm` task definition that make its arguments */
export interface TaskSpec extends BuildOptions {
  command: TaskCommand;
  target?: string;
  /** `run --example` */
  example?: boolean;
  /** After `--`, for the program */
  programArgs?: string[];
}

/**
 * The fpm arguments of a task: what it sets of `--profile`, `--compiler`
 * and `--flag`, else `defaults` (the settings); its `args` after those of
 * the settings. `clean` deletes the build directories but not the
 * dependencies, without asking (`--skip`).
 */
export function taskArgs(spec: TaskSpec, defaults: BuildOptions): string[] {
  const opts: BuildOptions = {
    profile: spec.profile ?? defaults.profile,
    compiler: spec.compiler ?? defaults.compiler,
    flags: spec.flags ?? defaults.flags,
    args: [...(defaults.args ?? []), ...(spec.args ?? [])],
  };
  switch (spec.command) {
    case "clean":
      return ["clean", "--skip", ...(spec.args ?? [])];
    case "build":
    case "install":
      return [spec.command, ...buildOptionArgs(opts)];
    case "run":
    case "test":
      return runArgs(
        { kind: spec.command === "test" ? "test" : spec.example ? "example" : "executable", name: spec.target },
        opts,
        spec.programArgs ?? [],
      );
  }
}

/** The names that `fpm run --list` (or `test`, `--example`) prints after
 * "Matched names:" */
export function parseList(output: string): string[] {
  const at = output.indexOf("Matched names:");
  if (at < 0) {
    return [];
  }
  return output
    .slice(at + "Matched names:".length)
    .split(/\s+/)
    .filter((n) => /^[\w.+-]+$/.test(n));
}

/** The program paths that `--runner echo` prints, one per line after
 * fpm's build messages */
export function parseRunnerEcho(output: string): string[] {
  return output
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("[") && !/^Project /.test(l) && /[\\/]/.test(l) && !/\s{2}/.test(l));
}

export type TestStatus = "passed" | "failed" | "skipped" | "expected-fail" | "unexpected-pass";

/** The result of a test-drive test, from its output */
export interface TestResult {
  suite?: string;
  name: string;
  status: TestStatus;
  /** Its `Message:` lines */
  message?: string;
}

const STATUSES: Record<string, TestStatus> = {
  PASSED: "passed",
  FAILED: "failed",
  SKIPPED: "skipped",
  "EXPECTED FAIL": "expected-fail",
  "UNEXPECTED PASS": "unexpected-pass",
};

/**
 * The results test-drive prints:
 *
 * ```text
 * # Testing: math
 *   Starting adds ... (1/2)
 *        ... adds [PASSED]
 *   Starting fails ... (2/2)
 *        ... fails [FAILED]
 *   Message: math is broken
 * ```
 */
export function parseTestDrive(output: string): TestResult[] {
  const results: TestResult[] = [];
  let suite: string | undefined;
  let last: TestResult | undefined;
  for (const line of output.split(/\r?\n/)) {
    const s = /^#\s*Testing:\s*(.+?)\s*$/.exec(line);
    if (s) {
      suite = s[1];
      last = undefined;
      continue;
    }
    const r = /^\s*\.\.\.\s+(.+?)\s+\[(PASSED|FAILED|SKIPPED|EXPECTED FAIL|UNEXPECTED PASS)\]\s*$/.exec(line);
    if (r) {
      last = { suite, name: r[1], status: STATUSES[r[2]] };
      results.push(last);
      continue;
    }
    const m = /^\s*Message:\s?(.*)$/.exec(line);
    if (m && last) {
      last.message = last.message === undefined ? m[1] : `${last.message}\n${m[1]}`;
      continue;
    }
    if (/^\s*Starting\s/.test(line)) {
      last = undefined;
    }
  }
  return results;
}

/** Whether a test-drive status is a success */
export function passed(status: TestStatus): boolean {
  return status === "passed" || status === "expected-fail" || status === "skipped";
}

/** A test of test-drive in a source file, 0-based line */
export interface TestDef {
  name: string;
  line: number;
  /** The collect procedure that returns it */
  collect?: string;
}

/** A test suite of test-drive: `new_testsuite("name", collect)` */
export interface SuiteDef {
  name: string;
  collect: string;
  line: number;
}

/** The suites and tests of test-drive in `text`: `new_testsuite` and
 * `new_unittest` calls, each test with the subroutine it is in */
export function testDriveDefs(text: string): { suites: SuiteDef[]; tests: TestDef[] } {
  const suites: SuiteDef[] = [];
  const tests: TestDef[] = [];
  let sub: string | undefined;
  text.split(/\r?\n/).forEach((line, i) => {
    const code = line.replace(/!.*$/, "");
    const start = /^\s*(?:(?:pure|impure|recursive|module)\s+)*subroutine\s+(\w+)/i.exec(code);
    if (start) {
      sub = start[1].toLowerCase();
    } else if (/^\s*end\s*subroutine\b/i.test(code)) {
      sub = undefined;
    }
    for (const m of code.matchAll(/new_testsuite\s*\(\s*(["'])(.+?)\1\s*,\s*(\w+)/gi)) {
      suites.push({ name: m[2], collect: m[3].toLowerCase(), line: i });
    }
    for (const m of code.matchAll(/new_unittest\s*\(\s*(["'])(.+?)\1/gi)) {
      tests.push({ name: m[2], line: i, collect: sub });
    }
  });
  return { suites, tests };
}

/** Whether a test program takes a suite and a test on its command line, as
 * test-drive's template does (`select_suite`, `run_selected`) */
export function selectsTests(programText: string): boolean {
  return /\bselect_suite\b/i.test(programText) && /\brun_selected\b/i.test(programText);
}
