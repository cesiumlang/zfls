// Plain Node.js tests (no VS Code) of the formatting helpers:
// `npm run unit`.

import * as assert from "node:assert/strict";
import { test } from "node:test";
import {
  formatterArgs,
  inputText,
  outputLines,
  selectedLines,
  textDiff,
  unsupportedReason,
} from "../../src/format";

test("findent gets the input form from the language", () => {
  assert.deepEqual(formatterArgs("findent", "FortranFreeForm", [], false), ["-ifree"]);
  assert.deepEqual(formatterArgs("findent", "FortranFixedForm", [], false), ["-ifixed"]);
  assert.deepEqual(formatterArgs("findent", "FortranFreeForm", ["-i4"], false), ["-ifree", "-i4"]);
});

test("findent input form and start indent from the user win", () => {
  assert.deepEqual(formatterArgs("findent", "FortranFixedForm", ["-iauto"], false), ["-iauto"]);
  assert.deepEqual(formatterArgs("findent", "FortranFreeForm", ["--input-format=fixed"], false), [
    "--input-format=fixed",
  ]);
  assert.deepEqual(formatterArgs("findent", "FortranFreeForm", ["--input_format=auto"], true), [
    "-Ia",
    "--input_format=auto",
  ]);
  assert.deepEqual(formatterArgs("findent", "FortranFreeForm", ["-I2"], true), ["-ifree", "-I2"]);
});

test("findent keeps the indentation of a selection", () => {
  assert.deepEqual(formatterArgs("findent", "FortranFreeForm", [], true), ["-ifree", "-Ia"]);
});

test("fprettify gets only the user's arguments", () => {
  assert.deepEqual(formatterArgs("fprettify", "FortranFreeForm", [], true), []);
  assert.deepEqual(formatterArgs("fprettify", "FortranFreeForm", ["-i", "4", "--enable-decl"], false), [
    "-i",
    "4",
    "--enable-decl",
  ]);
});

test("fprettify does not format fixed form", () => {
  assert.ok(unsupportedReason("fprettify", "FortranFixedForm"));
  assert.equal(unsupportedReason("fprettify", "FortranFreeForm"), undefined);
  assert.equal(unsupportedReason("findent", "FortranFixedForm"), undefined);
});

test("a selection covers whole lines", () => {
  assert.deepEqual(selectedLines(3, 3, 5), [3, 3]);
  assert.deepEqual(selectedLines(3, 7, 2), [3, 7]);
  // ending at the start of line 8 (a full-line selection) stops at line 7
  assert.deepEqual(selectedLines(3, 8, 0), [3, 7]);
  // an empty selection at the start of a line is that line
  assert.deepEqual(selectedLines(3, 3, 0), [3, 3]);
});

test("formatter input and output lines", () => {
  assert.equal(inputText(["a", "b"]), "a\nb\n");
  assert.deepEqual(outputLines("a\r\nb\r\n"), ["a", "b"]);
  assert.deepEqual(outputLines("a\nb"), ["a", "b"]);
  assert.deepEqual(outputLines("a\n\n"), ["a", ""]);
  assert.deepEqual(outputLines(""), [""]);
});

test("the edit is the changed part only", () => {
  assert.equal(textDiff("abc", "abc"), undefined);
  assert.deepEqual(textDiff("x=1\ny=2\nz=3", "x=1\n   y = 2\nz=3"), { start: 4, end: 6, text: "   y = " });
  assert.deepEqual(textDiff("a\nb", "a\nb\nc"), { start: 3, end: 3, text: "\nc" });
  assert.deepEqual(textDiff("a\nb\nc", "a\nc"), { start: 2, end: 4, text: "" });
  assert.deepEqual(textDiff("aaa", "aa"), { start: 2, end: 3, text: "" });
});

test("the edit does not split a surrogate pair", () => {
  // U+1F600 and U+1F601 share their high surrogate
  const diff = textDiff("! \u{1F600}", "! \u{1F601}");
  assert.deepEqual(diff, { start: 2, end: 4, text: "\u{1F601}" });
});
