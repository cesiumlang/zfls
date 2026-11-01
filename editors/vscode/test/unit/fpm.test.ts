// Plain Node.js tests (no VS Code) of the fpm support: fpm.toml, fpm's
// arguments and output, test-drive's tests and results: `npm run unit`.

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
  selectsTests,
  sourcesOfTarget,
  targetOfFile,
  taskArgs,
  testDriveDefs,
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

test("the source of a target", () => {
  const m = parseManifest(MANIFEST);
  assert.deepEqual(sourcesOfTarget(m, { kind: "test", name: "unit" }), {
    file: path.join("tests/unit", "main.f90"),
    dir: "tests/unit",
  });
  assert.deepEqual(sourcesOfTarget(m, { kind: "test", name: "check" }), { dir: "test", stem: "check" });
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

const SUITE = `module suite_math
  use testdrive, only : new_unittest, unittest_type, error_type, check
contains
  subroutine collect_math(testsuite)
    type(unittest_type), allocatable, intent(out) :: testsuite(:)
    testsuite = [ &
      new_unittest("adds", test_adds), &
      ! new_unittest("commented", test_x), &
      new_unittest('fails', test_fails, should_fail=.true.) &
      ]
  end subroutine collect_math
end module
program tester
  use testdrive, only : run_testsuite, new_testsuite, testsuite_type
  testsuites = [new_testsuite("math", collect_math), &
    new_testsuite("Strings", Collect_Strings)]
end program
`;

test("test-drive's suites and tests in the sources", () => {
  assert.deepEqual(testDriveDefs(SUITE), {
    suites: [
      { name: "math", collect: "collect_math", line: 14 },
      { name: "Strings", collect: "collect_strings", line: 15 },
    ],
    tests: [
      { name: "adds", line: 6, collect: "collect_math" },
      { name: "fails", line: 8, collect: "collect_math" },
    ],
  });
  assert.equal(selectsTests(SUITE), false);
  assert.equal(selectsTests("is = select_suite(testsuites, name)\ncall run_selected(testsuites(is)%collect, t, u, stat)"), true);
});
