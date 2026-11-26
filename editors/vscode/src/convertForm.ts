// Fortran: Convert to Free Form / Convert to Fixed Form: the server converts
// the active document with findent (zfls/convertForm), and the result goes
// to a new file beside it (name.f90, or name.f), which is opened. The old
// file is left as it is.

import * as fs from "node:fs";
import * as vscode from "vscode";
import type { LanguageClient } from "vscode-languageclient/node";

type ClientFor = (uri: vscode.Uri) => Promise<LanguageClient | undefined>;

/** The form a conversion makes */
type Form = "free" | "fixed";

/** The language of the documents a conversion to each form starts from */
const SOURCE_LANGUAGE: Record<Form, string> = { free: "FortranFixedForm", fixed: "FortranFreeForm" };

/** What zfls/convertForm answers */
interface Converted {
  text?: string;
  path?: string;
  error?: string;
}

/** Converts the active document to `to` and opens the new file */
async function convertActive(to: Form, clientFor: ClientFor): Promise<void> {
  const doc = vscode.window.activeTextEditor?.document;
  if (!doc || doc.uri.scheme !== "file" || doc.languageId !== SOURCE_LANGUAGE[to]) {
    void vscode.window.showInformationMessage(
      to === "free"
        ? vscode.l10n.t("zfls: open a fixed-form Fortran file to convert it to free form.")
        : vscode.l10n.t("zfls: open a free-form Fortran file to convert it to fixed form."),
    );
    return;
  }
  const client = await clientFor(doc.uri);
  if (!client) {
    return;
  }
  const res = await client.sendRequest<Converted>("zfls/convertForm", { textDocument: { uri: doc.uri.toString() }, to });
  if (res.error || res.text === undefined || !res.path) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: the conversion failed: {0}", res.error ?? "no answer"));
    return;
  }
  if (fs.existsSync(res.path)) {
    const overwrite = vscode.l10n.t("Overwrite");
    const choice = await vscode.window.showWarningMessage(
      vscode.l10n.t("{0} exists. Overwrite it with the converted text?", res.path),
      { modal: true },
      overwrite,
    );
    if (choice !== overwrite) {
      return;
    }
  }
  const target = vscode.Uri.file(res.path);
  await vscode.workspace.fs.writeFile(target, new TextEncoder().encode(res.text));
  await vscode.window.showTextDocument(target);
}

/** The commands zfls.convertToFreeForm and zfls.convertToFixedForm */
export function registerConvertCommands(context: vscode.ExtensionContext, clientFor: ClientFor): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("zfls.convertToFreeForm", () => convertActive("free", clientFor)),
    vscode.commands.registerCommand("zfls.convertToFixedForm", () => convertActive("fixed", clientFor)),
  );
}
