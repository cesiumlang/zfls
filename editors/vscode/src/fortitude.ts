// Linting with fortitude (zfls.fortitude.*, Modern Fortran #1165): the text
// of a Fortran file goes to `fortitude check` on stdin when it is opened or
// saved (and while it is edited, with lintOnType); its problems show in a
// diagnostic collection of their own, with fortitude's fixes as quick fixes
// and a "fix all" source action (`source.fixAll.fortitude`).

import * as path from "node:path";
import * as vscode from "vscode";
import { INSTALL_HINT, Problem, fortitudeArgs, parseOutput } from "./lint/fortitude";
import { expandVariables, findExecutable, runProcess } from "./tools";
import { documentVariables } from "./variables";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];
const TIMEOUT_MS = 30_000;
const SAVE_DELAY_MS = 250;
const FIX_ALL = vscode.CodeActionKind.SourceFixAll.append("fortitude");

interface Settings {
  enabled: boolean;
  path: string;
  args: string[];
  lintOnType: boolean;
  lintOnTypeDelay: number;
}

function settingsFor(uri: vscode.Uri): Settings {
  const c = vscode.workspace.getConfiguration("zfls.fortitude", uri);
  return {
    enabled: c.get<boolean>("enabled", false),
    path: c.get<string>("path", ""),
    args: c.get<string[]>("args", []),
    lintOnType: c.get<boolean>("lintOnType", false),
    lintOnTypeDelay: c.get<number>("lintOnTypeDelay", 500),
  };
}

function toRange(r: Problem["range"]): vscode.Range {
  return new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character);
}

export class Fortitude implements vscode.CodeActionProvider, vscode.Disposable {
  private readonly collection = vscode.languages.createDiagnosticCollection("fortitude");
  /** The problems of each file, for their fixes */
  private readonly problems = new Map<string, Problem[]>();
  private readonly runs = new Map<string, AbortController>();
  private readonly timers = new Map<string, NodeJS.Timeout>();
  private readonly reported = new Set<string>();
  private readonly disposables: vscode.Disposable[] = [];

  constructor(private readonly log: vscode.LogOutputChannel) {}

