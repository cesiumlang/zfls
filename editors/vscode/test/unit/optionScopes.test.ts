// Each setting that becomes a zfls option is sent per workspace folder, so
// it is resource-scoped (#789).

import * as assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";
import { OPTIONS } from "../../src/options";

test("every setting that becomes a zfls option can differ per folder", () => {
  const pkg = JSON.parse(readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  const props: Record<string, { scope?: string }> = {};
  for (const section of [pkg.contributes.configuration].flat()) {
    Object.assign(props, section.properties);
  }
  for (const o of OPTIONS) {
    assert.equal(props[`zfls.${o.setting}`]?.scope, "resource", o.setting);
  }
});
