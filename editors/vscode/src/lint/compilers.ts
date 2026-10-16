// The compilers the linter runs: their command-line flags and parsers of
// their messages. Nothing here depends on VS Code, so that the parsers can be
// tested with plain Node.js (test/unit).
//
// The NAG severity classes and the idea of reading the Intel column off the
// caret line come from the linter of Modern Fortran (src/lint/compilers.ts,
// MIT; see THIRD_PARTY_NOTICES.md).

export type CompilerId = "gfortran" | "ifx" | "ifort" | "nagfor" | "lfortran" | "nvfortran" | "flang";

export const COMPILER_IDS: readonly CompilerId[] = [
  "gfortran", "ifx", "ifort", "nagfor", "lfortran", "nvfortran", "flang",
];

export type Severity = "error" | "warning" | "info" | "hint";

/** A further location of a message, such as flang's "Declaration of 'x'" */
export interface RelatedMessage {
  file?: string;
  line: number;
  column?: number;
  message: string;
}

/** One message of a compiler. Lines and columns count from 1; a line of 0
 * means that the message has no location (such as a bad option). */
export interface CompilerMessage {
  /** As the compiler printed it: relative to its working directory or
   * absolute; undefined when the message names no file */
  file?: string;
  line: number;
  column?: number;
  /** The last line and column of the span, inclusive (LFortran only) */
  endLine?: number;
  endColumn?: number;
  severity: Severity;
  message: string;
  code?: string;
  related: RelatedMessage[];
}

/** Options that change a compiler's command line */
export interface FlagOptions {
  /** process.platform: Intel's compilers take /options on Windows */
  platform: string;
  /** Where the compiler writes .mod (and any object) files */
  modDir: string;
}

export interface CompilerSpec {
  id: CompilerId;
  /** Executable names tried on the PATH, in order */
  executables: string[];
  /** Check the source only, writing .mod files but no object */
  syntaxOnly(o: FlagOptions): string[];
  /** Run the C-like preprocessor (fpp) on every file */
  preprocess(o: FlagOptions): string[];
  free(o: FlagOptions): string[];
  fixed(o: FlagOptions): string[];
  /** Used when `zfls.linter.extraArgs` is empty */
  defaultArgs(o: FlagOptions): string[];
  /** Write .mod files to, and read them from, `dir` */
  modOutput(dir: string, o: FlagOptions): string[];
  include(dir: string, o: FlagOptions): string[];
  parse(output: string): CompilerMessage[];
}

const windows = (o: FlagOptions): boolean => o.platform === "win32";

function lines(output: string): string[] {
  return output.split(/\r?\n/);
}

function message(
  file: string | undefined, line: number, column: number | undefined,
  severity: Severity, text: string, code?: string,
): CompilerMessage {
  return { file, line, column, severity, message: text.trim(), code, related: [] };
}

/** A message without a location from the compiler driver, such as
 * "gfortran: error: unrecognized command-line option '-Wfoo'" */
const DRIVER = /^(?<bin>[\w.+-]+(?:\.exe)?): (?<sev>fatal error|error|warning): (?<msg>.+)$/i;

function driverMessage(text: string): CompilerMessage | undefined {
  const m = DRIVER.exec(text);
  if (!m?.groups) {
    return undefined;
  }
  const sev = m.groups.sev.toLowerCase() === "warning" ? "warning" : "error";
  return message(undefined, 0, undefined, sev, `${m.groups.bin}: ${m.groups.msg}`);
}

// --- gfortran ---------------------------------------------------------------

/** `file:line:column: Severity: message`, as printed with
 * -fno-diagnostics-show-caret (or -fdiagnostics-plain-output) */
const GNU_ONE_LINE = /^(?<file>.+?):(?<ln>\d+):(?:(?<cn>\d+):)? (?<sev>Fatal Error|Error|Warning|Note|Remark): (?<msg>.*)$/;
/** The locus line of the caret format: `file:line:column:` (or with a range
 * `file:line.column-end:`), followed by the source excerpt and later by
 * `Severity: message` */
const GNU_LOCUS = /^(?<file>.+?):(?<ln>\d+)[:.](?<cn>\d+)(?:-\d+)?:$/;
const GNU_SEVERITY_LINE = /^(?<sev>Fatal Error|Error|Warning|Note|Remark): (?<msg>.*)$/;

function gnuSeverity(sev: string): Severity {
  switch (sev.toLowerCase()) {
    case "warning":
      return "warning";
    case "note":
    case "remark":
      return "info";
    default:
      return "error";
  }
}

