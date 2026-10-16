// Tests of the linter's pure parts with plain Node.js (no VS Code):
//   npm run test:unit
// The compiler output samples are gfortran's own (captured from GNU Fortran
// 16.1, MSYS2) and, for the compilers not at hand, messages in the formats
// their manuals and sources describe.

import * as assert from "node:assert/strict";
import * as cp from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import {
  COMPILERS,
  CompilerMessage,
  dedupe,
  parseFlang,
  parseGfortran,
  parseIntel,
  parseLfortran,
  parseNag,
  parseNvfortran,
} from "../../src/lint/compilers";
import { expandDirectoryGlob, findExecutable, resolveVariables, samePath } from "../../src/lint/paths";
import { findIncludes, scanModules } from "../../src/lint/sources";

/** The fields that matter, for comparing */
function brief(m: CompilerMessage): string {
  return `${m.file ?? "-"}:${m.line}:${m.column ?? "-"} ${m.severity}: ${m.message}${m.code ? ` [${m.code}]` : ""}`;
}

// --- gfortran ---------------------------------------------------------------

test("gfortran one-line messages (-fno-diagnostics-show-caret)", () => {
  const out = [
    "main.f90:5:7: Error: Symbol 'j' at (1) has no IMPLICIT type",
    "inc.h:2:21: Error: Symbol 'undefined_thing' at (1) has no IMPLICIT type",
    "warn.f90:6:16: Warning: Unused variable 'unused' declared at (1) [-Wunused-variable]",
    "usem.f90:2:7: Fatal Error: Cannot open module file 'nonexistent_mod.mod' for reading at (1): No such file or directory",
    "compilation terminated.",
  ].join("\n");
  assert.deepEqual(parseGfortran(out).map(brief), [
    "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
    "inc.h:2:21 error: Symbol 'undefined_thing' at (1) has no IMPLICIT type",
    "warn.f90:6:16 warning: Unused variable 'unused' declared at (1) [-Wunused-variable]",
    "usem.f90:2:7 error: Cannot open module file 'nonexistent_mod.mod' for reading at (1): No such file or directory",
  ]);
});

test("gfortran caret format (older gfortran, or without the flag)", () => {
  const out = [
    "main.f90:5:7:",
    "",
    "    5 |   i = j + 1",
    "      |       1",
    "Error: Symbol 'j' at (1) has no IMPLICIT type",
    "C:\\src\\fixed.f:4:11:",
    "",
    "    4 |       i = q",
    "      |           1",
    "Error: Symbol 'q' at (1) has no IMPLICIT type",
    // gfortran 4.9-9: a range locus and two loci for one message
    "two.f90:8.13-15:",
    "two.f90:12:3:",
    "Warning: Type mismatch at (1) and (2)",
  ].join("\r\n");
  assert.deepEqual(parseGfortran(out).map(brief), [
    "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
    "C:\\src\\fixed.f:4:11 error: Symbol 'q' at (1) has no IMPLICIT type",
    "two.f90:8:13 warning: Type mismatch at (1) and (2)",
  ]);
});

test("gfortran driver messages without a location", () => {
  const out = [
    "gfortran: error: unrecognized command-line option '-Wbogus'",
    "f951.exe: Warning: Nonexistent include directory 'nope' [-Wmissing-include-dirs]",
  ].join("\n");
  assert.deepEqual(parseGfortran(out).map(brief), [
    "-:0:- error: gfortran: unrecognized command-line option '-Wbogus'",
    "-:0:- warning: f951.exe: Nonexistent include directory 'nope' [-Wmissing-include-dirs]",
  ]);
});

// --- Intel ------------------------------------------------------------------

test("ifx and ifort messages with the caret line", () => {
  const out = [
    "test.f90(3): error #6404: This name does not have a type, and must have an explicit type.   [X]",
    "  x = 1",
    "--^",
    "C:\\work\\test.f90(7): warning #6717: This name has not been given an explicit type.   [Y]",
    "      y = 2",
    "------^",
    "test.f90(9): remark #7712: This variable has not been used.   [Z]",
    "test.f90(2): #error: unsupported configuration",
    "test.f90(12): catastrophic error: Too many errors, exiting",
    "compilation aborted for test.f90 (code 1)",
  ].join("\n");
  assert.deepEqual(parseIntel(out).map(brief), [
    "test.f90:3:3 error: This name does not have a type, and must have an explicit type.   [X] [6404]",
    "C:\\work\\test.f90:7:7 warning: This name has not been given an explicit type.   [Y] [6717]",
    "test.f90:9:- info: This variable has not been used.   [Z] [7712]",
    "test.f90:2:- error: unsupported configuration",
    "test.f90:12:- error: Too many errors, exiting",
  ]);
});

// --- NAG --------------------------------------------------------------------

