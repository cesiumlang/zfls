// Each setting that becomes a zfls option is sent per workspace folder, so
// it is resource-scoped (#789), but for the one that names a program, which
// a workspace's own settings do not set (machine scope).

import * as assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";
import { OPTIONS } from "../../src/options";

const programs = new Set(["bindCClangd"]);

test("every setting that becomes a zfls option can differ per folder", () => {
  const pkg = JSON.parse(readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  const props: Record<string, { scope?: string }> = {};
  for (const section of [pkg.contributes.configuration].flat()) {
    Object.assign(props, section.properties);
  }
  for (const o of OPTIONS) {
    assert.equal(props[`zfls.${o.setting}`]?.scope, programs.has(o.setting) ? "machine" : "resource", o.setting);
  }
});

test("the settings that name a program are machine-scoped, and untrusted workspaces are declared", () => {
  const pkg = JSON.parse(readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  const props: Record<string, { scope?: string }> = {};
  for (const section of [pkg.contributes.configuration].flat()) {
    Object.assign(props, section.properties);
  }
  for (const [name, p] of Object.entries(props)) {
    if (/(^|\.)(path|[a-z]*Path|bindCClangd)$/.test(name)) {
      if (/Paths$|includePaths|excludePaths/.test(name)) continue;
      assert.equal(p.scope, "machine", name);
    }
  }
  assert.equal(pkg.capabilities.untrustedWorkspaces.supported, "limited");
  for (const name of pkg.capabilities.untrustedWorkspaces.restrictedConfigurations) {
    assert.ok(props[name], name);
  }
});
