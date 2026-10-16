// Runs inside VS Code: opens a fixture and asks VS Code for hover,
// definition, completion and symbols, which go through the extension's
// language client to zfls.

import * as assert from "node:assert";
import * as path from "node:path";
import * as vscode from "vscode";

const TIMEOUT_MS = 60_000;

export async function run(): Promise<void> {
  // the zfls under test, or else none configured, so that the bundled one
  // (or the PATH) is used
  await vscode.workspace
    .getConfiguration("zfls")
    .update("path", process.env.ZFLS_PATH || undefined, vscode.ConfigurationTarget.Global);
  const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  assert.ok(folder, "no workspace folder");
  const doc = await vscode.workspace.openTextDocument(path.join(folder, "modules_types.f90"));
  await vscode.window.showTextDocument(doc);
  assert.strictEqual(doc.languageId, "FortranFreeForm");
  const text = doc.getText();
  const at = (needle: string, offset = 0): vscode.Position => {
    const i = text.indexOf(needle);
    assert.ok(i >= 0, `fixture lacks ${needle}`);
    return doc.positionAt(i + offset);
  };

  // hover on the use of `pi` in circle_area (retried until zfls is up)
  const usePi = at("circle_area = pi", "circle_area = ".length);
  const hover = await poll("hover on pi", async () => {
    const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
      "vscode.executeHoverProvider", doc.uri, usePi);
    const shown = hovers
      .flatMap((h) => h.contents.map((c) => (typeof c === "string" ? c : c.value)))
      .join("\n");
    return /parameter/i.test(shown) ? shown : undefined;
  });
  console.log(`hover: ${hover.replace(/\s+/g, " ")}`);

  // definition of pi: its declaration
  const declaration = at("real, parameter :: pi").line;
  const defs = await vscode.commands.executeCommand<(vscode.Location | vscode.LocationLink)[]>(
    "vscode.executeDefinitionProvider", doc.uri, usePi);
  const lines = defs.map((d) => ("targetRange" in d ? d.targetRange : d.range).start.line);
  assert.ok(lines.includes(declaration), `definition lines ${lines}, expected ${declaration}`);

  // completion of a component after self%
  const member = at("self%radius", "self%".length);
  const items = await vscode.commands.executeCommand<vscode.CompletionList>(
    "vscode.executeCompletionItemProvider", doc.uri, member);
  const labels = items.items.map((i) => (typeof i.label === "string" ? i.label : i.label.label));
  assert.ok(labels.includes("radius"), `completions ${labels.slice(0, 20)}`);

  // document symbols
  const symbols = await vscode.commands.executeCommand<vscode.DocumentSymbol[]>(
    "vscode.executeDocumentSymbolProvider", doc.uri);
  const names = symbols.map((s) => s.name);
  assert.ok(names.includes("shapes"), `symbols ${names}`);

  console.log("zfls answered hover, definition, completion and symbols");

  await checkSnippets();
}

// The snippets are packaged and offered in both free and fixed form.
async function checkSnippets(): Promise<void> {
  for (const [language, line] of [["FortranFreeForm", "selt"], ["FortranFixedForm", "      selt"]]) {
    const doc = await vscode.workspace.openTextDocument({ language, content: line });
    const end = doc.lineAt(0).range.end;
    const snippets = await poll(`${language} snippets`, async () => {
      const list = await vscode.commands.executeCommand<vscode.CompletionList>(
        "vscode.executeCompletionItemProvider", doc.uri, end);
      const found = list.items.filter((i) => i.kind === vscode.CompletionItemKind.Snippet);
      return found.length > 0 ? found : undefined;
    });
    const labels = snippets.map((i) => (typeof i.label === "string" ? i.label : i.label.label));
    assert.ok(labels.includes("selt"), `${language} snippets ${labels}`);
  }
  console.log("snippets offered in free and fixed form");
}

async function poll<T>(what: string, attempt: () => Promise<T | undefined>): Promise<T> {
  const deadline = Date.now() + TIMEOUT_MS;
  for (;;) {
    const result = await attempt();
    if (result !== undefined) {
      return result;
    }
    if (Date.now() > deadline) {
      throw new Error(`timed out waiting for ${what}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}
