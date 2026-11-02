// zfls's debug adapter of the `fortran` debug type: between VS Code and
// gdb's own (`gdb -i=dap`: gdb 14 or later, built with Python). It passes
// the Debug Adapter Protocol through, and shows the program as Fortran:
// - array elements by their subscripts (`(2,-1)`), large arrays in
//   sections (`(1:100)`), and an expression for each variable (Add to
//   Watch, Copy as Expression, setting values);
// - previews of arrays and derived types (`[1.0, 2.0, …]`,
//   `point(x=9.0, y=-2.0, id=7)`), "not allocated" for unallocated arrays,
//   pointers as their targets;
// - a polymorphic object (CLASS) with the components of its dynamic type;
// - gfortran's hidden lengths of CHARACTER arguments left out;
// - the module variables that the frame's line sees
//   (`zfls/moduleVariables`), as a scope;
// - "Fortran runtime errors": stopping where the runtime reports an error
//   or ERROR STOP, an exception breakpoint filter;
// - the program in a terminal (`console`), for its input.
// No `vscode` import: VS Code runs it in the extension's process
// (DebugAdapterInlineImplementation), the tests in plain Node.js.

import { ChildProcess, execFile, spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  ArrayContext,
  Chunk,
  RUNTIME_ERROR_FUNCTIONS,
  addressOf,
  arrayPreview,
  arrayType,
  castCommand,
  chunkContext,
  chunkSection,
  chunks,
  derivedTypeName,
  dynamicType,
  element,
  extent,
  fortranNumber,
  fortranType,
  indexedDim,
  isClassWrapper,
  isErrorStop,
  isHiddenLength,
  isNullPointer,
  isUnallocated,
  pointerTarget,
  rankOf,
  shapePreview,
  structPreview,
} from "./fortranDebug";
import { ModuleVariable, byModule, expression } from "./moduleVariables";

/* eslint-disable @typescript-eslint/no-explicit-any */

interface Message {
  seq: number;
  type: string;
}

export interface Request extends Message {
  type: "request";
  command: string;
  arguments?: any;
}

export interface Response extends Message {
  type: "response";
  request_seq: number;
  command: string;
  success: boolean;
  message?: string;
  body?: any;
}

export interface Event extends Message {
  type: "event";
  event: string;
  body?: any;
}

export type ProtocolMessage = Request | Response | Event;

interface Variable {
  name: string;
  value: string;
  type?: string;
  variablesReference: number;
  evaluateName?: string;
  indexedVariables?: number;
  namedVariables?: number;
  presentationHint?: unknown;
  memoryReference?: string;
}

/** The words the adapter shows, translated by the extension */
export interface AdapterText {
  moduleVariables: string;
  notAllocated: string;
  notAssociated: string;
  notAvailable: string;
  runtimeErrors: string;
  runtimeErrorsDescription: string;
  runtimeError: string;
  errorStop: string;
  gdbExited: string;
}

export const ENGLISH: AdapterText = {
  moduleVariables: "Module variables",
  notAllocated: "not allocated",
  notAssociated: "not associated",
  notAvailable: "not available",
  runtimeErrors: "Fortran runtime errors",
  runtimeErrorsDescription: "Stop where the Fortran runtime reports an error (bounds checking, allocation, I/O) or ERROR STOP",
  runtimeError: "Fortran runtime error",
  errorStop: "ERROR STOP",
  gdbExited: "gdb exited",
};

export interface AdapterOptions {
  /** The gdb to run */
  gdb: string;
  /** The module variables a line of a file sees (`zfls/moduleVariables`),
   * none outside Fortran */
  moduleVariables?(file: string, line: number): Promise<ModuleVariable[]>;
  text?: Partial<AdapterText>;
  log?(line: string): void;
}

/** The exception breakpoint filter of the Fortran runtime's errors */
export const RUNTIME_ERRORS_FILTER = "fortranRuntimeErrors";

/** gdb's exception breakpoint filters of Ada, of no use to Fortran */
const ADA_FILTERS = ["assert", "exception"];

/** Requests that go on running the program: the variables of the last
 * stop are gone */
const RESUMING = ["continue", "next", "stepIn", "stepOut", "stepBack", "reverseContinue", "goto"];

/** What a variable reference of the adapter stands for */
type Node =
  | {
      kind: "gdb";
      /** gdb's reference */
      ref: number;
      frameId?: number;
      ctx: Context;
      /** The children's names as shown, to gdb's names and expressions */
      names?: Map<string, Named>;
    }
  | { kind: "section"; evaluateName: string; frameId?: number; ctx: Context; names?: Map<string, Named> }
  | { kind: "chunks"; frameId?: number; ctx: Context; count: number; ref?: number; names?: Map<string, Named> }
  | { kind: "modules"; frameId: number; vars: ModuleVariable[]; names?: Map<string, Named> }
  | { kind: "module"; frameId: number; vars: ModuleVariable[]; names?: Map<string, Named> };

