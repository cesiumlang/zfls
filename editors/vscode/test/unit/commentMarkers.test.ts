// Plain Node.js tests (no VS Code) of the grammar of zfls.commentMarkers:
// `npm run unit`.

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";
import { INJECTION_FILE, INJECTION_SCOPE, escapeRegExp, markerGrammar, markerGrammarText } from "../../src/commentMarkers";

const root = path.join(__dirname, "..", "..");

test("the grammar shipped is the one for no markers, registered for both forms", () => {
  assert.equal(fs.readFileSync(path.join(root, "syntaxes", INJECTION_FILE), "utf8"), markerGrammarText([]));
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const entry = pkg.contributes.grammars.find((g: { scopeName: string }) => g.scopeName === INJECTION_SCOPE);
  assert.ok(entry, "not in package.json");
  assert.equal(entry.path, `./syntaxes/${INJECTION_FILE}`);
  assert.deepEqual(entry.injectTo, ["source.fortran.free", "source.fortran.fixed"]);
});

test("markers are matched literally", () => {
  assert.equal(escapeRegExp(";*"), ";\\*");
  assert.equal(escapeRegExp("//"), "\\/\\/");
  const g = markerGrammar([";*", "//", "", ";*"]) as { patterns: { begin: string }[] };
  assert.equal(g.patterns.length, 1);
  const begin = new RegExp(g.patterns[0].begin);
  assert.match("  go to 110  ;* it's a comment", begin);
  assert.match("  x = 1 // y", begin);
  assert.doesNotMatch("  a = 1; b = 2 * 3", begin);
  assert.deepEqual((markerGrammar([]) as { patterns: unknown[] }).patterns, []);
});
