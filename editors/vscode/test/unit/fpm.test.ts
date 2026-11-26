// Plain Node.js tests (no VS Code) of the fpm support: fpm's arguments and
// output, test-drive's results: `npm run unit`. zfls reads fpm.toml and
// finds the targets and tests (src/fpm.zig, tests/issues/fpm_targets.zig).

import * as assert from "node:assert/strict";
import { test } from "node:test";
import {
  FPM_FLANG_DWARF_FLAGS,
  fpmDwarfFlags,
  listArgs,
  parseList,
  parseRunnerEcho,
  parseTestDrive,
  runArgs,
  targetOfFile,
  taskArgs,
} from "../../src/fpm";

test("the target of a main program, among those zfls found", () => {
  const targets = [
    { kind: "executable" as const, name: "second", main: "/p/app2/main.f90" },
    { kind: "test" as const, name: "check", main: "/p/test/sub/check.F90" },
  ];
  assert.deepEqual(targetOfFile(targets, "/p/app2/main.f90", "linux"), { kind: "executable", name: "second" });
  assert.deepEqual(targetOfFile(targets, "/p/test/sub/../sub/check.F90", "linux"), { kind: "test", name: "check" });
  assert.equal(targetOfFile(targets, "/p/src/lib.f90", "linux"), undefined);
  // without case on Windows
  assert.deepEqual(targetOfFile([{ kind: "test", name: "t", main: "C:\\P\\test\\t.f90" }], "c:\\p\\test\\T.F90", "win32"), { kind: "test", name: "t" });
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

test("a debug build's flags: DWARF for LLVM Flang on Windows, unless asked for (#430)", () => {
  const flang = { name: "flang", debugInfo: "dwarf" } as const;
  assert.equal(fpmDwarfFlags(undefined, flang, "win32"), FPM_FLANG_DWARF_FLAGS);
  assert.equal(fpmDwarfFlags("-O1", flang, "win32"), "-O1 -gdwarf-4 -Wl,-debug:dwarf");
  assert.equal(fpmDwarfFlags("-gdwarf-5 -Wl,-debug:dwarf", flang, "win32"), "-gdwarf-5 -Wl,-debug:dwarf");
  // without lld-link, zfls says Microsoft's debug information
  assert.equal(fpmDwarfFlags(undefined, { name: "flang", debugInfo: "pdb" }, "win32"), undefined);
  // elsewhere, and other compilers: as they are
  assert.equal(fpmDwarfFlags(undefined, flang, "linux"), undefined);
  assert.equal(fpmDwarfFlags("-g", { name: "gfortran", debugInfo: "dwarf" }, "win32"), "-g");
  assert.equal(fpmDwarfFlags(undefined, { name: "ifx", debugInfo: "pdb" }, "win32"), undefined);
  assert.equal(fpmDwarfFlags(undefined, undefined, "win32"), undefined);
});