/** Splits gfortran's trailing `[-Wflag]` off into the code */
function gnuMessage(file: string | undefined, ln: number, cn: number | undefined, sev: string, msg: string): CompilerMessage {
  const flag = /\s*\[(-W[\w=-]+)\]$/.exec(msg);
  const text = flag ? msg.slice(0, flag.index) : msg;
  return message(file, ln, cn, gnuSeverity(sev), text, flag?.[1]);
}

export function parseGfortran(output: string): CompilerMessage[] {
  const result: CompilerMessage[] = [];
  let locus: { file: string; ln: number; cn: number } | undefined;
  for (const text of lines(output)) {
    const one = GNU_ONE_LINE.exec(text);
    if (one?.groups) {
      const g = one.groups;
      result.push(gnuMessage(g.file, Number(g.ln), g.cn ? Number(g.cn) : undefined, g.sev, g.msg));
      locus = undefined;
      continue;
    }
    const at = GNU_LOCUS.exec(text);
    if (at?.groups) {
      // a second locus of the same message ("at (1) and (2)") keeps the first
      locus ??= { file: at.groups.file, ln: Number(at.groups.ln), cn: Number(at.groups.cn) };
      continue;
    }
    const sev = GNU_SEVERITY_LINE.exec(text);
    if (sev?.groups) {
      result.push(gnuMessage(locus?.file, locus?.ln ?? 0, locus?.cn, sev.groups.sev, sev.groups.msg));
      locus = undefined;
      continue;
    }
    const driver = driverMessage(text);
    if (driver) {
      result.push(driver);
    }
  }
  return result;
}

// --- Intel ifx and ifort ----------------------------------------------------

/** `file(line): error #6404: message   [NAME]`, then the source line and a
 * caret line `-----^`; fpp prints `file(line): #error: message` */
const INTEL = /^(?<file>.+?)\((?<ln>\d+)\): (?:#)?(?<sev>catastrophic error|fatal error|error|warning|remark|info)(?: #(?<code>\d+))?: (?<msg>.*)$/i;
const INTEL_CARET = /^(?<dashes>[-.]*)\^\s*$/;

function intelSeverity(sev: string): Severity {
  switch (sev.toLowerCase()) {
    case "warning":
      return "warning";
    case "remark":
    case "info":
      return "info";
    default:
      return "error";
  }
}

export function parseIntel(output: string): CompilerMessage[] {
  const result: CompilerMessage[] = [];
  const all = lines(output);
  for (let i = 0; i < all.length; i++) {
    const m = INTEL.exec(all[i]);
    if (!m?.groups) {
      const driver = /^(?:ifx|ifort|icx)(?:\.exe)?: (?:command line )?(?<sev>error|warning) #\d+: (?<msg>.+)$/i.exec(all[i]);
      if (driver?.groups) {
        result.push(message(undefined, 0, undefined, intelSeverity(driver.groups.sev), all[i]));
      }
      continue;
    }
    const g = m.groups;
    let column: number | undefined;
    // the source line and the caret line follow the message
    for (let j = i + 1; j <= i + 2 && j < all.length; j++) {
      const caret = INTEL_CARET.exec(all[j]);
      if (caret?.groups) {
        column = caret.groups.dashes.length + 1;
        break;
      }
      if (INTEL.test(all[j])) {
        break;
      }
    }
    result.push(message(g.file, Number(g.ln), column, intelSeverity(g.sev), g.msg, g.code));
  }
  return result;
}

// --- NAG nagfor -------------------------------------------------------------

/** `Severity: file, line N: message`; severities from section 7 of the
 * nagfor manual. A `detected at` line can follow (NAG 7). */
const NAG = /^(?<sev>Remark|Info|Note|Warning|Questionable|Extension|Obsolescent|Deleted feature used|(?:\w+ )?Error|Fatal(?: Error)?|Panic)(?:\([^)]*\))?: (?<file>.+?), lines? (?<ln>\d+)(?:-\d+)?: (?<msg>.*)$/;
const NAG_NO_FILE = /^(?<sev>Fatal Error|Fatal|Panic|Error): (?<msg>.*)$/;

function nagSeverity(sev: string): Severity {
  const s = sev.toLowerCase();
  if (s === "remark" || s === "info" || s === "note") {
    return "info";
  }
  if (s === "warning" || s === "questionable" || s === "extension" || s === "obsolescent" || s === "deleted feature used") {
    return "warning";
  }
  return "error";
}

export function parseNag(output: string): CompilerMessage[] {
  const result: CompilerMessage[] = [];
  for (const text of lines(output)) {
    const m = NAG.exec(text);
    if (m?.groups) {
      const g = m.groups;
      result.push(message(g.file, Number(g.ln), undefined, nagSeverity(g.sev), g.msg));
      continue;
    }
    const detected = /^\s+detected at (.+)$/.exec(text);
    if (detected && result.length > 0) {
      result[result.length - 1].message += ` (detected at ${detected[1]})`;
      continue;
    }
    const bare = NAG_NO_FILE.exec(text);
    if (bare?.groups) {
      result.push(message(undefined, 0, undefined, nagSeverity(bare.groups.sev), bare.groups.msg));
    }
  }
  return result;
}