interface Named {
  gdbName: string;
  evaluateName?: string;
}

/** What the adapter knows of a node's place, for its children */
interface Context {
  /** The node's expression: its components' are `expr%name` */
  evaluateName?: string;
  /** The node's place in an array, for an array or a column of one */
  array?: ArrayContext;
  /** Its elements, for an array */
  count?: number;
  /** The node is gdb's scope of registers: `$rax` */
  registers?: boolean;
  /** For a polymorphic object shown as its dynamic type: the components
   * of its declared type, which the object's expression names
   * (`t%_data%x`) while the others need gdb's pointer to it */
  declared?: { expr: string; names: Set<string> };
}

interface Frame {
  file?: string;
  line: number;
}

export class GdbAdapter {
  private readonly text: AdapterText;
  private readonly listeners: ((m: ProtocolMessage) => void)[] = [];
  private gdb?: ChildProcess;
  private buffer = Buffer.alloc(0);
  private gdbSeq = 1;
  private clientSeq = 1;
  /** gdb's answers awaited, by gdb's seq */
  private readonly pending = new Map<number, (r: Response) => void>();
  /** The client's answers awaited (runInTerminal), by our seq */
  private readonly clientPending = new Map<number, (r: Response) => void>();
  /** Requests are sent to gdb in the order they came */
  private order: Promise<void> = Promise.resolve();
  private readonly nodes = new Map<number, Node>();
  private nextRef = 1;
  private readonly frames = new Map<number, Frame>();
  private convenience = 0;
  private clientCaps: any = {};
  /** The function breakpoints of the client, and whether the runtime's
   * errors stop the program */
  private userFunctions: any[] = [];
  private runtimeErrors = false;
  /** gdb's ids of the breakpoints on the runtime's error functions */
  private readonly errorBreakpoints = new Map<number, string>();
  private functionsSynced: Promise<unknown> = Promise.resolve();
  private lastError?: string;
  private terminalPid?: number;
  private stderr = "";
  /** Why gdb is gone: its exit code and the end of what it wrote to stderr */
  private exitMessage?: string;
  private ended = false;
  private exited!: () => void;
  /** Resolved when gdb has exited, or did not start */
  readonly closed = new Promise<void>((resolve) => (this.exited = resolve));

  constructor(private readonly options: AdapterOptions) {
    this.text = { ...ENGLISH, ...options.text };
  }

  // The interface of vscode.DebugAdapter

  readonly onDidSendMessage = (
    listener: (m: ProtocolMessage) => unknown,
    thisArgs?: unknown,
    disposables?: { dispose(): unknown }[],
  ): { dispose(): void } => {
    const bound = (m: ProtocolMessage): void => void listener.call(thisArgs, m);
    this.listeners.push(bound);
    const d = {
      dispose: (): void => {
        const i = this.listeners.indexOf(bound);
        if (i >= 0) {
          this.listeners.splice(i, 1);
        }
      },
    };
    disposables?.push(d);
    return d;
  };

  handleMessage(message: ProtocolMessage): void {
    if (message.type === "response") {
      const done = this.clientPending.get(message.request_seq);
      this.clientPending.delete(message.request_seq);
      done?.(message);
      return;
    }
    if (message.type !== "request") {
      return;
    }
    this.order = this.order
      .then(() => this.dispatch(message))
      .catch((e: unknown) => {
        this.log(`[gdb adapter] ${message.command}: ${String(e)}`);
        this.respond(message, { success: false, message: String(e instanceof Error ? e.message : e) });
      });
  }

  dispose(): void {
    this.ended = true;
    if (this.gdb && this.gdb.exitCode === null && this.gdb.signalCode === null) {
      this.gdb.kill();
    } else {
      this.exited();
    }
    this.killTerminal();
  }

  // Messages

  private log(line: string): void {
    this.options.log?.(line);
  }

  private send(m: Omit<Response, "seq"> | Omit<Event, "seq"> | Omit<Request, "seq">): number {
    const seq = this.clientSeq++;
    const message = { ...m, seq } as ProtocolMessage;
    for (const l of [...this.listeners]) {
      l(message);
    }
    return seq;
  }

  private respond(req: Request, r: { success: boolean; message?: string; body?: any }): void {
    this.send({ type: "response", request_seq: req.seq, command: req.command, ...r });
  }

  private event(event: string, body?: any): void {
    this.send({ type: "event", event, body });
  }

  /** Sends a request to gdb: its answer */
  private request(command: string, args?: any): Promise<Response> {
    return new Promise((resolve) => {
      if (!this.gdb?.stdin?.writable || this.exitMessage) {
        resolve({ seq: 0, type: "response", request_seq: 0, command, success: false, message: this.exitMessage ?? this.text.gdbExited });
        return;
      }
      const seq = this.gdbSeq++;
      this.pending.set(seq, resolve);
      const json = JSON.stringify({ seq, type: "request", command, arguments: args });
      this.gdb.stdin.write(`Content-Length: ${Buffer.byteLength(json)}\r\n\r\n${json}`);
    });
  }

