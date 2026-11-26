// Plain Node.js tests (no VS Code) of the run and debug helpers:
// `npm run unit`. zfls's answer to `zfls/buildCommand` (the compiler's
// arguments, the output directory, the kit's link) is tested in Zig
// (src/run/, tests/issues/build_command.zig).

import * as assert from "node:assert/strict";
import * as path from "node:path";
import { test } from "node:test";
import {
  adapterArgs,
  chooseDebugger,
  fortranLaunch,
  launchConfiguration,
  parseProcesses,
  upsertByKey,
  workspaceRelative,
} from "../../src/run";

test("the first installed debugger is used", () => {
  const has = (...ids: string[]) => (id: string) => ids.includes(id);
  assert.deepEqual(chooseDebugger("auto", has("ms-vscode.cpptools", "vadimcn.vscode-lldb"), false), { type: "cppdbg" });
  assert.deepEqual(chooseDebugger("auto", has("ms-vscode.cpptools"), true), { type: "cppvsdbg" });
  assert.deepEqual(chooseDebugger("auto", has("vadimcn.vscode-lldb"), false), { type: "lldb" });
  assert.deepEqual(chooseDebugger("auto", has("eclipse-cdt.cdt-gdb-vscode"), false), { type: "gdb" });
  assert.deepEqual(chooseDebugger("lldb", has("ms-vscode.cpptools", "vadimcn.vscode-lldb"), false), { type: "lldb" });
});

