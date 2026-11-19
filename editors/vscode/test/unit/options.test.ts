// Tests of the zfls command line and the settings sent over LSP that the
// zfls.* settings become (src/options.ts), with plain Node.js and a
// stand-in for VS Code's settings (test/unit/vscode.ts):
//   npm run unit

import * as assert from "node:assert/strict";
import * as path from "node:path";
import { afterEach, test } from "node:test";
import type * as vscode from "vscode";
import { argOption, serverArguments, serverSettings } from "../../src/options";
import { settings } from "./vscode";

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
