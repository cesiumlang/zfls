// Runs inside VS Code: opens a fixture and asks VS Code for hover,
// definition, completion and symbols, which go through the extension's
// language client to zfls.

import * as assert from "node:assert";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import { findExecutable } from "../src/tools";

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

  checkSnippets();
  checkLanguageContributions();
  await checkConfigSchema();
  await checkCompilerDiagnostics();
}

// The snippets are packaged for both languages. (VS Code's snippet service in
// the test instance sometimes offers no snippets at all, so the completion
// list is not checked.)
function checkSnippets(): void {
  const ext = vscode.extensions.all.find((e) => e.packageJSON?.name === "zfls");
  assert.ok(ext, "zfls extension not found");
  const files: { language: string; path: string }[] = ext.packageJSON.contributes.snippets;
  assert.deepStrictEqual(files.map((f) => f.language), ["FortranFreeForm", "FortranFixedForm"]);
  for (const file of files) {
    const text = fs.readFileSync(path.join(ext.extensionPath, file.path), "utf8");
    const snippets: Record<string, { prefix: string; body: string[] }> = JSON.parse(text);
    const prefixes = Object.values(snippets).map((x) => x.prefix);
    assert.ok(prefixes.includes("selt"), `${file.language} snippet prefixes ${prefixes}`);
    if (file.language === "FortranFixedForm") {
      // typed at column 7, no tabs and nothing past column 72 with the
      // placeholders' default text
      for (const line of Object.values(snippets).flatMap((x) => x.body)) {
        const text = line.replace(/\$\{\d+[:|]?/g, "").replace(/\|?\}/g, "").replace(/\$\d+/g, "");
        assert.ok(!line.includes("\t") && 6 + text.length <= 72, `fixed-form line ${line}`);
      }
    }
  }
  console.log("snippets packaged for free and fixed form");
}

// Breakpoints are allowed in both languages, and their icons are packaged.
function checkLanguageContributions(): void {
  const ext = vscode.extensions.all.find((e) => e.packageJSON?.name === "zfls");
  assert.ok(ext, "zfls extension not found");
  const contributes = ext.packageJSON.contributes;
  const ids = ["FortranFreeForm", "FortranFixedForm"];
  const breakpoints = contributes.breakpoints.map((b: { language: string }) => b.language);
  assert.deepStrictEqual(breakpoints, ids);
  for (const language of contributes.languages.filter((l: { id: string }) => ids.includes(l.id))) {
    for (const icon of [language.icon.light, language.icon.dark]) {
      assert.ok(fs.existsSync(path.join(ext.extensionPath, icon)), `${language.id} icon ${icon}`);
    }
  }
  console.log("breakpoints and language icons contributed");
}

// A .fortlsrc opens as JSON with comments and is checked against the schema.
async function checkConfigSchema(): Promise<void> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-config-"));
  const file = path.join(dir, ".fortlsrc");
  fs.writeFileSync(file, '{\n  // comment\n  "nthreads": "four"\n}\n');
  const doc = await vscode.workspace.openTextDocument(file);
  await vscode.window.showTextDocument(doc);
  assert.strictEqual(doc.languageId, "jsonc");
  const problems = await poll("schema diagnostics", async () => {
    const found = vscode.languages.getDiagnostics(doc.uri);
    return found.length > 0 ? found : undefined;
  });
  const messages = problems.map((d) => d.message);
  assert.ok(messages.some((m) => /integer/i.test(m)), `diagnostics ${messages}`);
  assert.strictEqual(problems.length, 1, `diagnostics ${messages}`);
  console.log(`.fortlsrc checked against the schema: ${messages}`);
}

// A file with an error opened: gfortran's message shows in it (where the
// runner has gfortran).
async function checkCompilerDiagnostics(): Promise<void> {
  const commands = await vscode.commands.getCommands(true);
  assert.ok(commands.includes("zfls.linter.lint") && commands.includes("zfls.linter.clear"), "linter commands");
  if (!findExecutable("gfortran")) {
    console.log("no gfortran on the PATH: compiler diagnostics not checked");
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-lint-"));
  const file = path.join(dir, "lint_me.f90");
  fs.writeFileSync(file, "program lint_me\n  implicit none\n  i = 1\nend program lint_me\n");
  const doc = await vscode.workspace.openTextDocument(file);
  await vscode.window.showTextDocument(doc);
  const found = await poll("gfortran diagnostics", async () => {
    const mine = vscode.languages.getDiagnostics(doc.uri).filter((d) => d.source === "gfortran");
    return mine.length > 0 ? mine : undefined;
  });
  assert.strictEqual(found.length, 1, `diagnostics ${found.map((d) => d.message)}`);
  assert.match(found[0].message, /IMPLICIT/);
  assert.strictEqual(found[0].range.start.line, 2);
  assert.ok(!fs.readdirSync(dir).some((f) => f.endsWith(".mod") || f.endsWith(".o")), "files written beside the source");
  await vscode.commands.executeCommand("workbench.action.closeActiveEditor");
  console.log(`gfortran diagnostics shown: ${found[0].message}`);
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
