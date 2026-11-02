// zfls's debug adapter with a real gdb and gfortran (`npm run unit`): a
// program built with gfortran, debugged through the adapter as VS Code
// would, its variables as Fortran. Skipped without gfortran or a gdb of
// the Debug Adapter Protocol (gdb 14 or later, with Python).

import * as assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { after, before, test } from "node:test";
import { GdbAdapter, ProtocolMessage, RUNTIME_ERRORS_FILTER, Response, gdbHasDap } from "../../src/gdbAdapter";
import { ModuleVariable } from "../../src/moduleVariables";

const SOURCE = `module grid
  implicit none
  type :: point
    real :: x = 1.5, y = -2.0
    integer :: id = 7
  end type
  type, extends(point) :: tagged
    character(len=8) :: tag = 'hello'
    real, allocatable :: w(:)
  end type
  integer :: ncells = 42
  integer, private :: secret = 99
  type(point) :: origin
contains
  subroutine work(a, b, s, p, t)
    real, intent(inout) :: a(:)
    integer, intent(in) :: b(:,:)
    character(len=*), intent(in) :: s
    type(point), intent(in) :: p
    class(point), intent(in) :: t
    a(1) = a(1) + 5
    print *, a, b(2,1), s, p%x, t%id, secret
  end subroutine
end module

program main
  use grid
  implicit none
  real :: v(3) = [1., 2., 3.]
  real, allocatable :: big(:), none(:)
  integer :: m(2:3, -1:1)
  type(tagged) :: tg
  integer :: k
  do k = -1, 1
    m(:, k) = [10*k, 20*k]
  end do
  allocate(big(1000)); big = [(real(k), k=1,1000)]
  allocate(tg%w(2)); tg%w = 0.25
  origin%x = 9.0
  call work(v, m, 'abcdef', origin, tg)
  print *, allocated(none), big(1)
  k = 1001
  big(k) = 1.0
end program
`;
const WORK_LINE = 22;
const MAIN_LINE = 42;

let dir = "";
let program = "";
let source = "";
let gdb = "";

function which(exe: string): string | undefined {
  try {
    const out = execFileSync(process.platform === "win32" ? "where" : "which", [exe], { encoding: "utf8" });
    return out.split(/\r?\n/)[0].trim() || undefined;
  } catch {
    return undefined;
  }
}

// CI names them where other toolchains are on the PATH too
const gfortran = process.env.GFORTRAN || which("gfortran");
const gdbPath = process.env.GDB || which("gdb");
let usable = false;

before(async () => {
  if (!gfortran || !gdbPath || !(await gdbHasDap(gdbPath))) {
    return;
  }
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "zfls-dap-"));
  source = path.join(dir, "prog.f90");
  program = path.join(dir, process.platform === "win32" ? "prog.exe" : "prog");
  fs.writeFileSync(source, SOURCE);
  execFileSync(gfortran, ["-g", "-O0", "-fcheck=bounds", "-o", program, source], { cwd: dir });
  gdb = gdbPath;
  usable = true;
});

after(() => {
  if (dir) {
    // gdb and the program may take a moment to end
    fs.rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 250 });
  }
});

/** VS Code's side of the protocol, for a test */
class Client {
  private seq = 1;
  private readonly waiting = new Map<number, (r: Response) => void>();
  private readonly events: ProtocolMessage[] = [];
  private readonly eventWaiters: { event: string; resolve: (e: ProtocolMessage) => void }[] = [];
  output = "";

  constructor(readonly adapter: GdbAdapter) {
    adapter.onDidSendMessage((m) => {
      if (m.type === "response") {
        this.waiting.get(m.request_seq)?.(m);
        this.waiting.delete(m.request_seq);
      } else if (m.type === "event") {
        if (m.event === "output") {
          this.output += m.body?.output ?? "";
        }
        const w = this.eventWaiters.findIndex((x) => x.event === m.event);
        if (w >= 0) {
          this.eventWaiters.splice(w, 1)[0].resolve(m);
        } else {
          this.events.push(m);
        }
      }
    });
  }

  request(command: string, args?: unknown): Promise<Response> {
    const seq = this.seq++;
    return new Promise((resolve) => {
      this.waiting.set(seq, resolve);
      this.adapter.handleMessage({ seq, type: "request", command, arguments: args });
    });
  }