  activate(): void {
    const selector = LANGUAGES.map((language) => ({ language }));
    this.disposables.push(
      this.collection,
      vscode.languages.registerCodeActionsProvider(selector, this, {
        providedCodeActionKinds: [vscode.CodeActionKind.QuickFix, FIX_ALL],
      }),
      vscode.workspace.onDidOpenTextDocument((doc) => this.schedule(doc, SAVE_DELAY_MS)),
      vscode.workspace.onDidSaveTextDocument((doc) => this.schedule(doc, SAVE_DELAY_MS)),
      vscode.workspace.onDidChangeTextDocument((e) => {
        const s = settingsFor(e.document.uri);
        if (s.enabled && s.lintOnType && e.contentChanges.length > 0) {
          this.schedule(e.document, s.lintOnTypeDelay);
        }
      }),
      vscode.workspace.onDidCloseTextDocument((doc) => this.forget(doc.uri)),
      vscode.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration("zfls.fortitude")) {
          this.reported.clear();
          this.lintAll();
        }
      }),
    );
    this.lintAll();
  }

  dispose(): void {
    for (const t of this.timers.values()) {
      clearTimeout(t);
    }
    for (const r of this.runs.values()) {
      r.abort();
    }
    vscode.Disposable.from(...this.disposables).dispose();
  }

  private lintAll(): void {
    for (const doc of vscode.workspace.textDocuments) {
      this.schedule(doc, 0);
    }
  }

  private forget(uri: vscode.Uri): void {
    const key = uri.toString();
    clearTimeout(this.timers.get(key));
    this.timers.delete(key);
    this.runs.get(key)?.abort();
    this.runs.delete(key);
    this.problems.delete(key);
    this.collection.delete(uri);
  }

  private schedule(doc: vscode.TextDocument, delay: number): void {
    if (!LANGUAGES.includes(doc.languageId) || doc.uri.scheme !== "file") {
      return;
    }
    if (!settingsFor(doc.uri).enabled) {
      this.forget(doc.uri);
      return;
    }
    const key = doc.uri.toString();
    clearTimeout(this.timers.get(key));
    this.timers.set(
      key,
      setTimeout(() => {
        this.timers.delete(key);
        void this.lint(doc);
      }, delay),
    );
  }

  /** The fortitude executable for a file, or undefined (said once) */
  private executable(doc: vscode.TextDocument, s: Settings): string | undefined {
    const ctx = documentVariables(doc.uri);
    const configured = expandVariables(s.path, ctx);
    const exe = findExecutable("fortitude", configured, ctx.workspaceFolder);
    if (!exe) {
      const key = `missing:${configured}`;
      if (!this.reported.has(key)) {
        this.reported.add(key);
        void vscode.window.showWarningMessage(
          configured
            ? vscode.l10n.t(
                "zfls: fortitude was not found in {0} (zfls.fortitude.path). Install it with `{1}`, or set zfls.fortitude.path to it.",
                configured,
                INSTALL_HINT,
              )
            : vscode.l10n.t(
                "zfls: fortitude was not found on the PATH. Install it with `{0}`, or set zfls.fortitude.path to it.",
                INSTALL_HINT,
              ),
        );
      }
    }
    return exe;
  }

  /** Runs fortitude on the text of `doc`, with `extra` arguments */
  private async run(doc: vscode.TextDocument, extra: string[], signal?: AbortSignal) {
    const s = settingsFor(doc.uri);
    const exe = this.executable(doc, s);
    if (!exe) {
      return undefined;
    }
    const ctx = documentVariables(doc.uri);
    const args = fortitudeArgs(doc.uri.fsPath, [...extra, ...s.args.map((a) => expandVariables(a, ctx))]);
    // its configuration (fpm.toml, fortitude.toml) is found from there
    const cwd = ctx.workspaceFolder ?? path.dirname(doc.uri.fsPath);
    return runProcess(exe, args, { cwd, input: doc.getText(), timeout: TIMEOUT_MS, signal });
  }

  private async lint(doc: vscode.TextDocument): Promise<void> {
    const key = doc.uri.toString();
    this.runs.get(key)?.abort();
    const abort = new AbortController();
    this.runs.set(key, abort);
    const version = doc.version;
    const result = await this.run(doc, [], abort.signal);
    if (this.runs.get(key) === abort) {
      this.runs.delete(key);
    }
    if (!result || abort.signal.aborted || doc.isClosed || doc.version !== version) {
      return;
    }
    const problems = parseOutput(result.stdout);
    if (!problems) {
      this.log.warn(`fortitude failed on ${doc.uri.fsPath}: ${result.error?.message ?? result.stderr.trim()}`);
      return;
    }
    this.problems.set(key, problems);
    this.collection.set(
      doc.uri,
      problems.map((p) => {
        const d = new vscode.Diagnostic(toRange(p.range), p.message, vscode.DiagnosticSeverity.Warning);
        d.source = "fortitude";
        d.code = p.url ? { value: p.code, target: vscode.Uri.parse(p.url) } : p.code;
        return d;
      }),
    );
  }

  provideCodeActions(
    doc: vscode.TextDocument,
    _range: vscode.Range,
    context: vscode.CodeActionContext,
  ): vscode.CodeAction[] {
    const problems = this.problems.get(doc.uri.toString()) ?? [];
    const actions: vscode.CodeAction[] = [];
    const wants = (kind: vscode.CodeActionKind) => !context.only || context.only.contains(kind) || kind.contains(context.only);
    if (wants(vscode.CodeActionKind.QuickFix)) {
      for (const d of context.diagnostics) {
        if (d.source !== "fortitude") {
          continue;
        }
        const code = typeof d.code === "object" ? d.code.value : d.code;
        const p = problems.find((x) => x.code === code && toRange(x.range).isEqual(d.range));
        if (!p?.fix || p.fix.applicability === "display-only") {
          continue;
        }
        const unsafe = p.fix.applicability !== "safe";
        const action = new vscode.CodeAction(
          unsafe
            ? vscode.l10n.t("{0} (fortitude {1}, unsafe)", p.fix.message, p.code)
            : vscode.l10n.t("{0} (fortitude {1})", p.fix.message, p.code),
          vscode.CodeActionKind.QuickFix,
        );
        action.diagnostics = [d];
        action.isPreferred = !unsafe;
        action.edit = new vscode.WorkspaceEdit();
        for (const e of p.fix.edits) {
          action.edit.replace(doc.uri, toRange(e.range), e.content);
        }
        actions.push(action);
      }
    }
    if (settingsFor(doc.uri).enabled && wants(FIX_ALL) && problems.some((p) => p.fix?.applicability === "safe")) {
      const action = new vscode.CodeAction(vscode.l10n.t("Fix all safe fortitude problems"), FIX_ALL);
      action.command = { title: action.title, command: "zfls.fortitude.fixAll", arguments: [doc.uri] };
      actions.push(action);
    }
    return actions;
  }

  /** Applies fortitude's safe fixes to a file: `--fix-only` gives the
   * fixed text */
  async fixAll(uri?: vscode.Uri): Promise<void> {
    const doc = uri
      ? vscode.workspace.textDocuments.find((d) => d.uri.toString() === uri.toString())
      : vscode.window.activeTextEditor?.document;
    if (!doc || !LANGUAGES.includes(doc.languageId)) {
      return;
    }
    const version = doc.version;
    const result = await this.run(doc, ["--fix-only"]);
    if (!result || result.error || result.code !== 0 || doc.version !== version) {
      if (result && (result.error || result.code !== 0)) {
        this.log.warn(`fortitude --fix-only failed on ${doc.uri.fsPath}: ${result.error?.message ?? result.stderr.trim()}`);
      }
      return;
    }
    if (result.stdout === doc.getText()) {
      return;
    }
    const edit = new vscode.WorkspaceEdit();
    const last = doc.lineAt(doc.lineCount - 1);
    edit.replace(doc.uri, new vscode.Range(0, 0, last.lineNumber, last.text.length), result.stdout);
    await vscode.workspace.applyEdit(edit);
  }
}
