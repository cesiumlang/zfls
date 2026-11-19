// Plain Node.js tests (no VS Code) of the code lens helpers: `npm run unit`.

import * as assert from "node:assert/strict";
import { test } from "node:test";
import type { ClientCapabilities } from "vscode-languageclient/node";
import { LENS_COMMANDS, lensCommandsFeature, referenceArgs } from "../../src/codeLenses";

const at = { line: 2, character: 10 };
const location = { uri: "file:///w/main.f90", range: { start: { line: 3, character: 7 }, end: { line: 3, character: 12 } } };

test("the arguments of zfls.showReferences", () => {
  assert.deepEqual(referenceArgs(["file:///w/m.f90", at, [location]]), {
    uri: "file:///w/m.f90",
    position: at,
    locations: [location],
  });
  assert.deepEqual(referenceArgs(["file:///w/m.f90", at, []])?.locations, []);
  assert.equal(referenceArgs([]), undefined);
  assert.equal(referenceArgs([{ path: "/w/m.f90" }, at, []]), undefined);
  assert.equal(referenceArgs(["file:///w/m.f90", { line: 2 }, []]), undefined);
  assert.equal(referenceArgs(["file:///w/m.f90", at, [{ uri: "file:///w/x.f90" }]]), undefined);
});

test("the client announces the lens commands, after any others", () => {
  const caps: ClientCapabilities = {};
  lensCommandsFeature().fillClientCapabilities(caps);
  assert.deepEqual(caps.experimental, { commands: { commands: [...LENS_COMMANDS] } });
  const other: ClientCapabilities = { experimental: { commands: { commands: ["other.command"] }, more: true } };
  lensCommandsFeature().fillClientCapabilities(other);
  assert.deepEqual(other.experimental, { commands: { commands: ["other.command", ...LENS_COMMANDS] }, more: true });
});