// --- LFortran ---------------------------------------------------------------

/** `--error-format=short`: `file:line-endline:col-endcol: severity [code]: message`,
 * or without a location `severity: message` (src/libasr/diagnostics.cpp) */
const LFORTRAN = /^(?:(?<file>.+?):(?<ls>\d+)-(?<le>\d+):(?<cs>\d+)-(?<ce>\d+): )?(?<sev>(?:[\w ]*error)|warning|note|help|style suggestion)(?: \[(?<code>[^\]]+)\])?: (?<msg>.*)$/;

function lfortranSeverity(sev: string): Severity {
  if (sev === "warning") {
    return "warning";
  }
  if (sev === "note") {
    return "info";
  }
  if (sev === "help" || sev === "style suggestion") {
    return "hint";
  }
  return "error";
}

export function parseLfortran(output: string): CompilerMessage[] {
  const result: CompilerMessage[] = [];
  for (const text of lines(output)) {
    const m = LFORTRAN.exec(text);
    if (!m?.groups) {
      continue;
    }
    const g = m.groups;
    const msg = message(g.file, g.ls ? Number(g.ls) : 0, g.cs ? Number(g.cs) : undefined,
      lfortranSeverity(g.sev), g.msg, g.code);
    if (g.le) {
      msg.endLine = Number(g.le);
      msg.endColumn = Number(g.ce);
    }
    result.push(msg);
  }
  return result;
}

// --- NVIDIA nvfortran -------------------------------------------------------

/** `NVFORTRAN-S-0034-Syntax error at or near end of line (file.f90: 3)`;
 * severities I(nformative), W(arning), S(evere), F(atal). Older releases
 * print PGF90- or PGFTN- instead of NVFORTRAN-. */
const NVFORTRAN = /^(?:NVFORTRAN|PGF90|PGFTN)-(?<sev>[IWSFV])-(?<code>\d+)-(?<msg>.*?)(?: \((?<file>[^()]+?): ?(?<ln>\d+)(?:[:.] ?(?<cn>\d+))?\))?\s*$/;

export function parseNvfortran(output: string): CompilerMessage[] {
  const result: CompilerMessage[] = [];
  for (const text of lines(output)) {
    const m = NVFORTRAN.exec(text);
    if (!m?.groups) {
      continue;
    }
    const g = m.groups;
    const severity: Severity = g.sev === "W" ? "warning" : g.sev === "I" ? "info" : "error";
    result.push(message(g.file, g.ln ? Number(g.ln) : 0, g.cn ? Number(g.cn) : undefined,
      severity, g.msg, g.code));
  }
  return result;
}

// --- LLVM flang -------------------------------------------------------------

/** `file:line:column: severity: message`, as clang; flang adds context
 * lines without a severity (`file:line:column: Declaration of 'x'`), which
 * belong to the message before them */
const FLANG = /^(?<file>.+?):(?<ln>\d+):(?<cn>\d+): (?:(?<sev>fatal error|error|warning|portability|note|remark|because): )?(?<msg>.*)$/;

function flangSeverity(sev: string | undefined): Severity | undefined {
  switch (sev) {
    case "error":
    case "fatal error":
      return "error";
    case "warning":
    case "portability":
      return "warning";
    case "remark":
      return "info";
    default:
      // a note, a "because" or a context line: related to the message before
      return undefined;
  }
}

export function parseFlang(output: string): CompilerMessage[] {
  const result: CompilerMessage[] = [];
  for (const text of lines(output)) {
    const m = FLANG.exec(text);
    if (m?.groups) {
      const g = m.groups;
      const severity = flangSeverity(g.sev);
      const ln = Number(g.ln);
      const cn = Number(g.cn);
      const msg = g.sev === "portability" ? `portability: ${g.msg}` : g.msg;
      if (severity) {
        result.push(message(g.file, ln, cn, severity, msg));
      } else if (result.length > 0) {
        result[result.length - 1].related.push({ file: g.file, line: ln, column: cn, message: g.msg.trim() });
      }
      continue;
    }
    // "error: Semantic errors in x.f90" repeats the messages above it
    if (/^error: (?:Semantic errors in|Could not scan) /.test(text)) {
      continue;
    }
    const driver = driverMessage(text) ?? (/^error: /.test(text)
      ? message(undefined, 0, undefined, "error", text.slice("error: ".length))
      : undefined);
    if (driver) {
      result.push(driver);
    }
  }
  return result;
}

