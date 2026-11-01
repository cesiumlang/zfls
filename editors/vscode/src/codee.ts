// Codee's checks (zfls.codee.*), best-effort: when a Fortran file is opened
// or saved, `codee checks --json` analyzes it as saved, and its checks show
// in a diagnostic collection of their own, each linked to its page of
// Codee's Open Catalog. Codee is a commercial tool, which must be installed
// and licensed separately; zfls has not been tested with it (see
// lint/codee.ts).

import * as path from "node:path";
import * as vscode from "vscode";
import { codeeArgs, parseCodee } from "./lint/codee";
import { expandVariables, findExecutable, runProcess } from "./tools";
import { documentVariables } from "./variables";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];
const TIMEOUT_MS = 120_000;
const SAVE_DELAY_MS = 250;

const SEVERITY = {
  error: vscode.DiagnosticSeverity.Error,
  warning: vscode.DiagnosticSeverity.Warning,
  hint: vscode.DiagnosticSeverity.Hint,
};

export class Codee implements vscode.Disposable {
  private readonly collection = vscode.languages.createDiagnosticCollection("codee");
  private readonly runs = new Map<string, AbortController>();
  private readonly timers = new Map<string, NodeJS.Timeout>();
  private readonly reported = new Set<string>();
  private readonly disposables: vscode.Disposable[] = [];

  constructor(private readonly log: vscode.LogOutputChannel) {}

  activate(): void {
    this.disposables.push(
      this.collection,
      vscode.workspace.onDidOpenTextDocument((doc) => this.schedule(doc)),
      vscode.workspace.onDidSaveTextDocument((doc) => this.schedule(doc)),
      vscode.workspace.onDidCloseTextDocument((doc) => this.forget(doc.uri)),
      vscode.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration("zfls.codee")) {
          this.reported.clear();
          vscode.workspace.textDocuments.forEach((doc) => this.schedule(doc));
        }
      }),
    );
    vscode.workspace.textDocuments.forEach((doc) => this.schedule(doc));
  }

  dispose(): void {
    this.timers.forEach((t) => clearTimeout(t));
    this.runs.forEach((r) => r.abort());
    vscode.Disposable.from(...this.disposables).dispose();
  }

  private forget(uri: vscode.Uri): void {
    const key = uri.toString();
    clearTimeout(this.timers.get(key));
    this.timers.delete(key);
    this.runs.get(key)?.abort();
    this.runs.delete(key);
    this.collection.delete(uri);
  }

  private schedule(doc: vscode.TextDocument): void {
    if (!LANGUAGES.includes(doc.languageId) || doc.uri.scheme !== "file") {
      return;
    }
    if (!vscode.workspace.getConfiguration("zfls.codee", doc.uri).get<boolean>("enabled", false)) {
      this.forget(doc.uri);
      return;
    }
    const key = doc.uri.toString();
    clearTimeout(this.timers.get(key));
    this.timers.set(
      key,
      setTimeout(() => {
        this.timers.delete(key);
        void this.check(doc);
      }, SAVE_DELAY_MS),
    );
  }

  private async check(doc: vscode.TextDocument): Promise<void> {
    const config = vscode.workspace.getConfiguration("zfls.codee", doc.uri);
    const ctx = documentVariables(doc.uri);
    const configured = expandVariables(config.get<string>("path", ""), ctx);
    const exe = findExecutable("codee", configured, ctx.workspaceFolder);
    if (!exe) {
      const key = `missing:${configured}`;
      if (!this.reported.has(key)) {
        this.reported.add(key);
        void vscode.window.showWarningMessage(
          configured
            ? vscode.l10n.t("zfls: codee was not found in {0} (zfls.codee.path).", configured)
            : vscode.l10n.t("zfls: codee was not found on the PATH."),
        );
      }
      return;
    }
    const file = doc.uri.fsPath;
    const args = codeeArgs(file, config.get<string[]>("args", []).map((a) => expandVariables(a, ctx)));
    const cwd = ctx.workspaceFolder ?? path.dirname(file);
    const key = doc.uri.toString();
    this.runs.get(key)?.abort();
    const abort = new AbortController();
    this.runs.set(key, abort);
    this.log.info(`[codee] ${exe} ${args.join(" ")} (in ${cwd})`);
    const result = await runProcess(exe, args, { cwd, timeout: TIMEOUT_MS, signal: abort.signal });
    if (this.runs.get(key) === abort) {
      this.runs.delete(key);
    }
    if (abort.signal.aborted || doc.isClosed) {
      return;
    }
    const checks = parseCodee(result.stdout);
    if (!checks) {
      this.log.warn(`[codee] no report for ${file}: ${result.error?.message ?? (result.stderr.trim() || result.stdout.trim())}`);
      return;
    }
    const same = (f: string): boolean => {
      const a = path.resolve(cwd, f);
      return process.platform === "win32" ? a.toLowerCase() === file.toLowerCase() : a === file;
    };
    this.collection.set(
      doc.uri,
      checks
        .filter((c) => same(c.file))
        .map((c) => {
          const line = Math.min(c.line, doc.lineCount - 1);
          const word = doc.getWordRangeAtPosition(new vscode.Position(line, c.character));
          const range = word ?? new vscode.Range(line, c.character, line, doc.lineAt(line).text.length);
          const d = new vscode.Diagnostic(range, c.message, SEVERITY[c.severity]);
          d.source = "codee";
          d.code = c.url ? { value: c.code, target: vscode.Uri.parse(c.url) } : c.code;
          return d;
        }),
    );
  }
}
