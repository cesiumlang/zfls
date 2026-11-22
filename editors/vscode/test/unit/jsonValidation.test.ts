// The configuration schema covers zfls's user configuration file too (#794).

import * as assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

test("the schema applies to the user configuration file", () => {
  const pkg = JSON.parse(readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  const match = pkg.contributes.jsonValidation.flatMap((v: { fileMatch: string[] }) => v.fileMatch);
  for (const name of [".fortlsrc", ".fortls.json", ".fortls", "**/zfls/config.json"]) {
    assert.ok(match.includes(name), name);
  }
});