test("zfls's debugger, when there is a gdb of the Debug Adapter Protocol", () => {
  const cpptools = (id: string) => id === "ms-vscode.cpptools";
  assert.deepEqual(chooseDebugger("auto", cpptools, false, true), { type: "zfls" });
  assert.deepEqual(chooseDebugger("auto", cpptools, false, false), { type: "cppdbg" });
  // gdb cannot read MSVC-ABI debug information
  assert.deepEqual(chooseDebugger("auto", cpptools, true, true), { type: "cppvsdbg" });
  assert.deepEqual(chooseDebugger("zfls", cpptools, false, true), { type: "zfls" });
  assert.deepEqual(chooseDebugger("zfls", cpptools, false, false), { missing: "zfls", extensions: [] });
  assert.deepEqual(chooseDebugger("zfls", cpptools, true, true), { missing: "zfls", extensions: [] });
  // a debugger configured is used
  assert.deepEqual(chooseDebugger("cppdbg", cpptools, false, true), { type: "cppdbg" });
  // MSVC-ABI programs on Windows: zfls's debugger of Windows's Debugger Engine
  assert.deepEqual(chooseDebugger("auto", cpptools, true, false, true), { type: "zfls" });
  assert.deepEqual(chooseDebugger("zfls", () => false, true, false, true), { type: "zfls" });
  assert.deepEqual(chooseDebugger("cppvsdbg", cpptools, true, false, true), { type: "cppvsdbg" });
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

test("zfls's launch configuration: the fortran type, resolved", () => {
  const z = launchConfiguration({ ...spec, type: "zfls", gdbPath: "/opt/gdb", env: { A: "1" }, console: "integratedTerminal" });
  assert.equal(z.type, "fortran");
  assert.equal(z.debugger, "zfls");
  assert.equal(z.gdb, "/opt/gdb");
  assert.deepEqual(z.args, spec.args);
  assert.deepEqual(z.env, { A: "1" });
  assert.equal(z.console, "integratedTerminal");
  // a terminal for the program, as each debugger names it
  assert.equal(launchConfiguration({ ...spec, type: "cppdbg", console: "externalTerminal" }).externalConsole, true);
  assert.equal(launchConfiguration({ ...spec, type: "cppdbg" }).externalConsole, false);
  assert.equal(launchConfiguration({ ...spec, type: "lldb", console: "integratedTerminal" }).terminal, "integrated");
  assert.equal(launchConfiguration({ ...spec, type: "cppvsdbg", console: "externalTerminal" }).console, "externalTerminal");
});

test("zfls's debugger of an MSVC-ABI program: zfls dap", () => {
  const z = launchConfiguration({ ...spec, type: "zfls", gdbPath: "/opt/gdb", msvc: true, sourceRoot: "/w" });
  assert.equal(z.type, "fortran");
  assert.equal(z.dbgeng, true);
  assert.equal(z.gdb, undefined);
  assert.equal(z.sourceRoot, "/w");
  const g = launchConfiguration({ ...spec, type: "zfls", gdbPath: "/opt/gdb" });
  assert.equal(g.dbgeng, undefined);
  assert.equal(g.gdb, "/opt/gdb");
});

test("the processes to attach to", () => {
  const win = parseProcesses('"System","4","Services","0","24 K"\r\n"prog.exe","1234","Console","1","3,000 K"\r\n', "win32");
  assert.deepEqual(win[1], { pid: 1234, name: "prog.exe", command: "prog.exe" });
  const ps = parseProcesses("    1 /sbin/init splash\n 4242 /home/me/solver -n 3\n", "linux");
  assert.deepEqual(ps[1], { pid: 4242, name: "solver", command: "/home/me/solver -n 3" });
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
  const pretty = { description: "Enable pretty-printing for gdb", text: "-enable-pretty-printing", ignoreFailures: true };
  assert.deepEqual(cpp.setupCommands, [pretty, { text: "set print pretty on" }]);
  // the fortran type's setupCommands are strings, which C/C++ refuses (#797)
  const strings = fortranLaunch({ ...config, setupCommands: ["set print elements 0"] }, r);
  assert.deepEqual(strings.setupCommands, [pretty, { text: "set print elements 0" }]);
  assert.equal(cpp.debugger, undefined);
  const lldb = fortranLaunch(config, { ...r, type: "lldb" });
  assert.equal(lldb.stopOnEntry, true);
  assert.equal(lldb.stopAtEntry, undefined);
  // the compiler's runtime PATH first, the configuration's own over it
  const win = fortranLaunch({ ...config, env: { Path: "C:\mine" } }, { ...r, type: "cppvsdbg", platform: "win32", runtimeEnv: { Path: "C:\gcc\bin;C:\Windows" } });
  assert.deepEqual(win.environment, [{ name: "Path", value: "C:\mine" }]);
  // zfls's: still the fortran type, with what its debugger takes
  const z = fortranLaunch({ ...config, console: "integratedTerminal" }, { ...r, type: "zfls" });
  assert.equal(z.type, "fortran");
  assert.equal(z.debugger, "zfls");
  assert.equal(z.gdb, "/usr/bin/gdb");
  assert.equal(z.stopAtEntry, true);
  assert.equal(z.console, "integratedTerminal");
  assert.deepEqual(z.env, { OMP_NUM_THREADS: "2" });
  assert.deepEqual(z.setupCommands, [{ text: "set print pretty on" }]);
  // resolved again (Debug Fortran File starts a fortran configuration): the same
  assert.deepEqual(fortranLaunch(z, { ...r, type: "zfls" }), z);
});

test("zfls dap's debugger: the configuration's, else zfls dap's choice", () => {
  // none named: zfls dap chooses by the program, else the platform's
  assert.deepEqual(adapterArgs({}), []);
  assert.deepEqual(adapterArgs({ gdb: "/opt/gdb" }), ["--gdb", "/opt/gdb"]);
  assert.deepEqual(adapterArgs({ lldb: false }), ["--gdb", "gdb"]);
  assert.deepEqual(adapterArgs({ lldb: true }), ["--lldb"]);
  assert.deepEqual(adapterArgs({ lldb: "/opt/llvm/bin/lldb-dap", gdb: "gdb" }), ["--lldb", "/opt/llvm/bin/lldb-dap"]);
  assert.deepEqual(adapterArgs({ dbgeng: true, lldb: true }), ["--dbgeng"]);
  // the launch configuration says lldb, not gdb
  const z = launchConfiguration({ ...spec, type: "zfls", gdbPath: "/opt/gdb", lldb: true });
  assert.equal(z.lldb, true);
  assert.equal(z.gdb, undefined);
});
