// Plain Node.js tests (no VS Code) of the fpm support: fpm.toml, fpm's
// arguments and output, test-drive's results: `npm run unit`. zfls finds
// the tests (src/fpm.zig).

import * as assert from "node:assert/strict";
import * as path from "node:path";
import { test } from "node:test";
import {
  listArgs,
  parseList,
  parseManifest,
  parseRunnerEcho,
  parseTestDrive,
  runArgs,
  targetOfFile,
  taskArgs,
} from "../../src/fpm";

const MANIFEST = `
name = "demo"   # the package
version = "0.1.0"

[build]
auto-examples = false

[[executable]]
name = "second"
source-dir = "app2"
main = "main.f90"

[[test]]
name = 'unit'
source-dir = "tests/unit"

[dev-dependencies]
test-drive.git = "https://github.com/fortran-lang/test-drive"
`;

test("fpm.toml: the name, the targets and the auto-discovery switches", () => {
  const m = parseManifest(MANIFEST);
  assert.equal(m.name, "demo");
  assert.deepEqual(m.targets, [
    { kind: "executable", name: "second", sourceDir: "app2", main: "main.f90" },
    { kind: "test", name: "unit", sourceDir: "tests/unit", main: "main.f90" },
  ]);
  assert.deepEqual(m.auto, { executable: true, test: true, example: false });
});

test("the target of a main program", () => {
  const m = parseManifest(MANIFEST);
  const root = path.posix.join("/", "p");
  const of = (f: string): unknown => targetOfFile(m, root, path.posix.join(root, f), path.posix);
  assert.deepEqual(of("app2/main.f90"), { kind: "executable", name: "second" });
  assert.deepEqual(of("tests/unit/main.f90"), { kind: "test", name: "unit" });
  // found by fpm: named after the file
  assert.deepEqual(of("app/tool.f90"), { kind: "executable", name: "tool" });
  assert.deepEqual(of("test/sub/check.F90"), { kind: "test", name: "check" });
  // auto-examples = false; a library file
  assert.equal(of("example/ex1.f90"), undefined);
  assert.equal(of("src/lib.f90"), undefined);
  assert.equal(of("app.f90"), undefined);
});

test("the arguments of fpm's commands", () => {
  assert.deepEqual(listArgs("example"), ["run", "--example", "--list"]);
  assert.deepEqual(runArgs({ kind: "test", name: "check" }, {}, ["math", "adds"]), [
    "test",
    "check",
    "--",
    "math",
    "adds",
  ]);
  assert.deepEqual(runArgs({ kind: "example", name: "ex1" }, { profile: "release" }, [], "echo"), [
    "run",
    "--example",
    "ex1",
    "--profile",
    "release",
    "--runner",
    "echo",
  ]);
});

test("a task's arguments: its own options before the settings'", () => {
  const settings = { profile: "release", compiler: "ifx", args: ["--verbose"] };
  assert.deepEqual(taskArgs({ command: "build", profile: "debug" }, settings), [
    "build",
    "--profile",
    "debug",
    "--compiler",
    "ifx",
    "--verbose",
  ]);
  assert.deepEqual(taskArgs({ command: "run", target: "ex1", example: true, programArgs: ["-n", "3"] }, {}), [
    "run",
    "--example",
    "ex1",
    "--",
    "-n",
    "3",
  ]);
  assert.deepEqual(taskArgs({ command: "test", flags: "-O2 -g" }, {}), ["test", "--flag", "-O2 -g"]);
  assert.deepEqual(taskArgs({ command: "clean" }, settings), ["clean", "--skip"]);
});

// as fpm 0.13.0 prints them
test("fpm's lists and program paths", () => {
  assert.deepEqual(parseList(" Matched names:\nmain        second      \n"), ["main", "second"]);
  assert.deepEqual(parseList("<ERROR> no such target\n"), []);
  const echo = [
    "fpm_strings.f90                        done.",
    "[ 50%] Compiling...",
    "[100%] Project compiled successfully.",
    "build\\gfortran_A86CEF2075723C1E\\app\\main.exe",
    "build\\gfortran_A86CEF2075723C1E\\app\\second.exe",
    "",
  ].join("\r\n");
  assert.deepEqual(parseRunnerEcho(echo), [
    "build\\gfortran_A86CEF2075723C1E\\app\\main.exe",
    "build\\gfortran_A86CEF2075723C1E\\app\\second.exe",
  ]);
  assert.deepEqual(parseRunnerEcho("Project is up to date\nbuild/gfortran_1/test/check\n"), [
    "build/gfortran_1/test/check",
  ]);
});

// as test-drive 0.5.0 prints them
test("test-drive's results", () => {
  const output = [
    "Project is up to date",
    "# Testing: math",
    "  Starting adds ... (1/3)",
    "       ... adds [PASSED]",
    "  Starting fails ... (2/3)",
    "       ... fails [FAILED]",
    "  Message: math is broken",
    "  Starting bad_expected ... (3/3)",
    "       ... bad_expected [EXPECTED FAIL]",
    "  Message: math is broken",
    "# Testing: strings",
    "  Starting later ... (1/1)",
    "       ... later [SKIPPED]",
    "1 test(s) failed!",
    "ERROR STOP",
  ].join("\n");
  assert.deepEqual(parseTestDrive(output), [
    { suite: "math", name: "adds", status: "passed" },
    { suite: "math", name: "fails", status: "failed", message: "math is broken" },
    { suite: "math", name: "bad_expected", status: "expected-fail", message: "math is broken" },
    { suite: "strings", name: "later", status: "skipped" },
  ]);
});
