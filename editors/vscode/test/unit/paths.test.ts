// Tests of the glob patterns in the zfls.linter settings' include
// directories (src/lint/paths.ts) with plain Node.js (no VS Code):
//   npm run unit
// The compiler messages are zfls's to parse now (src/compilers.zig, with
// its tests).

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { expandDirectoryGlob } from "../../src/lint/paths";

test("glob patterns match directories", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-glob-"));
  try {
    for (const d of ["build/a/include", "build/b/include", "build/b/src", "other/include"]) {
      fs.mkdirSync(path.join(root, d), { recursive: true });
    }
    fs.writeFileSync(path.join(root, "build", "file.txt"), "");
    const rel = (ps: string[]): string[] => ps.map((p) => path.relative(root, p).replace(/\\/g, "/")).sort();
    assert.deepEqual(rel(expandDirectoryGlob(path.join(root, "build", "*", "include"))),
      ["build/a/include", "build/b/include"]);
    assert.deepEqual(rel(expandDirectoryGlob(path.join(root, "**", "include"))),
      ["build/a/include", "build/b/include", "other/include"]);
    assert.deepEqual(rel(expandDirectoryGlob(path.join(root, "build", "*"))), ["build/a", "build/b"]);
    assert.deepEqual(rel(expandDirectoryGlob(path.join(root, "build", "[a]", "*"))), ["build/a/include"]);
    // without glob characters: as it is, existing or not
    assert.deepEqual(expandDirectoryGlob("/no/such/dir"), ["/no/such/dir"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
