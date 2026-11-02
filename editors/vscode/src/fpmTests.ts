// The test explorer for fpm projects: a test item per test target of each
// project, and below it, for test-drive, its suites and tests, as zfls
// finds them (`zfls/fpmTests`). Running a target runs `fpm test NAME` (with
// the suite and test when one is picked and the program takes them) and
// reads test-drive's results from its output; debugging it runs the program
// under the debugger.

import * as path from "node:path";
import * as vscode from "vscode";
import type { LanguageClient } from "vscode-languageclient/node";
import { FpmTestProject, FpmTestTarget, Located, Target, parseTestDrive, passed, runArgs } from "./fpm";
import { FpmProject, buildOptions, debugTarget, fpmExecutable, projectAt } from "./fpmCommands";
import { FORTRAN_FILES } from "./linter";
import { runProcess } from "./tools";

/** The servers of the workspace folders, started if need be */
export type Servers = () => Promise<LanguageClient[]>;

/** What a test item stands for */
interface ItemData {
  project: FpmProject;
  target: Target;
  /** The program takes a suite and a test on its command line */
  selectsTests?: boolean;
  suite?: string;
  test?: string;
}

export function registerFpmTests(context: vscode.ExtensionContext, log: vscode.LogOutputChannel, servers: Servers): void {
  let tests: FpmTests | undefined;
  const update = (): void => {
    const enabled = vscode.workspace.getConfiguration("zfls.fpm").get<boolean>("testExplorer", true);
    if (enabled && !tests) {
      tests = new FpmTests(log, servers);
    } else if (!enabled && tests) {
      tests.dispose();
      tests = undefined;
    }
  };
  update();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("zfls.fpm.testExplorer")) {
        update();
      }
    }),
    { dispose: () => tests?.dispose() },
  );
}

class FpmTests implements vscode.Disposable {
  private readonly controller = vscode.tests.createTestController("zfls.fpm", "fpm");
  private readonly data = new WeakMap<vscode.TestItem, ItemData>();
  private readonly disposables: vscode.Disposable[] = [];
  private timer: NodeJS.Timeout | undefined;

  constructor(
    private readonly log: vscode.LogOutputChannel,
    private readonly servers: Servers,
  ) {
    this.controller.resolveHandler = async (item) => {
      if (!item) {
        await this.discover();
      }
    };
    this.controller.refreshHandler = () => this.discover();
    this.controller.createRunProfile(
      "Run",
      vscode.TestRunProfileKind.Run,
      (request, token) => this.run(request, token),
      true,
    );
    this.controller.createRunProfile(
      "Debug",
      vscode.TestRunProfileKind.Debug,
      (request, token) => this.debug(request, token),
      true,
    );
    const manifests = vscode.workspace.createFileSystemWatcher("**/fpm.toml");
    const sources = vscode.workspace.createFileSystemWatcher(`**/${FORTRAN_FILES}`);
    const later = (): void => this.later();
    this.disposables.push(
      this.controller,
      manifests,
      sources,
      manifests.onDidChange(later),
      manifests.onDidCreate(later),
      manifests.onDidDelete(later),
      sources.onDidCreate(later),
      sources.onDidDelete(later),
      vscode.workspace.onDidSaveTextDocument((d) => {
        if (this.inTests(d.uri)) {
          later();
        }
      }),
    );
  }

  dispose(): void {
    clearTimeout(this.timer);
    for (const d of this.disposables) {
      d.dispose();
    }
  }

  /** Whether a file is (near) one of the tests found, so that saving it may
   * change them */
  private inTests(uri: vscode.Uri): boolean {
    let found = false;
    this.controller.items.forEach((item) => {
      const d = this.data.get(item);
      if (d && !path.relative(d.project.root, uri.fsPath).startsWith("..")) {
        found = true;
      }
      item.children.forEach((child) => {
        const c = this.data.get(child);
        if (c && !path.relative(c.project.root, uri.fsPath).startsWith("..")) {
          found = true;
        }
      });
    });
    return found;
  }

