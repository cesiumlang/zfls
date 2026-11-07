// Plain Node.js tests (no VS Code) of toggling fixed-form comments:
// `npm run unit`.

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { toggleComments } from "../../src/comments";

test("comments go in column 1", () => {
  assert.deepEqual(toggleComments(["      x = 1", "  100 continue"], "C"), ["C      x = 1", "C  100 continue"]);
  assert.deepEqual(toggleComments(["      x = 1"], "*"), ["*      x = 1"]);
});

test("toggling twice gives the lines back", () => {
  const lines = ["      x = 1", "", "      y = 2"];
  assert.deepEqual(toggleComments(toggleComments(lines, "C"), "C"), lines);
});

test("lines that are all comments are uncommented, whatever their character", () => {
  assert.deepEqual(toggleComments(["C      x = 1", "c      y = 2", "*      z = 3", "!      w = 4"], "C"), [
    "      x = 1",
    "      y = 2",
    "      z = 3",
    "      w = 4",
  ]);
});

test("a mix of code and comments is commented", () => {
  assert.deepEqual(toggleComments(["C     note", "      x = 1"], "C"), ["CC     note", "C      x = 1"]);
});

test("blank lines are left alone", () => {
  assert.deepEqual(toggleComments(["", "   ", "      x = 1"], "C"), ["", "   ", "C      x = 1"]);
  assert.deepEqual(toggleComments(["", "  "], "C"), ["", "  "]);
});
