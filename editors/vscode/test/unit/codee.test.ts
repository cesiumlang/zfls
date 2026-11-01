// Plain Node.js tests (no VS Code) of reading Codee's output: `npm run unit`.
// The report follows the fields Codee's documentation reads; no Codee was
// at hand to capture one.

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { codeeArgs, codeeSeverity, parseCodee } from "../../src/lint/codee";

test("the file goes last, or where ${file} is", () => {
  assert.deepEqual(codeeArgs("/w/a.f90", []), ["checks", "--json", "/w/a.f90"]);
  assert.deepEqual(codeeArgs("/w/a.f90", ["-p", "build/compile_commands.json"]), [
    "checks", "--json", "-p", "build/compile_commands.json", "/w/a.f90",
  ]);
  assert.deepEqual(codeeArgs("/w/a.f90", ["${file}", "--", "gfortran", "${file}"]), [
    "checks", "--json", "/w/a.f90", "--", "gfortran", "/w/a.f90",
  ]);
});

test("checks, 0-based, with their severity and catalog page", () => {
  const out = "Codee 2025.3\n" + JSON.stringify({
    Checks: [
      { Check: "PWR068", Location: "src/solver.f90:12:5", Title: "Encapsulate procedures within modules", Suggestion: "Move it into a module." },
      { Check: "PWD002", Location: "C:\w\src\loop.f90:30:7", Title: "Unprotected multithreading reduction operation", Suggestion: "" },
      { Check: "RMK010", Location: "loop.f90:3:1", Title: "A remark" },
      { Check: "PWR001", Location: "nowhere", Title: "skipped" },
    ],
  });
  const checks = parseCodee(out)!;
  assert.equal(checks.length, 3);
  assert.deepEqual(checks[0], {
    code: "PWR068",
    file: "src/solver.f90",
    line: 11,
    character: 4,
    message: "Encapsulate procedures within modules\nMove it into a module.",
    severity: "warning",
    url: "https://open-catalog.codee.com/Checks/PWR068/",
  });
  assert.equal(checks[1].file, "C:\w\src\loop.f90");
  assert.equal(checks[1].severity, "error");
  assert.equal(checks[1].message, "Unprotected multithreading reduction operation");
  assert.equal(checks[2].severity, "hint");
  assert.equal(codeeSeverity("XYZ"), "warning");
});

test("output that is no report", () => {
  assert.equal(parseCodee("error: license not found"), undefined);
  assert.equal(parseCodee("{}"), undefined);
  assert.deepEqual(parseCodee('{"Checks": []}'), []);
});
