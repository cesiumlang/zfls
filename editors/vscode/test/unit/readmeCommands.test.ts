// The README's Commands section lists every command of package.json (#792).

import * as assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const dir = path.join(__dirname, "..", "..", "..", "..", "editors", "vscode");

test("each command has a bullet in the README's Commands section", () => {
  const pkg = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8"));
  const nls: Record<string, string> = JSON.parse(readFileSync(path.join(dir, "package.nls.json"), "utf8"));
  const readme = readFileSync(path.join(dir, "README.md"), "utf8");
  const start = readme.indexOf("\n## Commands");
  const section = readme.slice(start, readme.indexOf("\n## ", start + 1) === -1 ? undefined : readme.indexOf("\n## ", start + 1));
  assert.ok(start >= 0);
  for (const c of pkg.contributes.commands as { command: string; title: string; category?: string }[]) {
    const title = nls[c.title.replace(/^%|%$/g, "")] ?? c.title;
    assert.ok(section.includes(title), `${c.command}: "${title}" is not in the Commands section`);
  }
});
