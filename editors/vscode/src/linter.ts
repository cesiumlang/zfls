// Compiler diagnostics: compiles a Fortran file with a compiler's
// syntax-only mode and shows the compiler's errors and warnings in the
// file, in a diagnostic collection of their own (beside those of zfls).
//
// Compiler runs go one at a time. A run is debounced per file, and a newer
// request for the same file stops the older run (and kills its compiler),
// so that saving often (autosave) does not start a compiler per save.

import * as cp from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  COMPILERS,
  CompilerMessage,
  CompilerSpec,
  FlagOptions,
  Severity,
  dedupe,
  isCompilerId,
} from "./lint/compilers";
import {
  Folder,
  VariableContext,
  expandDirectoryGlob,
  findExecutable,
  resolvePath,
  resolveVariables,
  samePath,
} from "./lint/paths";
import { findIncludes, scanModules } from "./lint/sources";

const LANGUAGES = new Set(["FortranFreeForm", "FortranFixedForm"]);
/** The extensions of package.json's FortranFixedForm language, for files
 * compiled without being open */
const FIXED_FORM = new Set([".f", ".f77", ".for"]);
/** Every Fortran extension of package.json, both cases */
const FORTRAN_GLOB =
  "**/*.{f90,F90,f95,F95,f03,F03,f08,F08,f18,F18,fpp,FPP,pf,PF,fypp,FYPP,f,F,f77,F77,for,FOR}";
/** Debounce of runs on open and save */
const SAVE_DELAY_MS = 250;
const TIMEOUT_MS = 60_000;
/** How deep USE chains are followed to build the modules a file needs */
const MAX_DEPTH = 8;
const MAX_INDEXED_FILES = 20_000;

interface FyppSettings {
  enabled: boolean;
  path: string;
  definitions: Record<string, string>;
  includes: string[];
  extraArgs: string[];
}

interface Settings {
  compiler: string;
  compilerPath: string;
  extraArgs: string[];
  includePaths: string[];
  modOutput: string;
  lintOnSave: boolean;
  lintOnType: boolean;
  lintOnTypeDelay: number;
  resolveModules: boolean;
  fypp: FyppSettings;
}

/** Everything a compiler run of one file needs, resolved */
interface Job {
  settings: Settings;
  spec: CompilerSpec;
  exe: string;
  modDir: string;
  includes: string[];
  flags: FlagOptions;
  vars: VariableContext;
  base: string;
  env: NodeJS.ProcessEnv;
}

/** The file handed to the compiler, and the names under which its messages
 * may refer to the file being linted */
interface Source {
  path: string;
  cwd: string;
  aliases: string[];
  /** Directories to search for INCLUDE files when the source is a copy */
  extraIncludes: string[];
}

interface RunResult {
  code: number | null;
  output: string;
}

function readSettings(uri?: vscode.Uri): Settings {
  const c = vscode.workspace.getConfiguration("zfls.linter", uri);
  return {
    compiler: c.get<string>("compiler", "gfortran"),
    compilerPath: c.get<string>("compilerPath", ""),
    extraArgs: c.get<string[]>("extraArgs", []),
    includePaths: c.get<string[]>("includePaths", []),
    modOutput: c.get<string>("modOutput", ""),
    lintOnSave: c.get<boolean>("lintOnSave", true),
    lintOnType: c.get<boolean>("lintOnType", false),
    lintOnTypeDelay: c.get<number>("lintOnTypeDelay", 1000),
    resolveModules: c.get<boolean>("resolveModules", true),
    fypp: {
      enabled: c.get<boolean>("fypp.enabled", false),
      path: c.get<string>("fypp.path", "fypp"),
      definitions: c.get<Record<string, string>>("fypp.definitions", {}),
      includes: c.get<string[]>("fypp.includes", []),
      extraArgs: c.get<string[]>("fypp.extraArgs", []),
    },
  };
}

function severity(s: Severity): vscode.DiagnosticSeverity {
  switch (s) {
    case "error":
      return vscode.DiagnosticSeverity.Error;
    case "warning":
      return vscode.DiagnosticSeverity.Warning;
    case "info":
      return vscode.DiagnosticSeverity.Information;
    default:
      return vscode.DiagnosticSeverity.Hint;
  }
}

function hash(s: string): string {
  return crypto.createHash("sha1").update(s).digest("hex").slice(0, 12);
}

