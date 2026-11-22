// A root with glob characters still gets its files served (#798).

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { servedPattern } from "../../src/servedPattern";

test("the root is the base of the pattern, never part of the glob", () => {
  for (const root of ["file:///c%3A/work/proj%5B1%5D", "file:///c%3A/work/a%7Bb%7D", "file:///c%3A/work/p%5Bab"]) {
    assert.deepEqual(servedPattern(root, true), { baseUri: root, pattern: "**/*" });
    assert.deepEqual(servedPattern(root, false), { baseUri: root, pattern: "*" });
  }
});
