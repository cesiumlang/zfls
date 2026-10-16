// Plain Node.js tests (no VS Code) of the external tool helpers:
// `npm run unit`.

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { expandVariables, findExecutable, runProcess } from "../../src/tools";

const ctx = {
  workspaceFolder: path.join("/ws", "proj"),
  workspaceFolders: { proj: path.join("/ws", "proj"), lib: path.join("/ws", "lib") },
  file: path.join("/ws", "proj", "src", "main.f90"),
  env: { FC_HOME: "/opt/fc", Path: "/bin" },
  home: "/home/me",
};

test("variables are expanded", () => {
  assert.equal(expandVariables("${workspaceFolder}/x", ctx), `${ctx.workspaceFolder}/x`);
  assert.equal(expandVariables("${workspaceFolder:lib}", ctx), ctx.workspaceFolders.lib);
  assert.equal(expandVariables("${workspaceFolderBasename}", ctx), "proj");
  assert.equal(expandVariables("${env:FC_HOME}/bin", ctx), "/opt/fc/bin");
  assert.equal(expandVariables("${env:UNSET_VARIABLE}", ctx), "");
  assert.equal(expandVariables("${userHome}", ctx), "/home/me");
  assert.equal(expandVariables("${fileBasenameNoExtension}${fileExtname}", ctx), "main.f90");
  assert.equal(expandVariables("${fileDirname}", ctx), path.join("/ws", "proj", "src"));
  assert.equal(expandVariables("-c${file}", ctx), `-c${ctx.file}`);
});

test("a leading ~ is the home directory", () => {
  assert.equal(expandVariables("~", ctx), "/home/me");
  assert.equal(expandVariables("~/bin/findent", ctx), path.join("/home/me", "bin/findent"));
  assert.equal(expandVariables("-i~", ctx), "-i~");
  assert.equal(expandVariables("~user", ctx), "~user");
});

test("unknown variables are kept", () => {
  assert.equal(expandVariables("${config:x} ${nope}", ctx), "${config:x} ${nope}");
  assert.equal(expandVariables("${file}", { ...ctx, file: undefined }), "${file}");
});

test("executables are found in a directory, by path, or on the PATH", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-unit-"));
  try {
    const name = process.platform === "win32" ? "fmt.exe" : "fmt";
    const exe = path.join(dir, name);
    fs.writeFileSync(exe, "");
    const env = { PATH: dir, PATHEXT: ".EXE" };
    assert.equal(findExecutable("fmt", dir, undefined, env), exe);
    assert.equal(findExecutable("fmt", exe, undefined, env), exe);
    assert.equal(findExecutable("fmt", name, dir, env), exe);
    assert.equal(findExecutable("fmt", "", undefined, env), exe);
    assert.equal(findExecutable("fmt", "", undefined, { PATH: os.tmpdir() }), undefined);
    assert.equal(findExecutable("fmt", path.join(dir, "missing"), undefined, env), undefined);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a process gets its input on stdin", async () => {
  const script = "process.stdin.pipe(process.stdout)";
  const result = await runProcess(process.execPath, ["-e", script], { input: "x = 1\n" });
  assert.equal(result.error, undefined);
  assert.equal(result.code, 0);
  assert.equal(result.stdout, "x = 1\n");
});

test("arguments reach the process as they are", async () => {
  const args = ["a b", '"q"', "$HOME", "%PATH%", ""];
  const result = await runProcess(process.execPath, [
    "-e",
    "process.stdout.write(JSON.stringify(process.argv.slice(1)))",
    ...args,
  ]);
  assert.deepEqual(JSON.parse(result.stdout), args);
});

test("a missing program, an exit code and a timeout are reported", async () => {
  const missing = await runProcess(path.join(os.tmpdir(), "no-such-program-zfls"), []);
  assert.ok(missing.error);
  const failed = await runProcess(process.execPath, ["-e", "process.stderr.write('bad'); process.exit(3)"]);
  assert.equal(failed.code, 3);
  assert.equal(failed.stderr, "bad");
  const slow = await runProcess(process.execPath, ["-e", "setTimeout(() => {}, 10000)"], { timeout: 200 });
  assert.match(String(slow.error), /timed out/);
});
