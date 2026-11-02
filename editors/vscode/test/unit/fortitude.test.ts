// Plain Node.js tests (no VS Code) of reading fortitude's output:
// `npm run unit`.

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { fortitudeArgs, parseOutput } from "../../src/lint/fortitude";

// as fortitude 0.10.1 prints it, for `real*8 :: x` and an unnamed `end`
const OUTPUT = JSON.stringify([
  {
    code: "PORT021",
    name: "star-kind",
    severity: "error",
    end_location: { column: 9, row: 3 },
    filename: "p.f90",
    fix: {
      applicability: "unsafe",
      edits: [{ content: "real(8)", end_location: { column: 9, row: 3 }, location: { column: 3, row: 3 } }],
      message: "Replace with 'real(8)'",
    },
    location: { column: 7, row: 3 },
    message: "'real*8' uses non-standard syntax",
    url: "https://fortitude.readthedocs.io//en/stable/rules/star-kind",
  },
  {
    code: "PORT011",
    name: "literal-kind",
    severity: "error",
    end_location: { column: 9, row: 3 },
    filename: "p.f90",
    fix: null,
    location: { column: 8, row: 3 },
    message: "real kind set with number literal '8'",
    url: "https://fortitude.readthedocs.io//en/stable/rules/literal-kind",
  },
]);

test("the text goes on stdin, named for fortitude's configuration", () => {
  assert.deepEqual(fortitudeArgs("/w/p.f90", ["--select", "C"]), [
    "check",
    "--output-format",
    "json",
    "--select",
    "C",
    "--stdin-filename",
    "/w/p.f90",
    "-",
  ]);
});

test("problems, 0-based, with their fixes", () => {
  const problems = parseOutput(OUTPUT);
  assert.ok(problems);
  assert.equal(problems.length, 2);
  const [star, literal] = problems;
  assert.equal(star.code, "PORT021");
  assert.equal(star.name, "star-kind");
  assert.deepEqual(star.range, { start: { line: 2, character: 6 }, end: { line: 2, character: 8 } });
  assert.equal(star.url, "https://fortitude.readthedocs.io/en/stable/rules/star-kind");
  assert.deepEqual(star.fix, {
    message: "Replace with 'real(8)'",
    applicability: "unsafe",
    edits: [{ range: { start: { line: 2, character: 2 }, end: { line: 2, character: 8 } }, content: "real(8)" }],
  });
  assert.equal(literal.fix, undefined);
});

test("output that is no JSON array is a failure", () => {
  assert.equal(parseOutput("error: unknown rule selector"), undefined);
  assert.equal(parseOutput("{}"), undefined);
  assert.deepEqual(parseOutput("[]"), []);
});