  /** Sends a request to the client (runInTerminal): its answer */
  private clientRequest(command: string, args: any): Promise<Response> {
    return new Promise((resolve) => {
      const seq = this.send({ type: "request", command, arguments: args });
      this.clientPending.set(seq, resolve);
    });
  }

  /** Passes a request to gdb and its answer back, through `transform` */
  private forward(req: Request, args = req.arguments, transform?: (r: Response) => Promise<Response> | Response): void {
    void this.request(req.command, args).then(async (r) => {
      try {
        r = transform && r.success ? await transform(r) : r;
      } catch (e) {
        this.log(`[gdb adapter] ${req.command}: ${String(e)}`);
      }
      this.respond(req, { success: r.success, message: r.message, body: r.body });
    });
  }

  // gdb

  private start(): string | undefined {
    try {
      this.gdb = spawn(this.options.gdb, ["-q", "-i=dap"], {
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
        env: gdbEnv(this.options.gdb, process.env),
      });
    } catch (e) {
      return String(e);
    }
    this.gdb.stdout!.on("data", (d: Buffer) => this.received(d));
    this.gdb.stderr!.on("data", (d: Buffer) => {
      this.stderr = (this.stderr + d.toString()).slice(-4000);
      this.log(`[gdb] ${d.toString().trimEnd()}`);
    });
    this.gdb.on("error", (e) => {
      this.log(`[gdb adapter] ${this.options.gdb}: ${e.message}`);
      this.stderr += e.message;
      this.exited();
    });
    // `close`: after its output is read, for what it said before it ended
    this.gdb.on("close", (code) => {
      this.exited();
      this.exitMessage = `${this.text.gdbExited} (${code ?? "?"})${this.stderr.trim() ? `: ${this.stderr.trim().slice(-1000)}` : ""}`;
      for (const [, done] of this.pending) {
        done({ seq: 0, type: "response", request_seq: 0, command: "", success: false, message: this.exitMessage });
      }
      this.pending.clear();
      if (!this.ended) {
        this.ended = true;
        if (code !== 0) {
          this.event("output", { category: "stderr", output: `${this.exitMessage}\n` });
        }
        this.event("terminated");
      }
    });
    return undefined;
  }

