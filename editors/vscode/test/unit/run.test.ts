// Plain Node.js tests (no VS Code) of the run and debug helpers:
// `npm run unit`.

import * as assert from "node:assert/strict";
import * as path from "node:path";
import { test } from "node:test";
import {
  buildArgs,
  chooseDebugger,
  compilerKind,
  compilerName,
  fortranLaunch,
  launchConfiguration,
  outputDirFor,
  programPath,
  runtimeEnv,
  upsertByKey,
  workspaceRelative,
} from "../../src/run";

test("compiler names", () => {
  assert.equal(compilerName("gfortran"), "gfortran");
  assert.equal(compilerName("/usr/bin/gfortran-14"), "gfortran");
  assert.equal(compilerName("C:\\oneAPI\\bin\\ifx.exe"), "ifx");
  assert.equal(compilerName("flang-new-19"), "flang-new");
  assert.equal(compilerName("x86_64-w64-mingw32-gfortran.exe"), "x86_64-w64-mingw32-gfortran");
});

test("compiler kinds", () => {
  assert.deepEqual(compilerKind("ifx", "win32"), { argStyle: "intel-windows", msvc: true, defaultArgs: ["/Zi", "/Od"] });
  assert.deepEqual(compilerKind("ifx", "linux"), { argStyle: "gnu", msvc: false, defaultArgs: ["-g", "-O0"] });
  assert.equal(compilerKind("gfortran.exe", "win32").msvc, false);
  assert.equal(compilerKind("flang-new", "win32").msvc, true);
  assert.equal(compilerKind("flang", "darwin").msvc, false);
  assert.deepEqual(compilerKind("lfortran", "linux").defaultArgs, ["-g"]);
});

test("build arguments, GNU style", () => {
  const src = path.join("/p", "src", "main.f90");
  const exe = path.join("/out", "main");
  assert.deepEqual(buildArgs(compilerKind("gfortran", "linux"), src, exe, undefined), [
    "-g",
    "-O0",
    `-I${path.dirname(src)}`,
    "-o",
    exe,
    src,
  ]);
  assert.deepEqual(buildArgs(compilerKind("gfortran", "linux"), src, exe, ["-O2", "-fcheck=all"]), [
    "-O2",
    "-fcheck=all",
    `-I${path.dirname(src)}`,
    "-o",
    exe,
    src,
  ]);
  assert.deepEqual(buildArgs(compilerKind("gfortran", "linux"), src, exe, []), [`-I${path.dirname(src)}`, "-o", exe, src]);
});

test("build arguments, Intel on Windows", () => {
  const src = path.join("C:", "p q", "main.f90");
  const exe = path.join("C:", "out", "main.exe");
  assert.deepEqual(buildArgs(compilerKind("ifx", "win32"), src, exe, undefined), [
    "/nologo",
    "/Zi",
    "/Od",
    `/I${path.dirname(src)}`,
    `/exe:${exe}`,
    src,
  ]);
});

test("each source gets its own output directory", () => {
  const base = "/storage/run";
  const a = outputDirFor(base, "/p/a/main.f90", "linux");
  const b = outputDirFor(base, "/p/b/main.f90", "linux");
  assert.notEqual(a, b);
  assert.equal(path.posix.dirname(a), base);
  assert.match(path.posix.basename(a), /^main-[0-9a-f]{10}$/);
  assert.equal(a, outputDirFor(base, "/p/a/main.f90", "linux"));
  // Windows paths that differ only in case are the same file
  const win = outputDirFor("C:\\storage", "C:\\P\\main.f90", "win32");
  assert.equal(win, outputDirFor("C:\\storage", "c:\\p\\main.f90", "win32"));
  assert.match(win, /^C:\\storage\\main-[0-9a-f]{10}$/);
  assert.equal(programPath("/out", "/p/hello.F90", "linux"), "/out/hello");
  assert.equal(programPath("C:\\out", "C:\\p\\hello.f", "win32"), "C:\\out\\hello.exe");
});

test("the first installed debugger is used", () => {
  const has = (...ids: string[]) => (id: string) => ids.includes(id);
  assert.deepEqual(chooseDebugger("auto", has("ms-vscode.cpptools", "vadimcn.vscode-lldb"), false), { type: "cppdbg" });
  assert.deepEqual(chooseDebugger("auto", has("ms-vscode.cpptools"), true), { type: "cppvsdbg" });
  assert.deepEqual(chooseDebugger("auto", has("vadimcn.vscode-lldb"), false), { type: "lldb" });
  assert.deepEqual(chooseDebugger("auto", has("eclipse-cdt.cdt-gdb-vscode"), false), { type: "gdb" });
  assert.deepEqual(chooseDebugger("lldb", has("ms-vscode.cpptools", "vadimcn.vscode-lldb"), false), { type: "lldb" });
});

test("a missing debugger names the extensions to install", () => {
  const none = () => false;
  const gnu = chooseDebugger("auto", none, false);
  assert.ok("missing" in gnu);
  assert.deepEqual(gnu.extensions, ["ms-vscode.cpptools", "vadimcn.vscode-lldb", "eclipse-cdt.cdt-gdb-vscode"]);
  const msvc = chooseDebugger("auto", (id) => id === "vadimcn.vscode-lldb", true);
  assert.ok("missing" in msvc);
  assert.deepEqual(msvc.extensions, ["ms-vscode.cpptools"]);
  const chosen = chooseDebugger("gdb", (id) => id === "ms-vscode.cpptools", false);
  assert.ok("missing" in chosen);
  assert.deepEqual(chosen.extensions, ["eclipse-cdt.cdt-gdb-vscode"]);
});

