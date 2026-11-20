// Tests of which setting changes reach a running server over LSP and which
// restart it (src/settingsSync.ts), with plain Node.js (no VS Code):
//   npm run unit

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { appliesLive } from "../../src/settingsSync";

const base = { max_line_length: -1, use_signature_help: false, formatter: "none", formatter_fixed: "none", fortitude: false };

test("a changed value is sent", () => {
  assert.equal(appliesLive(base, { ...base, max_line_length: 132 }), true);
  assert.equal(appliesLive({ ...base, max_line_length: 132 }, base), true);
});

test("a feature turned on is sent, and turned off restarts", () => {
  assert.equal(appliesLive(base, { ...base, use_signature_help: true }), true);
  assert.equal(appliesLive({ ...base, use_signature_help: true }, base), false);
  assert.equal(appliesLive(base, { ...base, formatter: "findent" }), true);
  assert.equal(appliesLive({ ...base, formatter_fixed: "fprettify" }, base), false);
  // the formatters of #278 are formatters too
  assert.equal(appliesLive({ ...base, formatter: "custom" }, base), false);
  assert.equal(appliesLive({ ...base, formatter: "codee" }, { ...base, formatter: "forformat" }), true);
  // code actions stay on while fortitude or enable_code_actions is
  assert.equal(appliesLive({ ...base, fortitude: true }, { ...base, enable_code_actions: true }), true);
  assert.equal(appliesLive({ ...base, fortitude: true }, base), false);
});

test("a setting left out restarts", () => {
  assert.equal(appliesLive({ ...base, source_dirs: ["src"] }, base), false);
  assert.equal(appliesLive(base, { ...base, source_dirs: ["src"] }), true);
});