test("nagfor messages", () => {
  const out = [
    "Error: test.f90, line 4: Implicit type for Y in MAIN",
    "       detected at Y@=",
    "Warning: test.f90, line 6: Unused local variable X",
    "Extension(F2008): test.f90, line 8: Unlimited format item",
    "Questionable: sub.f90, line 10: Variable K set but never referenced",
    "Deleted feature used: old.f, line 12: Assigned GOTO statement",
    "Fatal Error: test.f90, line 2: Cannot find module FOO",
    "[NAG Fortran Compiler error termination, 2 errors, 1 warning]",
  ].join("\n");
  assert.deepEqual(parseNag(out).map(brief), [
    "test.f90:4:- error: Implicit type for Y in MAIN (detected at Y@=)",
    "test.f90:6:- warning: Unused local variable X",
    "test.f90:8:- warning: Unlimited format item",
    "sub.f90:10:- warning: Variable K set but never referenced",
    "old.f:12:- warning: Assigned GOTO statement",
    "test.f90:2:- error: Cannot find module FOO",
  ]);
});

// --- LFortran ---------------------------------------------------------------

test("lfortran --error-format=short messages", () => {
  const out = [
    "test.f90:3-3:5-7: semantic error: Variable 'abc' is not declared",
    "test.f90:5-6:1-10: syntax error: Token 'end' is unexpected here",
    "test.f90:8-8:3-3: warning: The variable 'x' is used before it is set",
    "test.f90:9-9:3-9: style suggestion: Use '**' instead",
    "C preprocessor error: cannot open 'x.h'",
  ].join("\n");
  const parsed = parseLfortran(out);
  assert.deepEqual(parsed.map(brief), [
    "test.f90:3:5 error: Variable 'abc' is not declared",
    "test.f90:5:1 error: Token 'end' is unexpected here",
    "test.f90:8:3 warning: The variable 'x' is used before it is set",
    "test.f90:9:3 hint: Use '**' instead",
    "-:0:- error: cannot open 'x.h'",
  ]);
  assert.equal(parsed[1].endLine, 6);
  assert.equal(parsed[1].endColumn, 10);
});

// --- nvfortran --------------------------------------------------------------

test("nvfortran messages", () => {
  const out = [
    "NVFORTRAN-S-0034-Syntax error at or near end of line (test.f90: 3)",
    "NVFORTRAN-W-0155-Unused variable x (test.f90: 7)",
    "NVFORTRAN-F-0004-Unable to open MODULE file foo.mod (use.f90: 2)",
    "NVFORTRAN-I-0035-Predefined intrinsic sum loses intrinsic property (test.f90: 9:12)",
    "PGF90-S-0038-Symbol, y, has not been explicitly declared (old.f90: 4)",
    "  0 inform,   1 warnings,   1 severes, 0 fatal for main",
  ].join("\n");
  assert.deepEqual(parseNvfortran(out).map(brief), [
    "test.f90:3:- error: Syntax error at or near end of line [0034]",
    "test.f90:7:- warning: Unused variable x [0155]",
    "use.f90:2:- error: Unable to open MODULE file foo.mod [0004]",
    "test.f90:9:12 info: Predefined intrinsic sum loses intrinsic property [0035]",
    "old.f90:4:- error: Symbol, y, has not been explicitly declared [0038]",
  ]);
});

// --- flang ------------------------------------------------------------------

test("flang messages and their context lines", () => {
  const out = [
    "error: Semantic errors in test.f90",
    "./test.f90:3:3: error: No explicit type declared for 'x'",
    "    x = 1",
    "    ^",
    "./test.f90:5:7: error: 'y' is already declared in this scoping unit",
    "    real :: y",
    "            ^",
    "./test.f90:4:14: Previous declaration of 'y'",
    "./test.f90:8:1: portability: nonstandard usage: tab character",
    "./test.f90:9:3: warning: Variable 'z' is used but never defined [-Wused-undefined-variable]",
    "flang: error: unknown argument: '-Wbogus'",
  ].join("\n");
  const parsed = parseFlang(out);
  assert.deepEqual(parsed.map(brief), [
    "./test.f90:3:3 error: No explicit type declared for 'x'",
    "./test.f90:5:7 error: 'y' is already declared in this scoping unit",
    "./test.f90:8:1 warning: portability: nonstandard usage: tab character",
    "./test.f90:9:3 warning: Variable 'z' is used but never defined [-Wused-undefined-variable]",
    "-:0:- error: flang: unknown argument: '-Wbogus'",
  ]);
  assert.deepEqual(parsed[1].related, [
    { file: "./test.f90", line: 4, column: 14, message: "Previous declaration of 'y'" },
  ]);
});

test("dedupe drops repeated messages", () => {
  const out = "a.f90:1:2: Error: x\na.f90:1:2: Error: x\na.f90:1:3: Error: x\n";
  assert.equal(dedupe(parseGfortran(out)).length, 2);
});

// --- flags ------------------------------------------------------------------