const spec = {
  name: "Debug main.f90",
  program: "/out/main",
  args: ["in put.txt", "-v"],
  cwd: "/p",
  env: {},
  platform: "linux" as NodeJS.Platform,
};

test("cppdbg launch configuration", () => {
  const config = launchConfiguration({ ...spec, type: "cppdbg", gdbPath: "/usr/bin/gdb", preLaunchTask: "build" });
  assert.equal(config.type, "cppdbg");
  assert.equal(config.request, "launch");
  assert.equal(config.MIMode, "gdb");
  assert.equal(config.miDebuggerPath, "/usr/bin/gdb");
  assert.deepEqual(config.args, spec.args);
  assert.equal(config.preLaunchTask, "build");
  assert.equal(config.environment, undefined);
  const mac = launchConfiguration({ ...spec, type: "cppdbg", platform: "darwin", gdbPath: "/x/gdb" });
  assert.equal(mac.MIMode, "lldb");
  assert.equal(mac.miDebuggerPath, undefined);
});

test("other launch configurations", () => {
  const env = { Path: "C:\\mingw\\bin;C:\\Windows" };
  const vs = launchConfiguration({ ...spec, type: "cppvsdbg", env, platform: "win32" });
  assert.deepEqual(vs.environment, [{ name: "Path", value: env.Path }]);
  assert.equal(vs.console, "integratedTerminal");
  const lldb = launchConfiguration({ ...spec, type: "lldb", env });
  assert.deepEqual(lldb.env, env);
  assert.deepEqual(lldb.args, spec.args);
  const gdb = launchConfiguration({ ...spec, type: "gdb", gdbPath: "/opt/gdb" });
  assert.equal(gdb.arguments, '"in put.txt" -v');
  assert.equal(gdb.gdb, "/opt/gdb");
});

test("the compiler's directory goes on the PATH on Windows", () => {
  const compiler = "C:\\mingw64\\bin\\gfortran.exe";
  assert.deepEqual(runtimeEnv(compiler, "linux", { PATH: "/usr/bin" }), {});
  assert.deepEqual(runtimeEnv(compiler, "win32", { Path: "C:\\Windows" }), { Path: "C:\\mingw64\\bin;C:\\Windows" });
  assert.deepEqual(runtimeEnv(compiler, "win32", { Path: "C:\\MinGW64\\bin\\;C:\\Windows" }), {});
});

test("entries are replaced by name", () => {
  const list = [{ name: "a", v: 1 }, { name: "b", v: 1 }];
  assert.deepEqual(upsertByKey(list, { name: "a", v: 2 }, "name"), [{ name: "a", v: 2 }, { name: "b", v: 1 }]);
  assert.deepEqual(upsertByKey(list, { name: "c", v: 2 }, "name"), [...list, { name: "c", v: 2 }]);
});

test("paths in the workspace folder use ${workspaceFolder}", () => {
  const ws = path.resolve("/ws");
  assert.equal(workspaceRelative(path.join(ws, "src", "a.f90"), ws), "${workspaceFolder}/src/a.f90");
  assert.equal(workspaceRelative(ws, ws), "${workspaceFolder}");
  const outside = path.resolve("/elsewhere/a.f90");
  assert.equal(workspaceRelative(outside, ws), outside);
  assert.equal(workspaceRelative(outside, undefined), outside);
});

test("a fortran configuration becomes the chosen debugger's", () => {
  const config = {
    type: "fortran",
    request: "launch",
    name: "Debug solver",
    program: "/w/solver",
    args: ["-n", "3"],
    env: { OMP_NUM_THREADS: "2" },
    stopAtEntry: true,
    debugger: "auto",
    // the debugger's own keys pass through
    setupCommands: [{ text: "set print pretty on" }],
  };
  const r = { type: "cppdbg" as const, program: "/w/solver", cwd: "/w", runtimeEnv: {}, platform: "linux" as const, gdbPath: "/usr/bin/gdb" };
  const cpp = fortranLaunch(config, r);
  assert.equal(cpp.type, "cppdbg");
  assert.equal(cpp.request, "launch");
  assert.equal(cpp.program, "/w/solver");
  assert.deepEqual(cpp.args, ["-n", "3"]);
  assert.equal(cpp.stopAtEntry, true);
  assert.equal(cpp.miDebuggerPath, "/usr/bin/gdb");
  assert.deepEqual(cpp.environment, [{ name: "OMP_NUM_THREADS", value: "2" }]);
  assert.deepEqual(cpp.setupCommands, [{ text: "set print pretty on" }]);
  assert.equal(cpp.debugger, undefined);
  const lldb = fortranLaunch(config, { ...r, type: "lldb" });
  assert.equal(lldb.stopOnEntry, true);
  assert.equal(lldb.stopAtEntry, undefined);
  // the compiler's runtime PATH first, the configuration's own over it
  const win = fortranLaunch({ ...config, env: { Path: "C:\mine" } }, { ...r, type: "cppvsdbg", platform: "win32", runtimeEnv: { Path: "C:\gcc\bin;C:\Windows" } });
  assert.deepEqual(win.environment, [{ name: "Path", value: "C:\mine" }]);
});
