// Tests of the snippets (snippets/*.json) with plain Node.js (no VS Code):
//   npm run unit
// The derived-type snippet, filled in with its defaults, is compiled with
// gfortran when it is on the PATH.

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { findExecutable, runProcess } from "../../src/tools";

type Snippets = Record<string, { prefix: string; body: string[]; description: string }>;

const root = path.join(__dirname, "..", "..");

function snippets(file: string): Snippets {
  return JSON.parse(fs.readFileSync(path.join(root, "snippets", file), "utf8")) as Snippets;
}

/** A snippet's body as VS Code inserts it when every placeholder keeps its
 * default (the first choice), with `indent` for a tab */
function expand(body: string[], indent: string): string[] {
  let text = body.join("\n");
  const defaults = new Map<string, string>();
  // innermost placeholders first: ${7:${3:name}}
  for (let before = ""; before !== text; ) {
    before = text;
    text = text.replace(/\$\{(\d+):([^${}]*)\}/g, (_, n: string, value: string) => {
      defaults.set(n, value);
      return value;
    });
    text = text.replace(/\$\{(\d+)\|([^|]*)\|\}/g, (_, n: string, choices: string) => {
      const value = choices.split(",")[0];
      defaults.set(n, value);
      return value;
    });
  }
  text = text.replace(/\$\{(\d+)\}|\$(\d+)/g, (_, a?: string, b?: string) => defaults.get((a ?? b)!) ?? "");
  return text.replace(/\t/g, indent).split("\n");
}

const forms = [
  { file: "fortran-free-form.json", ext: ".f90", indent: "  ", margin: "" },
  // inserted at column 7, each line indented as the first
  { file: "fortran-fixed-form.json", ext: ".f", indent: "   ", margin: "      " },
];

for (const form of forms) {
  test(`${form.file}: the derived type's PRIVATE statement comes before its components`, async (t) => {
    const lines = expand(snippets(form.file).Type.body, form.indent);
    const at = (re: RegExp) => lines.findIndex((l) => re.test(l));
    const component = at(/^\s*\w+\s*::/);
    assert.ok(component > 0);
    assert.ok(at(/^\s*private\s*$/) > 0 && at(/^\s*private\s*$/) < component);
    assert.ok(at(/^\s*contains\s*$/) > component);

    const gfortran = findExecutable("gfortran");
    if (!gfortran) {
      t.skip("gfortran is not on the PATH");
      return;
    }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-unit-"));
    try {
      const source = ["module m", "implicit none", ...lines, "end module m"].map((l) => form.margin + l).join("\n") + "\n";
      const file = path.join(dir, `m${form.ext}`);
      fs.writeFileSync(file, source);
      const result = await runProcess(gfortran, ["-fsyntax-only", "-std=f2008", file], { cwd: dir });
      assert.equal(result.code, 0, `${source}\n${result.stderr}`);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
