// Plain Node.js tests (no VS Code) of the external tool helpers:
// `npm run unit`.

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { FORTRAN_FILES, expandVariables, findExecutable, programPath, runProcess, serverExecutable } from "../../src/tools";

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
    // a bare name that is not in baseDir: on the PATH
    assert.equal(findExecutable("other", "fmt", os.tmpdir(), env), exe);
    assert.equal(findExecutable("other", "missing", os.tmpdir(), env), undefined);
    assert.equal(findExecutable("zfls-no-such-program-xyz"), undefined);
    assert.ok(findExecutable(process.execPath));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("zfls.path: variables, a relative path, a directory, and the path tried", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-unit-"));
  try {
    const ws = path.join(dir, "my ws");
    const home = path.join(dir, "home");
    const name = process.platform === "win32" ? "zfls.exe" : "zfls";
    const exe = path.join(ws, "tools", name);
    const homeExe = path.join(home, "bin", name);
    fs.mkdirSync(path.dirname(exe), { recursive: true });
    fs.mkdirSync(path.dirname(homeExe), { recursive: true });
    fs.writeFileSync(exe, "");
    fs.writeFileSync(homeExe, "");
    const ctx = { workspaceFolder: ws, home };
    const env = { PATH: "", PATHEXT: ".EXE" };
    assert.deepEqual(serverExecutable(`\${workspaceFolder}/tools/${name}`, ctx, env), { command: path.join(ws, "tools", name) });
    assert.deepEqual(serverExecutable(`~/bin/${name}`, ctx, env), { command: path.join(home, "bin", name) });
    assert.deepEqual(serverExecutable(`tools/${name}`, ctx, env), { command: exe });
    // a directory: the zfls in it
    assert.deepEqual(serverExecutable("${workspaceFolder}/tools", ctx, env), { command: exe });
    assert.deepEqual(serverExecutable(" tools ", ctx, env), { command: exe });
    // none there: the path looked for
    assert.deepEqual(serverExecutable("${workspaceFolder}/bin/zfls", ctx, env), { tried: path.join(ws, "bin", "zfls") });
    assert.deepEqual(serverExecutable("bin/zfls", ctx, env), { tried: path.join(ws, "bin", "zfls") });
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

test("FORTRAN_FILES has the extensions of the Fortran languages of package.json", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  const exts = pkg.contributes.languages
    .filter((l: { id: string }) => l.id === "FortranFreeForm" || l.id === "FortranFixedForm")
    .flatMap((l: { extensions: string[] }) => l.extensions.map((e) => e.slice(1)));
  assert.deepEqual(FORTRAN_FILES, `*.{${exts.join(",")}}`);
});

test("a bare program name is looked up on the PATH, not in the working directory", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-unit-"));
  try {
    const name = process.platform === "win32" ? "prog.exe" : "prog";
    const bin = path.join(dir, "bin");
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, name), "");
    fs.writeFileSync(path.join(dir, name), "");
    const sep = path.delimiter;
    const env = { PATH: `.${sep}bin${sep}${bin}`, PATHEXT: ".EXE" };
    const saved = process.cwd();
    process.chdir(dir);
    try {
      assert.equal(programPath("prog", env), path.join(bin, name));
      assert.equal(programPath("prog", { PATH: `.${sep}bin`, PATHEXT: ".EXE" }), undefined);
    } finally {
      process.chdir(saved);
    }
    // a path is left alone
    assert.equal(programPath(path.join(dir, name), env), path.join(dir, name));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
