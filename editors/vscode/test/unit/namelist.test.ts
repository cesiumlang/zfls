// Plain Node.js tests (no VS Code) of namelist files: the grammar's patterns
// (`npm run unit`). zfls serves their outline (src/namelist.zig).

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const root = path.join(__dirname, "..", "..");
const grammar = JSON.parse(fs.readFileSync(path.join(root, "syntaxes", "fortran_namelist.tmLanguage.json"), "utf8"));
const repo = grammar.repository;

test("the namelist grammar is registered for its language", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const entry = pkg.contributes.grammars.find((g: { scopeName: string }) => g.scopeName === grammar.scopeName);
  assert.equal(entry?.language, "FortranNamelist");
  const lang = pkg.contributes.languages.find((l: { id: string }) => l.id === "FortranNamelist");
  assert.ok(lang.extensions.includes(".nml"));
});

test("the namelist patterns match namelist syntax", () => {
  const re = (name: string) => new RegExp(repo[name].match);
  assert.match("&run_params", re("group-start"));
  assert.match("  $output", re("group-start"));
  assert.doesNotMatch("&end", re("group-start"));
  assert.match("$END", re("group-end"));
  assert.match("  /", re("group-end"));
  assert.match("  grid%nx = 3", re("assignment"));
  assert.match("  flags(1:2) = .true.", re("assignment"));
  const values = repo.values.patterns.filter((p: { match?: string }) => p.match).map((p: { match: string }) => new RegExp(p.match));
  for (const v of [".true.", ".F.", "3*", "1.0d-3", "-2.5e10", ".5", "42_int64"]) {
    assert.ok(
      values.some((r: RegExp) => r.exec(v)?.[0] === v),
      v,
    );
  }
});