  private later(): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.discover(), 1000);
  }

  /** The test targets of every project, as the items at the top (a project
   * each, when there are several) */
  async discover(): Promise<void> {
    const projects: { project: FpmProject; found: FpmTestProject }[] = [];
    for (const server of await this.servers()) {
      let found: FpmTestProject[] | null;
      try {
        found = await server.sendRequest<FpmTestProject[] | null>("zfls/fpmTests", {});
      } catch (err) {
        this.log.error(`[fpm] finding the tests: ${String(err)}`);
        continue;
      }
      for (const p of found ?? []) {
        const project = projectAt(vscode.Uri.parse(p.uri).fsPath);
        if (project) {
          projects.push({ project, found: p });
        }
      }
    }
    const top: vscode.TestItem[] = [];
    for (const { project, found } of projects) {
      const targets = found.targets.map((t) => this.targetItem(project, t));
      if (projects.length > 1) {
        const item = this.controller.createTestItem(project.root, found.name, vscode.Uri.file(project.root));
        item.children.replace(targets);
        this.data.set(item, { project, target: { kind: "test", name: "" } });
        top.push(item);
      } else {
        top.push(...targets);
      }
    }
    this.controller.items.replace(top);
  }

  /** A target's item, with test-drive's suites and tests below it */
  private targetItem(project: FpmProject, found: FpmTestTarget): vscode.TestItem {
    const target: Target = { kind: "test", name: found.name };
    const { selectsTests } = found;
    const item = this.controller.createTestItem(
      `${project.root}::${target.name}`,
      target.name,
      found.uri ? vscode.Uri.parse(found.uri) : undefined,
    );
    this.data.set(item, { project, target, selectsTests });
    if (found.range) {
      item.range = asRange(found.range);
    }
    for (const s of found.suites) {
      const suite = this.locatedItem(`${item.id}::${s.name}`, s);
      this.data.set(suite, { project, target, selectsTests, suite: s.name });
      for (const t of s.tests) {
        const test = this.locatedItem(`${suite.id}::${t.name}`, t);
        this.data.set(test, { project, target, selectsTests, suite: s.name, test: t.name });
        suite.children.add(test);
      }
      item.children.add(suite);
    }
    return item;
  }

  private locatedItem(id: string, found: Located): vscode.TestItem {
    const item = this.controller.createTestItem(id, found.name, vscode.Uri.parse(found.uri));
    item.range = asRange(found.range);
    return item;
  }

  /** The requested items, by target */
  private byTarget(request: vscode.TestRunRequest): Map<string, { target: vscode.TestItem; picked: vscode.TestItem[] }> {
    const groups = new Map<string, { target: vscode.TestItem; picked: vscode.TestItem[] }>();
    const excluded = new Set(request.exclude ?? []);
    const add = (item: vscode.TestItem): void => {
      if (excluded.has(item)) {
        return;
      }
      const d = this.data.get(item);
      if (!d) {
        return;
      }
      if (!d.target.name) {
        item.children.forEach(add);
        return;
      }
      const targetItem = this.targetItemOf(item);
      const key = targetItem.id;
      const group = groups.get(key) ?? { target: targetItem, picked: [] };
      group.picked.push(item);
      groups.set(key, group);
    };
    if (request.include) {
      request.include.forEach(add);
    } else {
      this.controller.items.forEach(add);
    }
    return groups;
  }

  private targetItemOf(item: vscode.TestItem): vscode.TestItem {
    let t = item;
    while (t.parent && this.data.get(t.parent)?.target.name) {
      t = t.parent;
    }
    return t;
  }

  private async run(request: vscode.TestRunRequest, token: vscode.CancellationToken): Promise<void> {
    const run = this.controller.createTestRun(request);
    const abort = new AbortController();
    const cancelled = token.onCancellationRequested(() => abort.abort());
    try {
      for (const { target, picked } of this.byTarget(request).values()) {
        if (token.isCancellationRequested) {
          break;
        }
        await this.runTarget(run, target, picked, abort.signal);
      }
    } finally {
      cancelled.dispose();
      run.end();
    }
  }

  /** The suite and test to pass to the program, when one suite (or one
   * test) is picked and the program takes them */
  private selection(target: vscode.TestItem, picked: vscode.TestItem[]): string[] {
    const d = this.data.get(target)!;
    if (picked.includes(target) || !d.selectsTests) {
      return [];
    }
    const suites = new Set(picked.map((p) => this.data.get(p)?.suite));
    if (suites.size !== 1) {
      return [];
    }
    const [suite] = suites;
    const single = picked.length === 1 ? this.data.get(picked[0])?.test : undefined;
    return suite ? (single ? [suite, single] : [suite]) : [];
  }

  private async runTarget(
    run: vscode.TestRun,
    target: vscode.TestItem,
    picked: vscode.TestItem[],
    signal: AbortSignal,
  ): Promise<void> {
    const d = this.data.get(target)!;
    const fpm = fpmExecutable(d.project);
    if (!fpm) {
      run.errored(target, new vscode.TestMessage(vscode.l10n.t("fpm was not found: set zfls.fpm.path.")));
      return;
    }
    // the items whose results this run gives
    const items = new Set<vscode.TestItem>();
    const addAll = (i: vscode.TestItem): void => {
      items.add(i);
      i.children.forEach(addAll);
    };
    picked.forEach(addAll);
    items.add(target);
    for (const i of items) {
      run.started(i);
    }
    const args = runArgs(d.target, buildOptions(d.project), this.selection(target, picked));
    run.appendOutput(`> fpm ${args.join(" ")}\r\n`);
    this.log.info(`[fpm] ${fpm} ${args.join(" ")} (in ${d.project.root})`);
    const start = Date.now();
    const result = await runProcess(fpm, args, { cwd: d.project.root, signal });
    const duration = Date.now() - start;
    const output = result.stdout + (result.stderr ? `\n${result.stderr}` : "");
    run.appendOutput(output.replace(/\r?\n/g, "\r\n") + "\r\n", undefined, target);
    if (result.error && signal.aborted) {
      for (const i of items) {
        run.skipped(i);
      }
      return;
    }
    if (result.error) {
      run.errored(target, new vscode.TestMessage(vscode.l10n.t("fpm did not run: {0}", result.error.message)));
      return;
    }
    const results = parseTestDrive(output);
    const suiteFailed = new Set<string>();
    for (const r of results) {
      const item = this.testItem(target, r.suite, r.name);
      if (!item) {
        continue;
      }
      items.delete(item);
      if (passed(r.status)) {
        if (r.status === "skipped") {
          run.skipped(item);
        } else {
          run.passed(item);
        }
      } else {
        suiteFailed.add(r.suite ?? "");
        const message = r.status === "unexpected-pass"
            ? vscode.l10n.t("passed, but was expected to fail")
            : (r.message ?? vscode.l10n.t("failed"));
        run.failed(item, this.messageAt(item, message));
      }
    }
    // the suites, from their tests
    for (const i of [...items]) {
      const id = this.data.get(i);
      if (i !== target && id?.suite && !id.test && results.some((r) => r.suite === id.suite)) {
        if (suiteFailed.has(id.suite)) {
          run.failed(i, new vscode.TestMessage(vscode.l10n.t("some of its tests failed")));
        } else {
          run.passed(i);
        }
        items.delete(i);
      }
    }
    items.delete(target);
    if (result.code === 0) {
      run.passed(target, duration);
    } else if (!results.length) {
      // no results: the build failed, or the program is not a test-drive one
      run.failed(target, new vscode.TestMessage(lastLines(output, 30)), duration);
    } else {
      run.failed(target, new vscode.TestMessage(vscode.l10n.t("exit code {0}", String(result.code))), duration);
    }
    // what the output gave no result for
    for (const i of items) {
      if (result.code === 0) {
        run.skipped(i);
      } else {
        run.errored(i, new vscode.TestMessage(vscode.l10n.t("no result: see the output")));
      }
    }
  }

  /** The item of a test of the target, added when it was not found in the
   * sources */
  private testItem(target: vscode.TestItem, suite: string | undefined, name: string): vscode.TestItem | undefined {
    const d = this.data.get(target)!;
    let parent = target;
    if (suite) {
      let s = target.children.get(`${target.id}::${suite}`);
      if (!s) {
        s = this.controller.createTestItem(`${target.id}::${suite}`, suite);
        this.data.set(s, { ...d, suite });
        target.children.add(s);
      }
      parent = s;
    }
    let item = parent.children.get(`${parent.id}::${name}`);
    if (!item) {
      item = this.controller.createTestItem(`${parent.id}::${name}`, name);
      this.data.set(item, { ...d, suite, test: name });
      parent.children.add(item);
    }
    return item;
  }

  private messageAt(item: vscode.TestItem, text: string): vscode.TestMessage {
    const message = new vscode.TestMessage(text);
    if (item.uri && item.range) {
      message.location = new vscode.Location(item.uri, item.range);
    }
    return message;
  }

  /** Debugs each requested target's program, one after the other */
  private async debug(request: vscode.TestRunRequest, token: vscode.CancellationToken): Promise<void> {
    const run = this.controller.createTestRun(request);
    try {
      for (const { target, picked } of this.byTarget(request).values()) {
        if (token.isCancellationRequested) {
          break;
        }
        const d = this.data.get(target)!;
        run.started(target);
        const ended = sessionEnd();
        const started = await debugTarget(d.project, d.target, this.log, this.selection(target, picked));
        if (started) {
          await ended.promise;
        } else {
          ended.dispose();
          run.errored(target, new vscode.TestMessage(vscode.l10n.t("the debugger did not start")));
        }
      }
    } finally {
      run.end();
    }
  }
}

/** The end of the next debug session to start */
export function sessionEnd(): { promise: Promise<void>; dispose: () => void } {
  let session: vscode.DebugSession | undefined;
  let resolve!: () => void;
  const promise = new Promise<void>((r) => (resolve = r));
  const started = vscode.debug.onDidStartDebugSession((s) => {
    session ??= s;
    started.dispose();
  });
  const ended = vscode.debug.onDidTerminateDebugSession((s) => {
    if (s === session) {
      ended.dispose();
      resolve();
    }
  });
  return {
    promise,
    dispose: () => {
      started.dispose();
      ended.dispose();
    },
  };
}

/** A range of the server's answers */
export function asRange(range: Located["range"]): vscode.Range {
  return new vscode.Range(range.start.line, range.start.character, range.end.line, range.end.character);
}

function lastLines(text: string, n: number): string {
  return text.trimEnd().split(/\r?\n/).slice(-n).join("\n");
}
