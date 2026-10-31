// Plain Node.js tests of the fypp grammar injection: its patterns compile
// and match fypp's syntax (`npm run unit`). The grammar engine is
// Oniguruma; these patterns use only syntax JavaScript reads the same way.

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const root = path.join(__dirname, "..", "..");
const grammar = JSON.parse(fs.readFileSync(path.join(root, "syntaxes", "fypp.injection.json"), "utf8"));
const repo = grammar.repository;

function regexes(node: unknown, out: string[] = []): string[] {
  if (Array.isArray(node)) node.forEach((n) => regexes(n, out));
  else if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      if ((k === "match" || k === "begin" || k === "end") && typeof v === "string") out.push(v);
      else regexes(v, out);
    }
  }
  return out;
}

test("the fypp injection is registered for free-form Fortran", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const entry = pkg.contributes.grammars.find((g: { scopeName: string }) => g.scopeName === grammar.scopeName);
  assert.ok(entry, "not in package.json");
  assert.deepEqual(entry.injectTo, ["source.fortran.free"]);
});

test("every pattern of the fypp injection compiles", () => {
  for (const re of regexes(grammar)) assert.doesNotThrow(() => new RegExp(re), re);
});

test("the fypp patterns match fypp's syntax", () => {
  const begin = (name: string) => new RegExp(repo[name].begin ?? repo[name].match);
  assert.match("#:for dname in data_names", begin("fypp-directive"));
  assert.match("  #:endif", begin("fypp-directive"));
  assert.doesNotMatch("#include 'x.h'", begin("fypp-directive"));
  assert.match("  $:dname", begin("fypp-eval-line"));
  assert.match("    @:ASSERT(n > 0)", begin("fypp-macro-call"));
  assert.match("type :: eg_${dname}$_t", begin("fypp-inline-eval"));
  assert.match("x = 1 #{if DEBUG}# + 1 #{endif}#", begin("fypp-inline-directive"));
  assert.match("y = @{square(1)}@", begin("fypp-inline-macro"));
  assert.match("#! a fypp comment", begin("fypp-comment"));
});