test("every compiler checks syntax only and writes .mod files to the given directory", () => {
  for (const platform of ["linux", "win32"]) {
    const o = { platform, modDir: "/tmp/mods" };
    for (const spec of Object.values(COMPILERS)) {
      assert.ok(spec.syntaxOnly(o).length > 0, spec.id);
      assert.ok(spec.modOutput("/tmp/mods", o).join(" ").includes("/tmp/mods"), spec.id);
      assert.ok(spec.fixed(o).length > 0, spec.id);
    }
  }
  const linux = { platform: "linux", modDir: "/m" };
  assert.deepEqual(COMPILERS.ifx.syntaxOnly(linux), ["-syntax-only"]);
  assert.deepEqual(COMPILERS.ifx.modOutput("/m", { platform: "win32", modDir: "/m" }), ["/module:/m"]);
  assert.deepEqual(COMPILERS.gfortran.fixed(linux), ["-ffixed-form"]);
  assert.deepEqual(COMPILERS.flang.executables, ["flang", "flang-new"]);
});

// --- paths ------------------------------------------------------------------

test("variables in path settings", () => {
  const ctx = {
    folders: [{ name: "app", path: "/w/app" }, { name: "lib", path: "/w/lib" }],
    folder: { name: "lib", path: "/w/lib" },
    file: "/w/lib/src/m.f90",
    env: { FOO: "bar" },
  };
  assert.equal(resolveVariables("${workspaceFolder}/inc", ctx), "/w/lib/inc");
  assert.equal(resolveVariables("${workspaceFolder:app}/inc", ctx), "/w/app/inc");
  assert.equal(resolveVariables("${env:FOO}/x", ctx), "bar/x");
  assert.equal(resolveVariables("${fileDirname}|${fileBasenameNoExtension}", ctx), "/w/lib/src|m");
  assert.equal(resolveVariables("${unknown}", ctx), "${unknown}");
  assert.equal(resolveVariables("~/mods", ctx), os.homedir() + "/mods");
  assert.equal(resolveVariables("a~b", ctx), "a~b");
});

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

test("findExecutable and samePath", () => {
  assert.equal(findExecutable("zfls-no-such-program-xyz"), undefined);
  assert.ok(findExecutable(process.execPath));
  assert.ok(samePath("/a/b/../c", "/a/c"));
});

// --- sources ----------------------------------------------------------------

test("modules defined and used", () => {
  const text = [
    "module geometry  ! shapes",
    "  use, intrinsic :: iso_fortran_env",
    "  use iso_c_binding",
    "  use :: constants, only: pi",
    "  use Kinds",
    "  use geometry_helpers",
    "  interface",
    "    module procedure area",
    "  end interface",
    "end module geometry",
    "submodule (geometry) geometry_impl",
    "end submodule",
    "program p",
    "  use geometry",
    "  ! use commented_out",
    "end program",
  ].join("\n");
  const scan = scanModules(text);
  assert.deepEqual(scan.defines, ["geometry"]);
  assert.deepEqual(scan.uses.sort(), ["constants", "geometry_helpers", "kinds"]);
});

test("INCLUDE lines and #include directives", () => {
  const text = "program p\n  include 'inc.h'\n#include \"cinc.h\"\n  INCLUDE \"dir/x.inc\"\nend program\n";
  assert.deepEqual(findIncludes(text), [
    { line: 1, name: "inc.h", start: 2, end: 17 },
    { line: 2, name: "cinc.h", start: 0, end: 17 },
    { line: 3, name: "dir/x.inc", start: 2, end: 21 },
  ]);
});

// --- a real gfortran, when there is one -------------------------------------

test("gfortran's real output parses", (t) => {
  const exe = findExecutable("gfortran");
  if (!exe) {
    t.skip("no gfortran on the PATH");
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-gfortran-"));
  try {
    fs.writeFileSync(path.join(dir, "inc.h"), "  k = undefined_thing + 1\n");
    fs.writeFileSync(path.join(dir, "main.f90"),
      "program main\n  implicit none\n  integer :: i, k\n  include 'inc.h'\n  i = j + 1\n  print *, i, k\nend program\n");
    fs.writeFileSync(path.join(dir, "fixed.f"), "      program fx\n      implicit none\n      integer i\n      i = q\n      end\n");
    const o = { platform: process.platform, modDir: dir };
    const spec = COMPILERS.gfortran;
    const run = (file: string, form: string[]): string => {
      const env = { ...process.env, LC_ALL: "C", PATH: path.dirname(exe) + path.delimiter + (process.env.PATH ?? "") };
      const r = cp.spawnSync(exe, [...spec.syntaxOnly(o), ...spec.preprocess(o), ...form, ...spec.defaultArgs(o),
        ...spec.modOutput(dir, o), file], { cwd: dir, env, encoding: "utf8" });
      return r.stdout + r.stderr;
    };
    assert.deepEqual(parseGfortran(run("main.f90", spec.free(o))).map(brief), [
      "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
      "inc.h:1:21 error: Symbol 'undefined_thing' at (1) has no IMPLICIT type",
    ]);
    assert.deepEqual(parseGfortran(run("fixed.f", spec.fixed(o))).map(brief), [
      "fixed.f:4:11 error: Symbol 'q' at (1) has no IMPLICIT type",
    ]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