  private received(data: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, data]);
    for (;;) {
      const header = this.buffer.indexOf("\r\n\r\n");
      if (header < 0) {
        return;
      }
      const m = /Content-Length:\s*(\d+)/i.exec(this.buffer.subarray(0, header).toString());
      if (!m) {
        this.buffer = this.buffer.subarray(header + 4);
        continue;
      }
      const length = Number(m[1]);
      if (this.buffer.length < header + 4 + length) {
        return;
      }
      const body = this.buffer.subarray(header + 4, header + 4 + length).toString();
      this.buffer = this.buffer.subarray(header + 4 + length);
      let message: ProtocolMessage;
      try {
        message = JSON.parse(body);
      } catch {
        continue;
      }
      if (message.type === "response") {
        const done = this.pending.get(message.request_seq);
        this.pending.delete(message.request_seq);
        done?.(message);
      } else if (message.type === "event") {
        this.gdbEvent(message);
      }
    }
  }

  private gdbEvent(e: Event): void {
    switch (e.event) {
      case "stopped": {
        this.nodes.clear();
        this.frames.clear();
        const ids: number[] = e.body?.hitBreakpointIds ?? [];
        const fn = ids.map((id) => this.errorBreakpoints.get(id)).find((f) => f !== undefined);
        this.lastError = fn;
        if (fn) {
          const description = isErrorStop(fn) ? this.text.errorStop : this.text.runtimeError;
          e = { ...e, body: { ...e.body, reason: "exception", description, text: fn } };
        }
        break;
      }
      case "continued":
        this.nodes.clear();
        break;
      case "breakpoint":
        // those of the runtime's errors are the adapter's own
        if (this.errorBreakpoints.has(e.body?.breakpoint?.id)) {
          return;
        }
        break;
      case "terminated":
      case "exited":
        this.killTerminal();
        break;
    }
    this.event(e.event, e.body);
  }

  // Requests

  private async dispatch(req: Request): Promise<void> {
    const args = req.arguments ?? {};
    switch (req.command) {
      case "initialize": {
        this.clientCaps = args;
        const failed = this.start();
        if (failed) {
          this.respond(req, { success: false, message: failed });
          return;
        }
        this.forward(req, { ...args, supportsRunInTerminalRequest: false }, (r) => {
          const filters: any[] = (r.body?.exceptionBreakpointFilters ?? []).filter(
            (f: any) => !ADA_FILTERS.includes(f.filter),
          );
          return {
            ...r,
            body: {
              ...r.body,
              supportsExceptionInfoRequest: true,
              supportsSetVariable: true,
              exceptionBreakpointFilters: [
                {
                  filter: RUNTIME_ERRORS_FILTER,
                  label: this.text.runtimeErrors,
                  description: this.text.runtimeErrorsDescription,
                  default: true,
                },
                ...filters,
              ],
            },
          };
        });
        return;
      }
      case "launch":
      case "attach": {
        await this.prepare(args);
        const forGdb =
          req.command === "launch"
            ? {
                program: args.program,
                args: Array.isArray(args.args) ? args.args.map(String) : [],
                cwd: args.cwd,
                env: mergeEnv(process.env, args.env ?? {}),
                stopAtBeginningOfMainSubprogram: args.stopAtEntry === true,
              }
            : {
                ...(args.processId !== undefined && args.processId !== "" ? { pid: Number(args.processId) } : {}),
                ...(args.program ? { program: args.program } : {}),
                ...(args.target ? { target: String(args.target) } : {}),
              };
        this.forward(req, forGdb);
        return;
      }
      case "setFunctionBreakpoints": {
        this.userFunctions = args.breakpoints ?? [];
        const r = await this.syncFunctions();
        this.respond(req, {
          success: r.success,
          message: r.message,
          body: { breakpoints: (r.body?.breakpoints ?? []).slice(0, this.userFunctions.length) },
        });
        return;
      }
      case "setExceptionBreakpoints": {
        const filters: string[] = args.filters ?? [];
        const options: any[] = args.filterOptions ?? [];
        const wanted =
          filters.includes(RUNTIME_ERRORS_FILTER) || options.some((o) => o.filterId === RUNTIME_ERRORS_FILTER);
        const ours = { filters: filters.filter((f) => f !== RUNTIME_ERRORS_FILTER), filterOptions: options.filter((o) => o.filterId !== RUNTIME_ERRORS_FILTER) };
        const sent = this.request(req.command, ours);
        if (wanted !== this.runtimeErrors) {
          this.runtimeErrors = wanted;
          void this.syncFunctions();
        }
        const r = await sent;
        const theirs: any[] = r.body?.breakpoints ?? [];
        const all = [...filters, ...options.map((o) => o.filterId)];
        const breakpoints = all.map((f) => (f === RUNTIME_ERRORS_FILTER ? { verified: true } : (theirs.shift() ?? { verified: true })));
        this.respond(req, { success: r.success, message: r.message, body: r.success ? { breakpoints } : r.body });
        return;
      }
      case "exceptionInfo": {
        const fn = this.lastError;
        this.respond(req, {
          success: fn !== undefined,
          body: fn
            ? {
                exceptionId: fn,
                description: isErrorStop(fn) ? this.text.errorStop : this.text.runtimeError,
                breakMode: "always",
              }
            : undefined,
        });
        return;
      }
      case "stackTrace":
        this.forward(req, args, (r) => {
          for (const f of r.body?.stackFrames ?? []) {
            this.frames.set(f.id, { file: f.source?.path, line: f.line });
            // the runtime's frames: VS Code shows the first frame of the
            // program's sources
            if (!f.source?.path || !exists(f.source.path)) {
              f.presentationHint = "subtle";
              if (f.source) {
                f.source.presentationHint = "deemphasize";
              }
            }
          }
          return r;
        });
        return;
      case "scopes":
        this.forward(req, args, (r) => this.scopes(args.frameId, r));
        return;
      case "variables":
        void this.variables(req);
        return;
      case "evaluate": {
        if (args.context === "repl") {
          this.forward(req, args, (r) => {
            if (r.body?.variablesReference) {
              r.body.variablesReference = this.add({ kind: "gdb", ref: r.body.variablesReference, frameId: args.frameId, ctx: {} });
            }
            return r;
          });
          return;
        }
        const context = ["watch", "hover", "variables"].includes(args.context) ? args.context : "watch";
        this.forward(req, { ...args, context }, async (r) => {
          const v = await this.present(
            { name: args.expression, value: r.body.result, type: r.body.type, variablesReference: r.body.variablesReference ?? 0, memoryReference: r.body.memoryReference },
            args.expression,
            args.expression,
            args.frameId,
          );
          return { ...r, body: { ...r.body, result: v.value, type: v.type, variablesReference: v.variablesReference } };
        });
        return;
      }
      case "setVariable":
        void this.setVariable(req);
        return;
      case "disconnect":
      case "terminate":
        this.forward(req, args, (r) => {
          if (req.command === "disconnect") {
            this.ended = true;
            setTimeout(() => this.dispose(), 2000);
          }
          return r;
        });
        return;
      default:
        if (RESUMING.includes(req.command)) {
          this.nodes.clear();
        }
        this.forward(req, args);
    }
  }

  /** Before launch or attach: the program's terminal, and the
   * configuration's gdb commands */
  private async prepare(args: any): Promise<void> {
    const console = typeof args.console === "string" ? args.console : "internalConsole";
    if (console !== "internalConsole") {
      if (process.platform === "win32") {
        await this.request("evaluate", { expression: "set new-console on", context: "repl" });
      } else if (this.clientCaps.supportsRunInTerminalRequest) {
        const tty = await this.terminalTty(console === "externalTerminal" ? "external" : "integrated", args.cwd);
        if (tty) {
          await this.request("evaluate", { expression: `set inferior-tty ${tty}`, context: "repl" });
        }
      }
    }
    const commands: unknown[] = Array.isArray(args.setupCommands) ? args.setupCommands : [];
    for (const c of commands) {
      const text = typeof c === "string" ? c : (c as { text?: unknown })?.text;
      // cppdbg's are MI commands (`-enable-pretty-printing`)
      if (typeof text === "string" && text.trim() && !text.trim().startsWith("-")) {
        const r = await this.request("evaluate", { expression: text, context: "repl" });
        if (!r.success) {
          this.event("output", { category: "stderr", output: `${text}: ${r.message ?? ""}\n` });
        }
      }
    }
  }

  /** A terminal of the client for the program: its tty, which a shell in
   * it writes to a file and then waits */
  private async terminalTty(kind: "integrated" | "external", cwd: string | undefined): Promise<string | undefined> {
    const file = path.join(os.tmpdir(), `zfls-tty-${process.pid}-${Date.now()}`);
    const r = await this.clientRequest("runInTerminal", {
      kind,
      title: "Fortran",
      cwd: cwd ?? os.homedir(),
      args: ["/bin/sh", "-c", `tty > '${file}'; trap 'exit 0' HUP INT TERM; while :; do sleep 3600; done`],
    });
    if (!r.success) {
      return undefined;
    }
    this.terminalPid = r.body?.shellProcessId ?? r.body?.processId;
    for (let i = 0; i < 100; i++) {
      try {
        const tty = fs.readFileSync(file, "utf8").trim();
        if (tty.startsWith("/")) {
          fs.rmSync(file, { force: true });
          return tty;
        }
      } catch {
        // not yet written
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    return undefined;
  }

  private killTerminal(): void {
    if (this.terminalPid) {
      try {
        process.kill(this.terminalPid);
      } catch {
        // gone
      }
      this.terminalPid = undefined;
    }
  }

  /** gdb's function breakpoints: the client's, then the runtime's error
   * functions when that filter is on */
  private syncFunctions(): Promise<Response> {
    const run = async (): Promise<Response> => {
      const ours = this.runtimeErrors ? RUNTIME_ERROR_FUNCTIONS : [];
      const r = await this.request("setFunctionBreakpoints", {
        breakpoints: [...this.userFunctions, ...ours.map((name) => ({ name }))],
      });
      this.errorBreakpoints.clear();
      const bps: any[] = r.body?.breakpoints ?? [];
      ours.forEach((name, i) => {
        const id = bps[this.userFunctions.length + i]?.id;
        if (typeof id === "number") {
          this.errorBreakpoints.set(id, name);
        }
      });
      return r;
    };
    const next = this.functionsSynced.then(run, run);
    this.functionsSynced = next;
    return next;
  }

  // Variables

  private add(node: Node): number {
    const ref = this.nextRef++;
    this.nodes.set(ref, node);
    return ref;
  }

  private async scopes(frameId: number, r: Response): Promise<Response> {
    const scopes: any[] = r.body?.scopes ?? [];
    for (const s of scopes) {
      if (s.variablesReference) {
        const registers = s.presentationHint === "registers" || s.name === "Registers";
        s.variablesReference = this.add({ kind: "gdb", ref: s.variablesReference, frameId, ctx: { registers } });
      }
      delete s.namedVariables;
      delete s.indexedVariables;
    }
    const frame = this.frames.get(frameId);
    let vars: ModuleVariable[] = [];
    if (frame?.file && this.options.moduleVariables) {
      try {
        vars = await this.options.moduleVariables(frame.file, frame.line);
      } catch (e) {
        this.log(`[gdb adapter] module variables: ${String(e)}`);
      }
    }
    if (vars.length) {
      const locals = scopes.findIndex((s) => s.presentationHint === "locals" || s.name === "Locals");
      const at = locals >= 0 ? locals + 1 : Math.min(scopes.length, 2);
      scopes.splice(at, 0, {
        name: this.text.moduleVariables,
        variablesReference: this.add({ kind: "modules", frameId, vars }),
        expensive: false,
      });
      // gdb's globals are those of the frame's file, the module variables among them
      for (const s of scopes) {
        if (s.name === "Globals") {
          s.expensive = true;
        }
      }
    }
    return r;
  }

  private async variables(req: Request): Promise<void> {
    const ref: number = req.arguments?.variablesReference;
    const node = this.nodes.get(ref);
    if (!node) {
      this.respond(req, { success: true, body: { variables: [] } });
      return;
    }
    try {
      const variables = await this.children(node);
      this.respond(req, { success: true, body: { variables } });
    } catch (e) {
      this.respond(req, { success: false, message: String(e instanceof Error ? e.message : e) });
    }
  }

  /** The children of a node, as shown */
  private async children(node: Node): Promise<Variable[]> {
    const names = new Map<string, Named>();
    node.names = names;
    const record = (vs: Variable[], gdbNames: string[]): Variable[] => {
      vs.forEach((v, i) => names.set(v.name, { gdbName: gdbNames[i], evaluateName: v.evaluateName }));
      return vs;
    };
    switch (node.kind) {
      case "modules":
        return byModule(node.vars).map((g) => ({
          name: g.module,
          value: "",
          variablesReference: this.add({ kind: "module", frameId: node.frameId, vars: g.vars }),
          presentationHint: { kind: "class" },
        }));
      case "module": {
        const vs = await Promise.all(node.vars.map((v) => this.moduleVariable(v, node.frameId)));
        return record(vs, vs.map((v) => v.name));
      }
      case "chunks": {
        const array = node.ctx.array!;
        return chunks(node.count).map((c) => this.chunk(array, c, node));
      }
      case "section": {
        const r = await this.request("evaluate", { expression: node.evaluateName, frameId: node.frameId, context: "watch" });
        if (!r.success || !r.body?.variablesReference) {
          return [];
        }
        const kids = await this.gdbChildren(r.body.variablesReference);
        return record(await this.convert(kids, node.ctx, node.frameId), kids.map((k) => k.name));
      }
      case "gdb": {
        const array = node.ctx.array;
        // a large array in sections, when it has an expression
        if (array?.expr !== undefined && (node.ctx.count ?? 0) > CHUNK) {
          return chunks(node.ctx.count!).map((c) => this.chunk(array, c, node));
        }
        const kids = await this.gdbChildren(node.ref);
        return record(await this.convert(kids, node.ctx, node.frameId), kids.map((k) => k.name));
      }
    }
  }

  /** A section of an array, shown as a node of its elements */
  private chunk(array: ArrayContext, c: Chunk, parent: Node): Variable {
    const section = chunkSection(array, c);
    const ctx: Context = { evaluateName: section.evaluateName, array: chunkContext(array, c), count: c.count };
    const frameId = parent.frameId;
    const ref =
      c.count > CHUNK
        ? this.add({ kind: "chunks", frameId, ctx, count: c.count })
        : this.add({ kind: "section", evaluateName: section.evaluateName!, frameId, ctx });
    return { name: section.name, value: "", variablesReference: ref, evaluateName: section.evaluateName };
  }

  private async moduleVariable(v: ModuleVariable, frameId: number): Promise<Variable> {
    const label = v.local.toLowerCase() === v.name.toLowerCase() ? v.local : `${v.local} => ${v.name}`;
    const expr = expression("gdb", v.module, v.name);
    const r = await this.request("evaluate", { expression: expr, frameId, context: "watch" });
    if (!r.success || typeof r.body?.result !== "string") {
      return { name: label, value: this.text.notAvailable, type: v.type, variablesReference: 0 };
    }
    return this.present(
      { name: label, value: r.body.result, type: r.body.type, variablesReference: r.body.variablesReference ?? 0 },
      label,
      expr,
      frameId,
    );
  }

  private async gdbChildren(ref: number): Promise<Variable[]> {
    const r = await this.request("variables", { variablesReference: ref });
    if (!r.success) {
      throw new Error(r.message ?? "variables");
    }
    return r.body?.variables ?? [];
  }

  /** gdb's children of a node as shown: Fortran names and expressions */
  private convert(kids: Variable[], parent: Context, frameId: number | undefined): Promise<Variable[]> {
    const shown = kids.filter((k) => !isHiddenLength(k.name, kids));
    return Promise.all(
      shown.map((k) => {
        if (parent.array) {
          const e = element(parent.array, k.name);
          return this.present(k, e.name, e.evaluateName, frameId, e.sub);
        }
        let evaluateName: string | undefined;
        if (parent.registers) {
          evaluateName = `$${k.name}`;
        } else if (parent.declared?.names.has(k.name.toLowerCase())) {
          evaluateName = `${parent.declared.expr}%${k.name}`;
        } else if (parent.evaluateName !== undefined) {
          evaluateName = `${parent.evaluateName}%${k.name}`;
        } else {
          evaluateName = k.name;
        }
        return this.present(k, k.name, evaluateName, frameId);
      }),
    );
  }

  /** A variable of gdb as shown: its value, and a node for its children */
  private async present(
    v: Variable,
    name: string,
    evaluateName: string | undefined,
    frameId: number | undefined,
    sub?: ArrayContext,
    extra?: Partial<Context>,
  ): Promise<Variable> {
    v = { ...v, type: fortranType(v.type) };
    const out: Variable = {
      name,
      value: v.value,
      type: v.type,
      variablesReference: 0,
      evaluateName,
      ...(v.presentationHint ? { presentationHint: v.presentationHint } : {}),
      ...(v.memoryReference ? { memoryReference: v.memoryReference } : {}),
    };
    const node = (ctx: Context): number =>
      v.variablesReference ? this.add({ kind: "gdb", ref: v.variablesReference, frameId, ctx: { ...ctx, ...extra } }) : 0;

    if (isClassWrapper(v.type) && v.variablesReference) {
      return this.presentClass(v, out, frameId);
    }
    // a pointer, as its target
    if (pointerTarget(v.type) !== undefined) {
      if (isNullPointer(v.value)) {
        return { ...out, value: this.text.notAssociated };
      }
      if (v.variablesReference) {
        const kids = await this.gdbChildren(v.variablesReference);
        if (kids.length === 1 && kids[0].name === "value") {
          return this.present(kids[0], name, evaluateName, frameId, sub, extra);
        }
      }
      return { ...out, variablesReference: node({ evaluateName }) };
    }
    const a = arrayType(v.type);
    if (a || sub) {
      if (a && !sub && isUnallocated(a)) {
        return { ...out, value: a.allocatable ? this.text.notAllocated : this.text.notAssociated };
      }
      const ctx: ArrayContext = sub ?? { expr: evaluateName, dims: a!.dims, fixed: [] };
      const count = v.indexedVariables ?? extent(indexedDim(ctx)) ?? 0;
      out.value = await this.arrayValue(v, ctx, count, frameId);
      out.variablesReference = node({ evaluateName, array: ctx, count });
      return out;
    }
    const typeName = derivedTypeName(v.type);
    if (typeName && v.variablesReference) {
      const kids = await this.gdbChildren(v.variablesReference);
      const shown = kids.filter((k) => !isHiddenLength(k.name, kids));
      out.value = structPreview(typeName, shown.map((k) => ({ name: k.name, value: short(k) })));
      out.variablesReference = node({ evaluateName });
      return out;
    }
    out.value = fortranNumber(v.value, v.type);
    out.variablesReference = node({ evaluateName });
    return out;
  }

  /** The preview of an array: its first elements, or its shape */
  private async arrayValue(v: Variable, ctx: ArrayContext, count: number, frameId: number | undefined): Promise<string> {
    const rank = rankOf(ctx);
    if (rank > 1) {
      return shapePreview(ctx.dims.slice(0, rank));
    }
    if (count === 0) {
      return "[]";
    }
    let kids: Variable[] = [];
    if (count <= CHUNK && v.variablesReference) {
      kids = await this.gdbChildren(v.variablesReference);
    } else if (ctx.expr !== undefined) {
      const first = chunkSection(ctx, { start: 0, count: Math.min(count, 6) });
      const r = await this.request("evaluate", { expression: first.evaluateName, frameId, context: "watch" });
      if (r.success && r.body?.variablesReference) {
        kids = await this.gdbChildren(r.body.variablesReference);
      }
    }
    return kids.length ? arrayPreview(kids.map(short), count) : `[${count}]`;
  }

  /** A polymorphic object: its dynamic type's components, through a
   * pointer of gdb's to it, as gdb shows only the declared type's */
  private async presentClass(v: Variable, out: Variable, frameId: number | undefined): Promise<Variable> {
    const kids = await this.gdbChildren(v.variablesReference);
    const data = kids.find((k) => k.name === "_data");
    const vptr = kids.find((k) => k.name === "_vptr");
    if (!data) {
      return { ...out, variablesReference: this.add({ kind: "gdb", ref: v.variablesReference, frameId, ctx: { evaluateName: out.evaluateName } }) };
    }
    const declaredName = derivedTypeName(pointerTarget(data.type));
    const type = declaredName ? `class(${declaredName})` : out.type;
    if (isNullPointer(data.value)) {
      return { ...out, type, value: this.text.notAllocated };
    }
    const dataExpr = out.evaluateName !== undefined ? `${out.evaluateName}%_data` : undefined;
    const dynamic = vptr ? dynamicType(vptr.value) : undefined;
    const address = addressOf(data.value);
    if (dynamic && address && dynamic.name !== declaredName?.toLowerCase()) {
      const variable = `zfls_${++this.convenience}`;
      const set = await this.request("evaluate", { expression: castCommand(variable, address, dynamic), frameId, context: "repl" });
      if (set.success) {
        const r = await this.request("evaluate", { expression: `$${variable}`, frameId, context: "watch" });
        if (r.success && r.body?.variablesReference) {
          const declared = dataExpr !== undefined ? { expr: dataExpr, names: await this.componentNames(data) } : undefined;
          const shown = await this.present(
            { name: out.name, value: r.body.result, type: r.body.type, variablesReference: r.body.variablesReference },
            out.name,
            `$${variable}`,
            frameId,
            undefined,
            declared ? { declared } : undefined,
          );
          return { ...shown, type, evaluateName: out.evaluateName };
        }
      }
    }
    const shown = await this.present(data, out.name, dataExpr, frameId);
    return { ...shown, type, evaluateName: out.evaluateName };
  }

  /** The components of the declared type of a polymorphic object's `_data` */
  private async componentNames(data: Variable): Promise<Set<string>> {
    if (!data.variablesReference) {
      return new Set();
    }
    const [value] = await this.gdbChildren(data.variablesReference);
    if (!value?.variablesReference) {
      return new Set();
    }
    return new Set((await this.gdbChildren(value.variablesReference)).map((k) => k.name.toLowerCase()));
  }

  private async setVariable(req: Request): Promise<void> {
    const args = req.arguments ?? {};
    const node = this.nodes.get(args.variablesReference);
    const named = node?.names?.get(args.name);
    const frameId = node?.frameId;
    if (named?.evaluateName !== undefined && !named.evaluateName.startsWith("$zfls_")) {
      const r = await this.request("setExpression", { expression: named.evaluateName, value: args.value, frameId });
      if (!r.success) {
        this.respond(req, { success: false, message: r.message });
        return;
      }
      const v = await this.present(
        { name: args.name, value: r.body?.value ?? "", type: r.body?.type, variablesReference: r.body?.variablesReference ?? 0 },
        args.name,
        named.evaluateName,
        frameId,
      );
      this.respond(req, { success: true, body: { value: v.value, type: v.type, variablesReference: v.variablesReference } });
      return;
    }
    if (node?.kind === "gdb") {
      const r = await this.request("setVariable", { ...args, variablesReference: node.ref, name: named?.gdbName ?? args.name });
      this.respond(req, { success: r.success, message: r.message, body: r.body });
      return;
    }
    this.respond(req, { success: false, message: this.text.notAvailable });
  }
}

/** Arrays of more elements are shown in sections */
const CHUNK = 100;

/** A value in a preview: a number as Fortran writes it, `[…]` for an
 * array, `point(…)` for a derived type */
function short(v: Variable): string {
  if (v.value) {
    return fortranNumber(v.value, v.type);
  }
  if (arrayType(v.type)) {
    return "[…]";
  }
  const t = derivedTypeName(v.type);
  return t ? `${t}(…)` : "…";
}

function exists(file: string): boolean {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

/** gdb's version of `gdb --version`, the end of its first line:
 * `GNU gdb (GDB) 17.2` -> [17, 2] */
export function gdbVersion(text: string): [number, number] | undefined {
  const m = /^GNU gdb\b.*\s(\d+)\.(\d+)\S*\s*$/m.exec(text.split(/\r?\n/)[0] ?? "");
  return m ? [Number(m[1]), Number(m[2])] : undefined;
}

const dapSupport = new Map<string, Promise<boolean>>();

/** Whether a gdb has the Debug Adapter Protocol: gdb 14 or later, built
 * with Python (asked once per gdb) */
export function gdbHasDap(gdb: string): Promise<boolean> {
  let known = dapSupport.get(gdb);
  if (!known) {
    known = (async () => {
      const version = gdbVersion(await output(gdb, ["--version"]));
      if (!version || version[0] < 14) {
        return false;
      }
      // the modules its DAP needs, which another Python's library lacks
      const check = "python import json, struct, threading; print(6*7)";
      return (await output(gdb, ["-nx", "-q", "-batch", "-ex", check])).trim() === "42";
    })();
    dapSupport.set(gdb, known);
  }
  return known;
}

function output(exe: string, args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile(exe, args, { timeout: 10000, windowsHide: true, env: gdbEnv(exe, process.env) }, (error, stdout) =>
      resolve(error ? "" : stdout),
    );
  });
}

/** gdb's environment: its own directory first on the PATH. gdb's Python
 * finds its library by the `python3` on the PATH, and another one there
 * first (a virtual environment, conda, pyenv, CI's) breaks it ("No module
 * named '_struct'"); next to gdb is the one it was built with. */
export function gdbEnv(gdb: string, base: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const dir = path.isAbsolute(gdb) ? path.dirname(gdb) : undefined;
  if (!dir) {
    return base;
  }
  const key = Object.keys(base).find((k) => k.toUpperCase() === "PATH") ?? "PATH";
  const current = base[key] ?? "";
  return { ...base, [key]: current ? `${dir}${path.delimiter}${current}` : dir };
}

/** The program's environment: this process's with `extra` over it (gdb
 * gives the program exactly the environment it is given); on Windows the
 * names are case-insensitive */
export function mergeEnv(base: NodeJS.ProcessEnv, extra: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(base)) {
    if (v !== undefined) {
      out[k] = v;
    }
  }
  for (const [k, v] of Object.entries(extra)) {
    if (process.platform === "win32") {
      for (const existing of Object.keys(out)) {
        if (existing.toUpperCase() === k.toUpperCase()) {
          delete out[existing];
        }
      }
    }
    out[k] = String(v);
  }
  return out;
}
