// Formats Fortran documents and selections with findent or fprettify
// (zfls.formatting.*). The text goes to the formatter on stdin and comes back
// on stdout; no files are written.

import * as path from "node:path";
import * as vscode from "vscode";
import {
  FORMATTERS,
  Formatter,
  INSTALL_HINTS,
  formatterArgs,
  inputText,
  outputLines,
  selectedLines,
  textDiff,
  unsupportedReason,
} from "./format";
import { expandVariables, findExecutable, runProcess } from "./tools";
import { documentVariables } from "./variables";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];
const TIMEOUT_MS = 30_000;

/**
 * Registers the formatting providers while a formatter is chosen (for the
 * window or any workspace folder), so that with `Disabled` VS Code offers
 * other formatters, and format-on-save does nothing.
 */
export function registerFormatting(context: vscode.ExtensionContext, log: vscode.LogOutputChannel): void {
  let registration: vscode.Disposable | undefined;
  const provider = new FortranFormatter(log);
  const update = (): void => {
    const wanted = formattingEnabledSomewhere();
    if (wanted && !registration) {
      const selector = LANGUAGES.map((language) => ({ language }));
      registration = vscode.Disposable.from(
        vscode.languages.registerDocumentFormattingEditProvider(selector, provider),
        vscode.languages.registerDocumentRangeFormattingEditProvider(selector, provider),
      );
    } else if (!wanted && registration) {
      registration.dispose();
      registration = undefined;
    }
  };
  update();
  context.subscriptions.push(
    { dispose: () => registration?.dispose() },
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("zfls.formatting")) {
        provider.reported.clear();
        update();
      }
    }),
    vscode.workspace.onDidChangeWorkspaceFolders(update),
  );
}

function formattingEnabledSomewhere(): boolean {
  const uris: (vscode.Uri | undefined)[] = [undefined];
  for (const folder of vscode.workspace.workspaceFolders ?? []) {
    uris.push(folder.uri);
  }
  for (const uri of uris) {
    for (const languageId of LANGUAGES) {
      const config = vscode.workspace.getConfiguration("zfls.formatting", { uri, languageId });
      if (config.get<string>("formatter", "Disabled") !== "Disabled") {
        return true;
      }
    }
  }
  return false;
}