  async body(command: string, args?: unknown): Promise<any> {
    const r = await this.request(command, args);
    assert.ok(r.success, `${command}: ${r.message}`);
    return r.body;
  }

  event(event: string, timeout = 30000): Promise<any> {
    const i = this.events.findIndex((e) => e.type === "event" && e.event === event);
    if (i >= 0) {
      return Promise.resolve(this.events.splice(i, 1)[0]);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no ${event} event; output: ${this.output}`)), timeout);
      this.eventWaiters.push({
        event,
        resolve: (e) => {
          clearTimeout(timer);
          resolve(e);
        },
      });
    });
  }

  async variables(ref: number): Promise<any[]> {
    return (await this.body("variables", { variablesReference: ref })).variables;
  }
}

function named(vars: any[], name: string): any {
  const v = vars.find((x) => x.name === name);
  assert.ok(v, `no ${name} in ${vars.map((x) => x.name).join(", ")}`);
  return v;
}

test("a gfortran program through zfls's debug adapter", { timeout: 120000 }, async (t) => {
  if (!usable) {
    t.skip("needs gfortran and gdb 14 or later with Python");
    return;
  }
  const modules: ModuleVariable[] = [
    { module: "grid", name: "ncells", local: "ncells", type: "INTEGER" },
    { module: "grid", name: "secret", local: "hidden", type: "INTEGER" },
  ];
  const asked: [string, number][] = [];
  const adapter = new GdbAdapter({
    gdb,
    moduleVariables: async (file, line) => {
      asked.push([file, line]);
      return path.basename(file) === "prog.f90" ? modules : [];
    },
  });
  const client = new Client(adapter);
  try {
    const caps = await client.body("initialize", {
      adapterID: "fortran",
      clientID: "test",
      linesStartAt1: true,
      columnsStartAt1: true,
      pathFormat: "path",
      supportsVariableType: true,
    });
    const filters = caps.exceptionBreakpointFilters.map((f: any) => f.filter);
    assert.equal(filters[0], RUNTIME_ERRORS_FILTER);
    assert.ok(!filters.includes("assert"), "no Ada filters");
    assert.ok(caps.supportsExceptionInfoRequest);

    const launched = client.request("launch", { program, args: [], cwd: dir, env: { ZFLS_TEST: "1" } });
    const bps = await client.body("setBreakpoints", {
      source: { path: source },
      breakpoints: [{ line: WORK_LINE }, { line: MAIN_LINE }],
    });
    assert.equal(bps.breakpoints.length, 2);
    const exc = await client.body("setExceptionBreakpoints", { filters: [RUNTIME_ERRORS_FILTER] });
    assert.equal(exc.breakpoints.length, 1);
    await client.body("setFunctionBreakpoints", { breakpoints: [] });
    await client.body("configurationDone");
    assert.ok((await launched).success, "launch");

    // in work: its arguments
    let stopped = await client.event("stopped");
    let stack = (await client.body("stackTrace", { threadId: stopped.body.threadId })).stackFrames;
    assert.equal(stack[0].line, WORK_LINE);
    let scopes = (await client.body("scopes", { frameId: stack[0].id })).scopes;
    const names = scopes.map((s: any) => s.name);
    assert.ok(names.includes("Module variables"), names.join(", "));
    assert.ok(asked.some(([f, l]) => path.basename(f) === "prog.f90" && l === WORK_LINE));

    const args = await client.variables(named(scopes, "Arguments").variablesReference);
    assert.ok(!args.some((v) => v.name === "_s"), "the hidden length of s");
    const a = named(args, "a");
    assert.equal(a.value, "[6.0, 2.0, 3.0]");
    assert.equal(a.evaluateName, "a");
    const elements = await client.variables(a.variablesReference);
    assert.deepEqual(
      elements.map((e) => [e.name, e.value, e.evaluateName]),
      [
        ["(1)", "6.0", "a(1)"],
        ["(2)", "2.0", "a(2)"],
        ["(3)", "3.0", "a(3)"],
      ],
    );
    // b: m(2:3,-1:1), assumed shape: from 1
    const b = named(args, "b");
    assert.equal(b.value, "[2×3]");
    const columns = await client.variables(b.variablesReference);
    assert.deepEqual(columns.map((c) => c.name), ["(:,1)", "(:,2)", "(:,3)"]);
    const first = await client.variables(columns[0].variablesReference);
    assert.deepEqual(first.map((e) => [e.name, e.value, e.evaluateName]), [
      ["(1,1)", "-10", "b(1,1)"],
      ["(2,1)", "-20", "b(2,1)"],
    ]);
    assert.equal(named(args, "s").value, "'abcdef'");
    assert.equal(named(args, "p").value, "point(x=9.0, y=-2.0, id=7)");
    const p = await client.variables(named(args, "p").variablesReference);
    assert.equal(named(p, "x").evaluateName, "p%x");
    // t: class(point), a tagged
    const tv = named(args, "t");
    assert.equal(tv.type, "class(point)");
    assert.ok(tv.value.startsWith("tagged("), tv.value);
    const tc = await client.variables(tv.variablesReference);
    assert.equal(named(tc, "tag").value, "'hello   '");
    assert.equal(named(tc, "w").value, "[0.25, 0.25]");
    const parent = await client.variables(named(tc, "point").variablesReference);
    assert.equal(named(parent, "id").value, "7");

    // the module variables of the line
    const mv = await client.variables(named(scopes, "Module variables").variablesReference);
    assert.deepEqual(mv.map((m) => m.name), ["grid"]);
    const grid = await client.variables(mv[0].variablesReference);
    assert.deepEqual(grid.map((g) => [g.name, g.value, g.evaluateName]), [
      ["ncells", "42", "grid::ncells"],
      ["hidden => secret", "99", "grid::secret"],
    ]);

    // setting a value, then an expression
    const set = await client.body("setVariable", { variablesReference: a.variablesReference, name: "(2)", value: "100" });
    assert.equal(set.value, "100.0");
    const hover = await client.body("evaluate", { expression: "a", frameId: stack[0].id, context: "hover" });
    assert.equal(hover.result, "[6.0, 100.0, 3.0]");
    const sum = await client.body("evaluate", { expression: "a(2) + 1", frameId: stack[0].id, context: "watch" });
    assert.equal(sum.result, "101.0");
    assert.equal(sum.type, "real(kind=8)");

    // in the main program: lower bounds, a large array, not allocated
    await client.body("continue", { threadId: stopped.body.threadId });
    stopped = await client.event("stopped");
    stack = (await client.body("stackTrace", { threadId: stopped.body.threadId })).stackFrames;
    assert.equal(stack[0].line, MAIN_LINE);
    scopes = (await client.body("scopes", { frameId: stack[0].id })).scopes;
    const locals = await client.variables(named(scopes, "Locals").variablesReference);
    assert.equal(named(locals, "none").value, "not allocated");
    assert.equal(named(locals, "none").variablesReference, 0);
    const m = named(locals, "m");
    const mc = await client.variables(m.variablesReference);
    assert.deepEqual(mc.map((c) => c.name), ["(:,-1)", "(:,0)", "(:,1)"]);
    const m1 = await client.variables(mc[0].variablesReference);
    assert.deepEqual(m1.map((e) => [e.name, e.value, e.evaluateName]), [
      ["(2,-1)", "-10", "m(2,-1)"],
      ["(3,-1)", "-20", "m(3,-1)"],
    ]);
    const big = named(locals, "big");
    assert.equal(big.value, "[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, …]");
    const sections = await client.variables(big.variablesReference);
    assert.equal(sections.length, 10);
    assert.deepEqual([sections[5].name, sections[5].evaluateName], ["(501:600)", "big(501:600)"]);
    const s5 = await client.variables(sections[5].variablesReference);
    assert.equal(s5.length, 100);
    assert.deepEqual([s5[0].name, s5[0].value, s5[0].evaluateName], ["(501)", "501.0", "big(501)"]);

    // an array bound exceeded: a Fortran runtime error
    await client.body("continue", { threadId: stopped.body.threadId });
    stopped = await client.event("stopped");
    assert.equal(stopped.body.reason, "exception", JSON.stringify(stopped.body));
    const info = await client.body("exceptionInfo", { threadId: stopped.body.threadId });
    assert.equal(info.description, "Fortran runtime error");
    stack = (await client.body("stackTrace", { threadId: stopped.body.threadId })).stackFrames;
    const ours = stack.find((f: any) => f.presentationHint !== "subtle");
    assert.ok(ours && path.basename(ours.source.path) === "prog.f90", JSON.stringify(stack.slice(0, 4)));

    await client.body("disconnect", { terminateDebuggee: true });
  } finally {
    adapter.dispose();
    await adapter.closed;
  }
});

test("the program's input and output in a terminal (Linux)", { timeout: 60000 }, async (t) => {
  if (!usable || process.platform !== "linux" || !which("script")) {
    t.skip("needs gfortran, gdb 14 or later with Python, and script(1), on Linux");
    return;
  }
  const reader = path.join(dir, "reader.f90");
  const readerExe = path.join(dir, "reader");
  fs.writeFileSync(reader, "program reader\n  integer :: n\n  read(*, *) n\n  print '(a,i0)', 'read ', n\nend program\n");
  execFileSync(gfortran!, ["-g", "-o", readerExe, reader], { cwd: dir });
  const adapter = new GdbAdapter({ gdb });
  const client = new Client(adapter);
  // VS Code's terminal: script(1) gives the command a terminal, whose
  // input and output are the test's
  let terminal: ReturnType<typeof spawn> | undefined;
  let screen = "";
  adapter.onDidSendMessage((m) => {
    if (m.type === "request" && m.command === "runInTerminal") {
      const command = (m.arguments.args as string[]).map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ");
      terminal = spawn("script", ["-qfec", command, "/dev/null"], { cwd: m.arguments.cwd, stdio: ["pipe", "pipe", "inherit"] });
      terminal.stdout!.on("data", (d: Buffer) => (screen += d.toString()));
      adapter.handleMessage({ seq: 1000, type: "response", request_seq: m.seq, command: "runInTerminal", success: true, body: { shellProcessId: terminal.pid } });
    }
  });
  try {
    await client.body("initialize", { adapterID: "fortran", pathFormat: "path", supportsRunInTerminalRequest: true });
    const launched = client.request("launch", { program: readerExe, cwd: dir, console: "integratedTerminal" });
    await client.body("configurationDone");
    assert.ok((await launched).success, "launch");
    assert.ok(terminal, "a terminal was asked for");
    terminal!.stdin!.write("42\n");
    const exited = await client.event("exited");
    assert.equal(exited.body.exitCode, 0);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.match(screen, /read 42/);
    await client.request("disconnect", { terminateDebuggee: true });
  } finally {
    adapter.dispose();
    await adapter.closed;
    terminal?.kill();
  }
});

test("stopping at the start, gdb commands first", { timeout: 60000 }, async (t) => {
  if (!usable) {
    t.skip("needs gfortran and gdb 14 or later with Python");
    return;
  }
  const adapter = new GdbAdapter({ gdb });
  const client = new Client(adapter);
  try {
    await client.body("initialize", { adapterID: "fortran", linesStartAt1: true, columnsStartAt1: true, pathFormat: "path" });
    const launched = client.request("launch", {
      program,
      cwd: dir,
      stopAtEntry: true,
      // a cppdbg configuration's MI command is left out
      setupCommands: [{ text: "-enable-pretty-printing" }, "set print elements 2"],
    });
    await client.body("setExceptionBreakpoints", { filters: [] });
    await client.body("configurationDone");
    assert.ok((await launched).success, "launch");
    const stopped = await client.event("stopped");
    const stack = (await client.body("stackTrace", { threadId: stopped.body.threadId })).stackFrames;
    assert.equal(path.basename(stack[0].source.path), "prog.f90");
    assert.ok(stack[0].line < MAIN_LINE, `line ${stack[0].line}`);
    const shown = await client.body("evaluate", { expression: "show print elements", context: "repl", frameId: stack[0].id });
    assert.match(shown.result, /\b2\b/);
    await client.body("disconnect", { terminateDebuggee: true });
  } finally {
    adapter.dispose();
    await adapter.closed;
  }
});