// --- the compilers ----------------------------------------------------------

const gnuForm = { free: ["-ffree-form"], fixed: ["-ffixed-form"] };

export const COMPILERS: Record<CompilerId, CompilerSpec> = {
  gfortran: {
    id: "gfortran",
    executables: ["gfortran"],
    // -fno-diagnostics-show-caret puts each message on one line (GCC 4.9+;
    // -fdiagnostics-plain-output needs GCC 11)
    syntaxOnly: () => ["-fsyntax-only", "-fno-diagnostics-show-caret", "-fdiagnostics-color=never"],
    preprocess: () => ["-cpp"],
    free: () => gnuForm.free,
    fixed: () => gnuForm.fixed,
    defaultArgs: () => ["-Wall"],
    modOutput: (dir) => [`-J${dir}`],
    include: (dir) => [`-I${dir}`],
    parse: parseGfortran,
  },
  ifx: intel("ifx"),
  ifort: intel("ifort"),
  nagfor: {
    id: "nagfor",
    executables: ["nagfor"],
    // -M: produce .mod files only; -quiet: no banner and summary line
    syntaxOnly: () => ["-M", "-quiet"],
    preprocess: () => ["-fpp"],
    free: () => ["-free"],
    fixed: () => ["-fixed"],
    defaultArgs: () => [],
    // -mdir only writes there; -I also reads from there
    modOutput: (dir) => ["-mdir", dir, "-I", dir],
    include: (dir) => ["-I", dir],
    parse: parseNag,
  },
  lfortran: {
    id: "lfortran",
    executables: ["lfortran"],
    syntaxOnly: () => ["--semantics-only", "--error-format=short", "--no-color"],
    preprocess: () => ["--cpp"],
    free: () => [],
    fixed: () => ["--fixed-form"],
    defaultArgs: () => [],
    modOutput: (dir) => ["-J", dir, "-I", dir],
    include: (dir) => [`-I${dir}`],
    parse: parseLfortran,
  },
  nvfortran: {
    id: "nvfortran",
    executables: ["nvfortran"],
    // nvfortran has no syntax-only mode: compile, with the object file next
    // to the .mod files rather than in the source tree
    syntaxOnly: (o) => ["-c", "-o", joinPath(o.modDir, "zfls-lint.o", o.platform)],
    preprocess: () => ["-Mpreprocess"],
    free: () => ["-Mfree"],
    fixed: () => ["-Mfixed"],
    defaultArgs: () => ["-Minform=warn"],
    modOutput: (dir) => ["-module", dir],
    include: (dir) => [`-I${dir}`],
    parse: parseNvfortran,
  },
  flang: {
    id: "flang",
    // LLVM 20 renamed flang-new to flang
    executables: ["flang", "flang-new"],
    syntaxOnly: () => ["-fsyntax-only", "-fno-color-diagnostics"],
    preprocess: () => ["-cpp"],
    free: () => gnuForm.free,
    fixed: () => gnuForm.fixed,
    defaultArgs: () => [],
    modOutput: (dir) => ["-module-dir", dir],
    include: (dir) => [`-I${dir}`],
    parse: parseFlang,
  },
};

function intel(id: "ifx" | "ifort"): CompilerSpec {
  // the Windows spellings of the same options
  return {
    id,
    executables: [id],
    syntaxOnly: (o) => (windows(o) ? ["/nologo", "/syntax-only"] : ["-syntax-only"]),
    preprocess: (o) => (windows(o) ? ["/fpp"] : ["-fpp"]),
    free: (o) => (windows(o) ? ["/free"] : ["-free"]),
    fixed: (o) => (windows(o) ? ["/fixed"] : ["-fixed"]),
    defaultArgs: (o) => (windows(o) ? ["/warn:all"] : ["-warn", "all"]),
    modOutput: (dir, o) => (windows(o) ? [`/module:${dir}`] : ["-module", dir]),
    include: (dir, o) => (windows(o) ? [`/I${dir}`] : [`-I${dir}`]),
    parse: parseIntel,
  };
}

function joinPath(dir: string, name: string, platform: string): string {
  const sep = platform === "win32" ? "\\" : "/";
  return dir.endsWith("/") || dir.endsWith("\\") ? dir + name : dir + sep + name;
}

export function isCompilerId(id: string): id is CompilerId {
  return (COMPILER_IDS as readonly string[]).includes(id);
}

/** The diagnostics of one run, without repeats (a compiler can report the
 * same problem twice, for instance once per included copy) */
export function dedupe(messages: CompilerMessage[]): CompilerMessage[] {
  const seen = new Set<string>();
  return messages.filter((m) => {
    const key = [m.file ?? "", m.line, m.column ?? "", m.severity, m.message].join("\u0000");
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}