function mtime(file: string): number | undefined {
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return undefined;
  }
}

/** `env` with `name` set, whatever the case of its key (Windows has Path) */
function setEnv(env: NodeJS.ProcessEnv, name: string, value: string): void {
  const key = Object.keys(env).find((k) => k.toLowerCase() === name.toLowerCase()) ?? name;
  env[key] = value;
}

function getEnv(env: NodeJS.ProcessEnv, name: string): string {
  const key = Object.keys(env).find((k) => k.toLowerCase() === name.toLowerCase());
  return key ? env[key] ?? "" : "";
}

export class Linter implements vscode.Disposable {
  private readonly collection = vscode.languages.createDiagnosticCollection("zfls-compiler");
  private readonly timers = new Map<string, NodeJS.Timeout>();
  /** The run requested last for each file; aborting it kills its compiler */
  private readonly runs = new Map<string, AbortController>();
  private queue: Promise<void> = Promise.resolve();
  private readonly notified = new Set<string>();
  private readonly globCache = new Map<string, string[]>();
  /** Module name to the workspace file defining it, built when first needed */
  private index: Promise<Map<string, string>> | undefined;
  /** File (per module directory) to the modification time it was compiled at */
  private readonly compiled = new Map<string, number>();
  private readonly disposables: vscode.Disposable[] = [];

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly log: vscode.LogOutputChannel,
  ) {}

  activate(): void {
    const watcher = vscode.workspace.createFileSystemWatcher(FORTRAN_GLOB);
    this.disposables.push(
      this.collection,
      watcher,
      watcher.onDidCreate((uri) => void this.reindex(uri.fsPath)),
      watcher.onDidChange((uri) => void this.reindex(uri.fsPath)),
      watcher.onDidDelete((uri) => void this.reindex(uri.fsPath)),
      vscode.commands.registerCommand("zfls.linter.lint", () => this.lintActive()),
      vscode.commands.registerCommand("zfls.linter.clear", () => this.clear()),
      vscode.workspace.onDidOpenTextDocument((doc) => this.request(doc, SAVE_DELAY_MS)),
      vscode.workspace.onDidSaveTextDocument((doc) => {
        if (readSettings(doc.uri).lintOnSave) {
          this.request(doc, SAVE_DELAY_MS);
          this.requestUsers(doc);
        }
      }),
      vscode.workspace.onDidChangeTextDocument((e) => {
        const settings = readSettings(e.document.uri);
        if (settings.lintOnType && e.contentChanges.length > 0) {
          this.request(e.document, Math.max(0, settings.lintOnTypeDelay));
        }
      }),
      vscode.workspace.onDidCloseTextDocument((doc) => this.forget(doc.uri)),
      vscode.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration("zfls.linter")) {
          this.reset();
          vscode.workspace.textDocuments.forEach((doc) => this.request(doc, SAVE_DELAY_MS));
        }
      }),
    );
    vscode.workspace.textDocuments.forEach((doc) => this.request(doc, SAVE_DELAY_MS));
  }

  dispose(): void {
    this.cancelAll();
    this.disposables.forEach((d) => d.dispose());
  }

  // --- scheduling -----------------------------------------------------------

  private wanted(doc: vscode.TextDocument): boolean {
    if (doc.uri.scheme !== "file" || !LANGUAGES.has(doc.languageId)) {
      return false;
    }
    const settings = readSettings(doc.uri);
    if (!isCompilerId(settings.compiler)) {
      return false;
    }
    // without fypp the compiler cannot read fypp's directives
    return settings.fypp.enabled || path.extname(doc.fileName).toLowerCase() !== ".fypp";
  }

  /** Lints `doc` after `delay` ms, unless asked again before then */
  private request(doc: vscode.TextDocument, delay: number): void {
    if (!this.wanted(doc)) {
      return;
    }
    const key = doc.uri.toString();
    clearTimeout(this.timers.get(key));
    this.timers.set(key, setTimeout(() => {
      this.timers.delete(key);
      this.enqueue(doc);
    }, delay));
  }

  /** Queues a run of `doc`, stopping the one queued or running before */
  private enqueue(doc: vscode.TextDocument): Promise<void> {
    const key = doc.uri.toString();
    this.runs.get(key)?.abort();
    const run = new AbortController();
    this.runs.set(key, run);
    this.queue = this.queue.then(async () => {
      try {
        await this.lint(doc, run.signal);
      } catch (err) {
        if (!run.signal.aborted) {
          this.log.error(`[lint] ${doc.fileName}: ${String(err)}`);
        }
      } finally {
        if (this.runs.get(key) === run) {
          this.runs.delete(key);
        }
      }
    });
    return this.queue;
  }

  /** Lints again the open files that use a module `doc` defines, after
   * `doc` (whose run rebuilds the module) */
  private requestUsers(doc: vscode.TextDocument): void {
    if (!readSettings(doc.uri).resolveModules) {
      return;
    }
    const defines = new Set(scanModules(doc.getText()).defines);
    if (defines.size === 0) {
      return;
    }
    for (const other of vscode.workspace.textDocuments) {
      if (other !== doc && this.wanted(other) && scanModules(other.getText()).uses.some((u) => defines.has(u))) {
        this.request(other, SAVE_DELAY_MS);
      }
    }
  }

  private forget(uri: vscode.Uri): void {
    const key = uri.toString();
    clearTimeout(this.timers.get(key));
    this.timers.delete(key);
    this.runs.get(key)?.abort();
    this.runs.delete(key);
    this.collection.delete(uri);
  }

  private cancelAll(): void {
    this.timers.forEach((t) => clearTimeout(t));
    this.timers.clear();
    this.runs.forEach((r) => r.abort());
    this.runs.clear();
  }

  /** After a settings change: nothing of the old settings stays */
  private reset(): void {
    this.cancelAll();
    this.collection.clear();
    this.globCache.clear();
    this.compiled.clear();
  }

  // --- commands -------------------------------------------------------------

  private async lintActive(): Promise<void> {
    const doc = vscode.window.activeTextEditor?.document;
    if (!doc || doc.uri.scheme !== "file" || !LANGUAGES.has(doc.languageId)) {
      void vscode.window.showInformationMessage("zfls: open a Fortran file to lint it.");
      return;
    }
    if (!isCompilerId(readSettings(doc.uri).compiler)) {
      void vscode.window.showInformationMessage(
        "zfls: compiler diagnostics are off; choose a compiler in zfls.linter.compiler.");
      return;
    }
    await this.enqueue(doc);
  }

  /** Clears the diagnostics and the .mod files of the default module
   * directory (a configured zfls.linter.modOutput is left alone) */
  private async clear(): Promise<void> {
    this.reset();
    this.index = undefined;
    await this.queue;
    try {
      await fs.promises.rm(this.storageDir(), { recursive: true, force: true });
    } catch (err) {
      this.log.warn(`[lint] cannot remove ${this.storageDir()}: ${String(err)}`);
    }
  }

  // --- a run ----------------------------------------------------------------

  private async lint(doc: vscode.TextDocument, signal: AbortSignal): Promise<void> {
    if (signal.aborted || doc.isClosed) {
      return;
    }
    const job = this.prepare(doc.uri);
    if (!job) {
      return;
    }
    const file = doc.uri.fsPath;
    if (job.settings.resolveModules) {
      await this.buildDependencies(file, doc.getText(), job, signal, new Set([file]), 0);
    }
    const stamp = doc.isDirty ? undefined : mtime(file);
    const source = await this.sourceFor(file, doc.isDirty ? doc.getText() : undefined, job, signal);
    if (!source || signal.aborted) {
      return;
    }
    const result = await this.compile(source, doc.languageId === "FortranFixedForm", job, signal);
    if (!result || signal.aborted || doc.isClosed) {
      return;
    }
    if (stamp !== undefined) {
      this.compiled.set(this.compiledKey(job, file), stamp);
    }
    const messages = dedupe(job.spec.parse(result.output));
    this.collection.set(doc.uri, this.toDiagnostics(doc, messages, source, job));
  }

  /** Resolves the settings of the file's folder; undefined (after telling
   * the user once) when the compiler is not found */
  private prepare(uri: vscode.Uri): Job | undefined {
    const settings = readSettings(uri);
    if (!isCompilerId(settings.compiler)) {
      return undefined;
    }
    const spec = COMPILERS[settings.compiler];
    const vars = this.variables(uri);
    const base = vars.folder?.path ?? path.dirname(uri.fsPath);
    const exe = this.executable(settings, spec, vars, base);
    if (!exe) {
      void this.notifyMissing(settings.compilerPath || spec.executables[0], "compilerPath");
      return undefined;
    }
    const modDir = settings.modOutput
      ? resolvePath(settings.modOutput, vars, base)
      : path.join(this.storageDir(), spec.id);
    fs.mkdirSync(modDir, { recursive: true });
    const flags: FlagOptions = { platform: process.platform, modDir };
    const env: NodeJS.ProcessEnv = { ...process.env, LC_ALL: "C" };
    // the compiler's own directory first: MinGW's gfortran needs its DLLs
    setEnv(env, "PATH", path.dirname(exe) + path.delimiter + getEnv(env, "PATH"));
    const includes = this.globs(settings.includePaths, vars, base);
    return { settings, spec, exe, modDir, includes, flags, vars, base, env };
  }

  private storageDir(): string {
    return path.join((this.context.storageUri ?? this.context.globalStorageUri).fsPath, "lint");
  }

  private variables(uri: vscode.Uri): VariableContext {
    const toFolder = (f: vscode.WorkspaceFolder): Folder => ({ name: f.name, path: f.uri.fsPath });
    const own = vscode.workspace.getWorkspaceFolder(uri);
    return {
      folders: (vscode.workspace.workspaceFolders ?? []).map(toFolder),
      folder: own ? toFolder(own) : undefined,
      file: uri.fsPath,
      env: process.env,
    };
  }

  private executable(settings: Settings, spec: CompilerSpec, vars: VariableContext, base: string): string | undefined {
    if (settings.compilerPath) {
      const p = resolveVariables(settings.compilerPath.trim(), vars);
      const hasDir = p.includes("/") || p.includes("\\");
      return findExecutable(hasDir ? path.resolve(base, p) : p);
    }
    for (const name of spec.executables) {
      const found = findExecutable(name);
      if (found) {
        return found;
      }
    }
    return undefined;
  }

  /** Include directories, with variables resolved and globs expanded */
  private globs(patterns: string[], vars: VariableContext, base: string): string[] {
    const resolved = patterns.filter((p) => p.trim()).map((p) => resolvePath(p, vars, base));
    const key = resolved.join("\u0000");
    let dirs = this.globCache.get(key);
    if (!dirs) {
      dirs = [...new Set(resolved.flatMap(expandDirectoryGlob))];
      this.globCache.set(key, dirs);
      this.log.debug(`[lint] include paths: ${dirs.join(", ")}`);
    }
    return dirs;
  }

  /** Once a session for each executable */
  private async notifyMissing(name: string, setting: string): Promise<void> {
    if (this.notified.has(name)) {
      return;
    }
    this.notified.add(name);
    this.log.warn(`[lint] ${name} not found; no compiler diagnostics`);
    const open = "Open Settings";
    const off = "Turn Off";
    const choice = await vscode.window.showInformationMessage(
      `zfls: ${name} was not found, so Fortran files are not checked with a compiler. ` +
        `Set zfls.linter.${setting}, choose another zfls.linter.compiler, or turn compiler diagnostics off.`,
      open,
      off,
    );
    if (choice === open) {
      await vscode.commands.executeCommand("workbench.action.openSettings", "zfls.linter");
    } else if (choice === off) {
      await vscode.workspace.getConfiguration("zfls.linter")
        .update("compiler", "Disabled", vscode.ConfigurationTarget.Global);
    }
  }

  /** The file to compile: the file itself, a copy of unsaved text, and
   * either one run through fypp when that is on */
  private async sourceFor(file: string, unsaved: string | undefined, job: Job, signal: AbortSignal): Promise<Source | undefined> {
    const cwd = path.dirname(file);
    const source: Source = { path: file, cwd, aliases: [file], extraIncludes: [] };
    if (unsaved !== undefined) {
      const copy = path.join(this.storageDir(), "unsaved", hash(file), path.basename(file));
      await fs.promises.mkdir(path.dirname(copy), { recursive: true });
      await fs.promises.writeFile(copy, unsaved);
      source.path = copy;
      source.aliases.push(copy);
      source.extraIncludes.push(cwd);
    }
    if (job.settings.fypp.enabled) {
      const out = await this.fypp(source, FIXED_FORM.has(path.extname(file).toLowerCase()), job, signal);
      if (!out) {
        return undefined;
      }
      source.aliases.push(out);
      source.path = out;
      if (!source.extraIncludes.includes(cwd)) {
        source.extraIncludes.push(cwd);
      }
    }
    return source;
  }

  /** Runs fypp on the source, with line markers naming the original file;
   * returns the output file, or undefined when fypp failed (its message is
   * then shown in the file) */
  private async fypp(source: Source, fixed: boolean, job: Job, signal: AbortSignal): Promise<string | undefined> {
    const fy = job.settings.fypp;
    const p = resolveVariables(fy.path.trim() || "fypp", job.vars);
    const exe = findExecutable(p.includes("/") || p.includes("\\") ? path.resolve(job.base, p) : p);
    if (!exe) {
      void this.notifyMissing(fy.path || "fypp", "fypp.path");
      return undefined;
    }
    const stem = path.parse(source.aliases[0]).name;
    const out = path.join(this.storageDir(), "fypp", hash(source.aliases[0]), stem + (fixed ? ".f" : ".f90"));
    await fs.promises.mkdir(path.dirname(out), { recursive: true });
    const args = [
      "--line-numbering",
      "--line-marker-format=cpp",
      ...(fixed ? ["--fixed-format"] : []),
      ...this.globs(fy.includes, job.vars, job.base).map((d) => `-I${d}`),
      ...Object.entries(fy.definitions).map(([k, v]) => (v ? `-D${k}=${v}` : `-D${k}`)),
      ...fy.extraArgs.map((a) => resolveVariables(a, job.vars)),
      // forward slashes: the path goes into the line markers, where a
      // backslash would be an escape
      source.path.replace(/\\/g, "/"),
      out,
    ];
    const result = await this.run(exe, args, source.cwd, job.env, signal);
    if (!result || result.code === 0) {
      return result ? out : undefined;
    }
    this.log.debug(`[lint] fypp failed:\n${result.output}`);
    // shown in the file, if it is open (not for a module built for another)
    const uri = vscode.Uri.file(source.aliases[0]);
    if (!vscode.workspace.textDocuments.some((d) => d.uri.toString() === uri.toString())) {
      return undefined;
    }
    const m = /^(?<file>.+?):(?<ln>\d+)(?:-\d+)?: (?:error: )?(?<msg>.+)$/m.exec(result.output);
    const line = m?.groups ? Math.max(0, Number(m.groups.ln) - 1) : 0;
    const text = m?.groups?.msg ?? (result.output.trim().split(/\r?\n/).pop() || "fypp failed");
    const d = new vscode.Diagnostic(new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER), text);
    d.source = "fypp";
    this.collection.set(uri, [d]);
    return undefined;
  }

  private async compile(source: Source, fixed: boolean, job: Job, signal: AbortSignal): Promise<RunResult | undefined> {
    const { spec, flags, settings } = job;
    const extra = settings.extraArgs.length > 0
      ? settings.extraArgs.map((a) => resolveVariables(a, job.vars))
      : spec.defaultArgs(flags);
    const args = [
      ...spec.syntaxOnly(flags),
      ...spec.preprocess(flags),
      ...(fixed ? spec.fixed(flags) : spec.free(flags)),
      ...extra,
      ...spec.modOutput(job.modDir, flags),
      ...[...source.extraIncludes, ...job.includes].flatMap((d) => spec.include(d, flags)),
      source.path,
    ].filter((a) => a !== "");
    return this.run(job.exe, args, source.cwd, job.env, signal);
  }

  /** Runs a program to its end; undefined when aborted or not started */
  private run(exe: string, args: string[], cwd: string, env: NodeJS.ProcessEnv, signal: AbortSignal): Promise<RunResult | undefined> {
    this.log.debug(`[lint] ${cwd}> ${exe} ${args.join(" ")}`);
    return new Promise((resolve) => {
      if (signal.aborted) {
        resolve(undefined);
        return;
      }
      const chunks: string[] = [];
      let child: cp.ChildProcess;
      try {
        child = cp.spawn(exe, args, { cwd, env, signal, timeout: TIMEOUT_MS, windowsHide: true });
      } catch (err) {
        this.log.error(`[lint] cannot run ${exe}: ${String(err)}`);
        resolve(undefined);
        return;
      }
      child.stdout?.setEncoding("utf8").on("data", (s: string) => chunks.push(s));
      child.stderr?.setEncoding("utf8").on("data", (s: string) => chunks.push(s));
      child.on("error", (err) => {
        if (!signal.aborted) {
          this.log.error(`[lint] cannot run ${exe}: ${String(err)}`);
        }
        resolve(undefined);
      });
      child.on("close", (code) => {
        if (signal.aborted) {
          resolve(undefined);
          return;
        }
        const output = chunks.join("");
        this.log.debug(`[lint] exit ${code}:\n${output}`);
        resolve({ code, output });
      });
    });
  }

  // --- messages to diagnostics ----------------------------------------------

  private toDiagnostics(doc: vscode.TextDocument, messages: CompilerMessage[], source: Source, job: Job): vscode.Diagnostic[] {
    const resolve = (file: string): string => path.resolve(source.cwd, file);
    const isSelf = (file: string | undefined): boolean =>
      !file || file === "<stdin>" || source.aliases.some((a) => samePath(resolve(file), a));
    const locate = (file: string | undefined, line: number, column?: number): vscode.Location => {
      const uri = isSelf(file) ? doc.uri : vscode.Uri.file(resolve(file ?? ""));
      return new vscode.Location(uri, new vscode.Position(Math.max(0, line - 1), Math.max(0, (column ?? 1) - 1)));
    };
    const result: vscode.Diagnostic[] = [];
    const seen = new Set<string>();
    for (const m of messages) {
      let d: vscode.Diagnostic;
      if (isSelf(m.file)) {
        d = new vscode.Diagnostic(this.rangeOf(doc, m), m.message, severity(m.severity));
      } else {
        // a message about an included file: shown at the INCLUDE line that
        // brings it in, with a link to the place in the included file
        const file = resolve(m.file ?? "");
        const where = `${path.relative(path.dirname(doc.fileName), file)}:${m.line}${m.column ? `:${m.column}` : ""}`;
        const range = this.includeSite(doc, file, [...source.extraIncludes, ...job.includes]) ??
          doc.lineAt(0).range;
        d = new vscode.Diagnostic(range, `${where}: ${m.message}`, severity(m.severity));
        d.relatedInformation = [new vscode.DiagnosticRelatedInformation(locate(m.file, m.line, m.column), m.message)];
      }
      d.source = job.spec.id;
      if (m.code) {
        d.code = m.code;
      }
      if (m.related.length > 0) {
        d.relatedInformation = [
          ...(d.relatedInformation ?? []),
          ...m.related.map((r) => new vscode.DiagnosticRelatedInformation(locate(r.file, r.line, r.column), r.message)),
        ];
      }
      const key = `${d.range.start.line}:${d.range.start.character}:${d.severity}:${d.message}`;
      if (!seen.has(key)) {
        seen.add(key);
        result.push(d);
      }
    }
    return result;
  }

  /** The word at the message's column, the span LFortran gives, or the
   * whole line (without its indentation) when there is no column */
  private rangeOf(doc: vscode.TextDocument, m: CompilerMessage): vscode.Range {
    const clampLine = (n: number): number => Math.min(Math.max(n - 1, 0), doc.lineCount - 1);
    const line = clampLine(m.line);
    const text = doc.lineAt(line).text;
    if (m.line === 0 || m.column === undefined) {
      const start = doc.lineAt(line).firstNonWhitespaceCharacterIndex;
      return new vscode.Range(line, start, line, text.length);
    }
    const start = new vscode.Position(line, Math.min(m.column - 1, text.length));
    if (m.endLine !== undefined && m.endColumn !== undefined) {
      const endLine = clampLine(m.endLine);
      const end = new vscode.Position(endLine, Math.min(m.endColumn, doc.lineAt(endLine).text.length));
      return end.isAfter(start) ? new vscode.Range(start, end) : new vscode.Range(start, start.translate(0, 1));
    }
    return doc.getWordRangeAtPosition(start) ??
      new vscode.Range(start, new vscode.Position(line, Math.min(start.character + 1, text.length)));
  }

  /** The INCLUDE line (or #include) of `doc` through which `target` is
   * included, directly or by a file it includes */
  private includeSite(doc: vscode.TextDocument, target: string, dirs: string[]): vscode.Range | undefined {
    const docDir = path.dirname(doc.fileName);
    for (const inc of findIncludes(doc.getText())) {
      const file = this.resolveInclude(inc.name, docDir, dirs);
      if (file && (samePath(file, target) || this.includesFile(file, target, dirs, new Set([doc.fileName]), 1))) {
        return new vscode.Range(inc.line, inc.start, inc.line, inc.end);
      }
    }
    return undefined;
  }

  private includesFile(file: string, target: string, dirs: string[], visited: Set<string>, depth: number): boolean {
    if (depth > MAX_DEPTH || visited.has(file)) {
      return false;
    }
    visited.add(file);
    let text: string;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      return false;
    }
    return findIncludes(text).some((inc) => {
      const next = this.resolveInclude(inc.name, path.dirname(file), dirs);
      return next !== undefined &&
        (samePath(next, target) || this.includesFile(next, target, dirs, visited, depth + 1));
    });
  }

  private resolveInclude(name: string, dir: string, dirs: string[]): string | undefined {
    if (path.isAbsolute(name)) {
      return fs.existsSync(name) ? name : undefined;
    }
    return [dir, ...dirs].map((d) => path.join(d, name)).find((p) => fs.existsSync(p));
  }

  // --- modules --------------------------------------------------------------

  private compiledKey(job: Job, file: string): string {
    return `${job.modDir}\u0000${path.resolve(file)}`;
  }

  /** Compiles, quietly, the workspace files defining the modules that
   * `text` uses (and theirs first), where their .mod files are missing or
   * older than the files, so that `use` finds them */
  private async buildDependencies(file: string, text: string, job: Job, signal: AbortSignal, visited: Set<string>, depth: number): Promise<void> {
    const { uses } = scanModules(text);
    if (uses.length === 0 || depth > MAX_DEPTH) {
      return;
    }
    const index = await this.moduleIndex();
    for (const mod of uses) {
      const dep = index.get(mod);
      if (signal.aborted) {
        return;
      }
      if (!dep || [...visited].some((v) => samePath(v, dep))) {
        continue;
      }
      visited.add(dep);
      const stamp = mtime(dep);
      if (stamp === undefined || this.isUpToDate(dep, mod, stamp, job)) {
        continue;
      }
      let depText: string;
      try {
        depText = await fs.promises.readFile(dep, "utf8");
      } catch {
        continue;
      }
      await this.buildDependencies(dep, depText, job, signal, visited, depth + 1);
      const source = await this.sourceFor(dep, undefined, job, signal);
      if (signal.aborted) {
        return;
      }
      if (!source) {
        continue;
      }
      this.log.debug(`[lint] building module ${mod} from ${dep} for ${file}`);
      const result = await this.compile(source, FIXED_FORM.has(path.extname(dep).toLowerCase()), job, signal);
      if (result) {
        // compiled even with errors, so that it is not retried until it changes
        this.compiled.set(this.compiledKey(job, dep), stamp);
      }
    }
  }

  private isUpToDate(dep: string, mod: string, stamp: number, job: Job): boolean {
    if (this.compiled.get(this.compiledKey(job, dep)) === stamp) {
      return true;
    }
    const modStamp = mtime(path.join(job.modDir, `${mod}.mod`));
    return modStamp !== undefined && modStamp >= stamp;
  }

  private moduleIndex(): Promise<Map<string, string>> {
    this.index ??= this.buildIndex();
    return this.index;
  }

  private async buildIndex(): Promise<Map<string, string>> {
    const index = new Map<string, string>();
    const files = await vscode.workspace.findFiles(FORTRAN_GLOB, "**/{node_modules,.git}/**", MAX_INDEXED_FILES);
    for (const uri of files) {
      if (uri.scheme !== "file") {
        continue;
      }
      try {
        const text = await fs.promises.readFile(uri.fsPath, "utf8");
        for (const mod of scanModules(text).defines) {
          if (!index.has(mod)) {
            index.set(mod, uri.fsPath);
          }
        }
      } catch {
        // unreadable: skipped
      }
    }
    this.log.debug(`[lint] module index: ${index.size} modules in ${files.length} files`);
    return index;
  }

  /** Updates the module index for a created, changed or deleted file */
  private async reindex(file: string): Promise<void> {
    if (!this.index) {
      return;
    }
    const index = await this.index;
    for (const [mod, f] of index) {
      if (samePath(f, file)) {
        index.delete(mod);
      }
    }
    try {
      const text = await fs.promises.readFile(file, "utf8");
      for (const mod of scanModules(text).defines) {
        index.set(mod, file);
      }
    } catch {
      // deleted
    }
  }
}
