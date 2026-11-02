// Plain Node.js tests (no VS Code) of what the extension needs for
// debugging with zfls dap (`npm run unit`); zfls dap's own tests are in
// Zig (src/dap/, tests/dap_gdb.zig)

import * as assert from "node:assert/strict";
import * as path from "node:path";
import { test } from "node:test";
import { gdbEnv, gdbVersion, hoverExpressionStart } from "../../src/debugSupport";

test("the expression under the mouse", () => {
  const line = "  y = p%x + a(i, 2)%w(3) + q % z";
  assert.equal(hoverExpressionStart(line, line.indexOf("x +")), line.indexOf("p%x"));
  assert.equal(hoverExpressionStart(line, line.indexOf("w(3)")), line.indexOf("a(i, 2)"));
  assert.equal(hoverExpressionStart(line, line.indexOf("z")), line.indexOf("q % z"));
  assert.equal(hoverExpressionStart(line, line.indexOf("y")), line.indexOf("y"));
  // no name before the %
  assert.equal(hoverExpressionStart("  (1)%x", 6), 6);
});

test("gdb's version", () => {
  assert.deepEqual(gdbVersion("GNU gdb (GDB) 17.2\nCopyright"), [17, 2]);
  assert.deepEqual(gdbVersion("GNU gdb (Ubuntu 15.0.50.20240403-0ubuntu1) 15.0.50.20240403-git"), [15, 0]);
  assert.deepEqual(gdbVersion("GNU gdb (GDB; SUSE Linux Enterprise 15) 12.1"), [12, 1]);
  assert.deepEqual(gdbVersion("GNU gdb (Fedora Linux) 14.1-2.fc39\r\nCopyright"), [14, 1]);
  assert.equal(gdbVersion("lldb version 21"), undefined);
});

test("gdb's own directory first on its PATH, for its Python", () => {
  const gdb = path.resolve("/opt/gdb/bin/gdb");
  const env = gdbEnv(gdb, { Path: "x", HOME: "h" });
  assert.equal(env.Path, `${path.dirname(gdb)}${path.delimiter}x`);
  assert.equal(env.HOME, "h");
  // a bare name: the PATH as it is
  assert.deepEqual(gdbEnv("gdb", { PATH: "x" }), { PATH: "x" });
});
