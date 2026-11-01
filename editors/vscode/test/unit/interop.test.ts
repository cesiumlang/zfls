// Plain Node.js tests (no VS Code) of the Fortran-C navigation helpers:
// `npm run unit`.

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { identifierAt, isCFile, uniqueByPlace } from "../../src/interop";

test("C, C++ and CUDA files", () => {
  for (const f of ["/w/a.h", "/w/a.C", "C:\\w\\b.cpp", "/w/k.cu", "/w/k.cuh", "/w/x.hpp"]) {
    assert.ok(isCFile(f), f);
  }
  for (const f of ["/w/a.f90", "/w/a.F", "/w/Makefile", "/w/a.h.f90"]) {
    assert.ok(!isCFile(f), f);
  }
});

test("a declaration found twice is kept once", () => {
  const found = [
    { uri: "file:///w/a.h", line: 2, by: "zfls" },
    { uri: "file:///w/a.h", line: 2, by: "clangd" },
    { uri: "file:///w/a.c", line: 1, by: "clangd" },
  ];
  assert.deepEqual(
    uniqueByPlace(found, (f) => f).map((f) => f.by),
    ["zfls", "clangd"],
  );
});

test("the C name under the cursor", () => {
  const line = "  int x = c_add(1, 2);";
  assert.equal(identifierAt(line, line.indexOf("c_add") + 2), "c_add");
  assert.equal(identifierAt(line, line.indexOf("c_add") + 5), "c_add");
  assert.equal(identifierAt(line, line.indexOf("1")), undefined);
  assert.equal(identifierAt("", 0), undefined);
});