class FortranFormatter
  implements vscode.DocumentFormattingEditProvider, vscode.DocumentRangeFormattingEditProvider
{
  /** Problems already shown, so that format on save does not repeat them */
  readonly reported = new Set<string>();

  constructor(private readonly log: vscode.LogOutputChannel) {}

  provideDocumentFormattingEdits(
    document: vscode.TextDocument,
    _options: vscode.FormattingOptions,
    token: vscode.CancellationToken,
  ): Promise<vscode.TextEdit[]> {
    return this.format(document, 0, document.lineCount - 1, false, token);
  }

  provideDocumentRangeFormattingEdits(
    document: vscode.TextDocument,
    range: vscode.Range,
    _options: vscode.FormattingOptions,
    token: vscode.CancellationToken,
  ): Promise<vscode.TextEdit[]> {
    const [first, last] = selectedLines(range.start.line, range.end.line, range.end.character);
    return this.format(document, first, last, true, token);
  }

  private async format(
    document: vscode.TextDocument,
    first: number,
    last: number,
    selection: boolean,
    token: vscode.CancellationToken,
  ): Promise<vscode.TextEdit[]> {
    // read at each request: a changed setting applies at once
    const config = vscode.workspace.getConfiguration("zfls.formatting", {
      uri: document.uri,
      languageId: document.languageId,
    });
    const name = config.get<string>("formatter", "Disabled");
    if (!FORMATTERS.includes(name as Formatter)) {
      return [];
    }
    const formatter = name as Formatter;
    if (unsupportedReason(formatter, document.languageId)) {
      // the one reason there is: fprettify on fixed form
      this.reportOnce(
        `unsupported:${formatter}:${document.languageId}`,
        vscode.l10n.t("zfls: fprettify formats free-form Fortran only; use findent for fixed-form files."),
      );
      return [];
    }

    const ctx = documentVariables(document.uri);
    const configured = expandVariables(config.get<string>("path", "").trim(), ctx);
    const exe = findExecutable(formatter, configured, ctx.workspaceFolder);
    if (!exe) {
      this.reportOnce(
        `missing:${formatter}:${configured}`,
        configured
          ? vscode.l10n.t(
              "zfls: {0} was not found in {1} (zfls.formatting.path). Install it with `{2}`, or set zfls.formatting.path to it.",
              formatter,
              configured,
              INSTALL_HINTS[formatter],
            )
          : vscode.l10n.t(
              "zfls: {0} was not found on the PATH. Install it with `{1}`, or set zfls.formatting.path to it.",
              formatter,
              INSTALL_HINTS[formatter],
            ),
        "zfls.formatting.path",
      );
      return [];
    }
    const userArgs = config.get<string[]>(`${formatter}Args`, []).map((a) => expandVariables(a, ctx));
    const args = formatterArgs(formatter, document.languageId, userArgs, selection);

    const lines: string[] = [];
    for (let i = first; i <= last; i++) {
      lines.push(document.lineAt(i).text);
    }
    const before = lines.join("\n");
    const version = document.version;
    const abort = new AbortController();
    const cancel = token.onCancellationRequested(() => abort.abort());
    // fprettify looks for .fprettify.rc from the current directory up
    const cwd = document.uri.scheme === "file" ? path.dirname(document.uri.fsPath) : ctx.workspaceFolder;
    this.log.debug(`[format] ${exe} ${args.join(" ")} (lines ${first + 1}-${last + 1})`);
    const result = await runProcess(exe, args, {
      cwd,
      input: inputText(lines),
      timeout: TIMEOUT_MS,
      signal: abort.signal,
    }).finally(() => cancel.dispose());
    if (token.isCancellationRequested || document.version !== version) {
      return [];
    }
    if (result.stderr.trim()) {
      this.log.warn(`[format] ${formatter}: ${result.stderr.trim()}`);
    }
    if (result.error || result.code !== 0) {
      const why = result.error ? result.error.message : vscode.l10n.t("exit code {0}", String(result.code));
      const detail = result.stderr.trim() ? `: ${lastLine(result.stderr)}` : "";
      this.reportOnce(
        `failed:${formatter}:${why}:${result.stderr}`,
        vscode.l10n.t(
          "zfls: {0} failed ({1}){2}. The document is unchanged; see the zfls output for details.",
          formatter,
          why,
          detail,
        ),
      );
      return [];
    }
    const after = outputLines(result.stdout).join("\n");
    if (after.trim() === "" && before.trim() !== "") {
      this.reportOnce(
        `empty:${formatter}`,
        vscode.l10n.t("zfls: {0} printed nothing; the document is unchanged.", formatter),
      );
      return [];
    }
    const diff = textDiff(before, after);
    if (!diff) {
      return [];
    }
    // offsets in `before` (lines joined by \n) to positions in the document
    const position = (offset: number): vscode.Position => {
      const head = before.slice(0, offset).split("\n");
      return new vscode.Position(first + head.length - 1, head[head.length - 1].length);
    };
    const eol = document.eol === vscode.EndOfLine.CRLF ? "\r\n" : "\n";
    return [
      vscode.TextEdit.replace(
        new vscode.Range(position(diff.start), position(diff.end)),
        diff.text.replace(/\n/g, eol),
      ),
    ];
  }

  private reportOnce(key: string, message: string, setting = "zfls.formatting.formatter"): void {
    this.log.error(`[format] ${message}`);
    if (this.reported.has(key)) {
      return;
    }
    this.reported.add(key);
    const settings = vscode.l10n.t("Open Settings");
    const show = vscode.l10n.t("Show Output");
    void vscode.window.showErrorMessage(message, settings, show).then((choice) => {
      if (choice === settings) {
        void vscode.commands.executeCommand("workbench.action.openSettings", setting);
      } else if (choice === show) {
        this.log.show(true);
      }
    });
  }
}

/** The last line of an error output: where Python tools put the error */
function lastLine(text: string): string {
  const lines = text.trim().split(/\r?\n/);
  return lines[lines.length - 1];
}
