// Every attribute that zfls dap reads from a launch or attach configuration
// is in the `fortran` debugger's schema (package.json), or is listed here as
// not the user's (#791).

import * as assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const root = path.join(__dirname, "..", "..", "..", "..");
// what the adapter reads from `args` that is not a configuration attribute:
// lldb-dap's own preRunCommands, and the arguments of other requests
const NOT_ATTRIBUTES = [
  "preRunCommands", "request", "breakpoints", "column", "context", "expression", "filterOptions", "filters",
  "frameId", "line", "name", "text", "threadId", "value", "variablesReference",
];

test("the schema lists every attribute the adapter reads", () => {
  const dap = path.join(root, "src", "dap");
  const read = new Set<string>();
  for (const file of readdirSync(dap).filter((f) => f.endsWith(".zig"))) {
    for (const m of readFileSync(path.join(dap, file), "utf8").matchAll(/json\.\w+\(args, "(\w+)"\)/g)) {
      read.add(m[1]);
    }
  }
  const pkg = JSON.parse(readFileSync(path.join(root, "editors", "vscode", "package.json"), "utf8"));
  const type = pkg.contributes.debuggers.find((d: { type: string }) => d.type === "fortran");
  const schema = new Set([...Object.keys(type.configurationAttributes.launch.properties), ...Object.keys(type.configurationAttributes.attach.properties)]);
  const missing = [...read].filter((k) => !schema.has(k) && !NOT_ATTRIBUTES.includes(k));
  assert.deepEqual(missing, []);
});
