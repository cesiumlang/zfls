// Tests of the zfls command line and the settings sent over LSP that the
// zfls.* settings become (src/options.ts), with plain Node.js and a
// stand-in for VS Code's settings (test/unit/vscode.ts):
//   npm run unit

import * as assert from "node:assert/strict";
import * as path from "node:path";
import { afterEach, test } from "node:test";
import type * as vscode from "vscode";
import { argOption, restartsServer, serverArguments, serverSettings, startSettings } from "../../src/options";
import { settings, workspace } from "./vscode";

const root = path.join("/", "my proj");
const folder = { name: "my proj", index: 0, uri: { fsPath: root } } as unknown as vscode.WorkspaceFolder;

afterEach(() => {
  for (const key of Object.keys(settings)) {
    delete settings[key];
  }
});

test("an argument with a space stays one, on the command line and over LSP", () => {
  settings["zfls.linter.extraArgs"] = ["-Wall", "-I${workspaceFolder}/inc"];
  const inc = `-I${root}/inc`;
  assert.deepEqual(serverSettings(folder).compiler_args, ["-Wall", inc]);
  assert.ok(serverArguments(folder).includes(`--compiler_args=${JSON.stringify(["-Wall", inc])}`));

  settings["zfls.fortitude.enabled"] = true;
  settings["zfls.fortitude.args"] = ["--config-file", "${workspaceFolder}/fortitude.toml"];
  assert.deepEqual(serverSettings(folder).fortitude_args, ["--config-file", `${root}/fortitude.toml`]);

  settings["zfls.linter.fypp.enabled"] = true;
  settings["zfls.linter.fypp.definitions"] = { NAME: "a b" };
  assert.deepEqual(serverSettings(folder).compiler_fypp_args, ["-DNAME=a b"]);
});

test("fypp does not run in an untrusted workspace, even when the user's settings turn it on", () => {
  settings["zfls.linter.fypp.enabled"] = true;
  workspace.isTrusted = false;
  try {
    assert.equal(serverSettings(folder).compiler_fypp, null);
    assert.ok(!serverArguments(folder).some((a) => a.startsWith("--compiler_fypp")));
  } finally {
    workspace.isTrusted = true;
  }
  assert.notEqual(serverSettings(folder).compiler_fypp, null);
});

test("arguments without a space are one string on the command line", () => {
  settings["zfls.linter.extraArgs"] = ["-Wall", "-std=f2018"];
  assert.ok(serverArguments(folder).includes("--compiler_args=-Wall -std=f2018"));
  assert.equal(argOption("--codee_args", []), "--codee_args=");
  // a first argument zfls would take for a JSON list
  assert.equal(argOption("--codee_args", ["[x]"]), '--codee_args=["[x]"]');
});

test("empty and blank items of zfls.arguments are left out", () => {
  settings["zfls.arguments"] = ["", " ", "--nthreads=2"];
  const args = serverArguments(folder);
  assert.equal(args[args.length - 1], "--nthreads=2");
  assert.ok(!args.some((a) => a.trim() === ""));
});

test("files.associations reaches zfls on the command line and over LSP (#686)", () => {
  assert.deepEqual(serverSettings(folder).file_associations, {});
  assert.ok(!serverArguments(folder).includes("--file_associations"));
  settings["files.associations"] = { "*.fpp": "FortranFixedForm" };
  assert.deepEqual(serverSettings(folder).file_associations, { "*.fpp": "FortranFixedForm" });
  const args = serverArguments(folder);
  assert.equal(args[args.indexOf("--file_associations") + 1], '{"*.fpp":"FortranFixedForm"}');
});

test("a fractional lintOnTypeDelay is sent as whole milliseconds (#783)", () => {
  settings["zfls.linter.lintOnType"] = true;
  settings["zfls.linter.lintOnTypeDelay"] = 250.6;
  assert.equal(serverSettings(folder).compiler_change_delay, 251);
  const args = serverArguments(folder);
  assert.equal(args[args.indexOf("--compiler_change_delay") + 1], "251");
});

test("the settings are sent at start too, with incremental_sync (#782)", () => {
  settings["zfls.lowercaseHover"] = true;
  settings["zfls.incrementalSync"] = true;
  const start = startSettings(folder);
  assert.equal(start.lowercase_hover, true);
  assert.equal(start.incremental_sync, true);
  const restartOnly = { incremental_sync: undefined, debug_log: undefined };
  assert.deepEqual({ ...start, ...restartOnly }, { ...serverSettings(folder), ...restartOnly });
  assert.ok(!("incremental_sync" in serverSettings(folder)));
  assert.ok(!("config" in start));
});

test("settings that zfls.arguments sets are not sent (#782)", () => {
  settings["zfls.lowercaseHover"] = false;
  settings["zfls.arguments"] = ["--lowercase_hover", "-n2", "--max_line=100", "--incremental_sync"];
  for (const s of [serverSettings(folder), startSettings(folder)]) {
    assert.ok(!("lowercase_hover" in s));
    assert.ok(!("nthreads" in s));
    // a prefix: every setting it begins
    assert.ok(!("max_line_length" in s));
    assert.ok("max_comment_line_length" in s);
    assert.ok(!("incremental_sync" in s));
  }
  // a whole name is that one only
  settings["zfls.arguments"] = ["--codee"];
  assert.ok(!("codee" in serverSettings(folder)));
  assert.ok("codee_path" in serverSettings(folder));
});

test("blank zfls.arguments items do not restart the server on every change (#787)", () => {
  const e = { affectsConfiguration: (key: string) => key === "zfls.lowercaseHover" } as vscode.ConfigurationChangeEvent;
  settings["zfls.arguments"] = ["", "  "];
  assert.equal(restartsServer(e, undefined), false);
  settings["zfls.arguments"] = ["", "--nthreads=2"];
  assert.equal(restartsServer(e, undefined), true);
});

test("the debug log, cache, compile commands and C binding settings are options (#793)", () => {
  settings["zfls.debugLog"] = true;
  settings["zfls.disableIndexCache"] = true;
  settings["zfls.disableCompileCommands"] = true;
  settings["zfls.disableBindCSearch"] = true;
  settings["zfls.bindCClangd"] = "${workspaceFolder}/tools/clangd";
  const args = serverArguments(folder);
  for (const flag of ["--debug_log", "--disable_index_cache", "--disable_compile_commands", "--disable_bind_c_search"]) {
    assert.ok(args.includes(flag), flag);
  }
  assert.equal(args[args.indexOf("--bind_c_clangd") + 1], `${root}/tools/clangd`);
  const live = serverSettings(folder);
  assert.equal(live.disable_index_cache, true);
  assert.equal(live.bind_c_clangd, `${root}/tools/clangd`);
  // debug_log is read at start only
  assert.ok(!("debug_log" in live));
});
