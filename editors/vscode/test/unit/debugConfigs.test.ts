// A new launch.json gets the Debug Fortran program configuration once (#786).

import * as assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";
import { initialConfiguration } from "../../src/debugConfigs";

test("the initial configuration comes from the provider only", () => {
  const pkg = JSON.parse(readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  const debuggers = pkg.contributes.debuggers.filter((d: { type: string }) => d.type === "fortran");
  assert.equal(debuggers.length, 1);
  assert.equal(debuggers[0].initialConfigurations, undefined);
  const config = initialConfiguration();
  assert.equal(config.type, "fortran");
  assert.equal(config.request, "launch");
  assert.equal(config.name, "Debug Fortran program");
});
