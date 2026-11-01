// The test explorer for fpm projects: a test item per test target of each
// project (`fpm test --list`), and below it, for test-drive, its suites and
// tests, found in the sources. Running a target runs `fpm test NAME` (with
// the suite and test when one is picked and the program takes them) and
// reads test-drive's results from its output; debugging it runs the program
// under the debugger.

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  Target,
  TestDef,
  isProgram,
  parseTestDrive,
  passed,
  runArgs,
  selectsTests,
  sourcesOfTarget,
  testDriveDefs,
} from "./fpm";
import { FpmProject, buildOptions, debugTarget, findProjects, fpmExecutable, listTargets } from "./fpmCommands";
import { FORTRAN_FILES } from "./linter";
import { runProcess } from "./tools";

/** What a test item stands for */
interface ItemData {
  project: FpmProject;
  target: Target;
  /** The program's source, when found */
  program?: string;
  suite?: string;
  test?: string;
}

export function registerFpmTests(context: vscode.ExtensionContext, log: vscode.LogOutputChannel): void {
  let tests: FpmTests | undefined;
  const update = (): void => {
    const enabled = vscode.workspace.getConfiguration("zfls.fpm").get<boolean>("testExplorer", true);
    if (enabled && !tests) {
      tests = new FpmTests(log);
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

  constructor(private readonly log: vscode.LogOutputChannel) {
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
    const projects = await findProjects();
    const top: vscode.TestItem[] = [];
    for (const project of projects) {
      const fpm = fpmExecutable(project, true);
      if (!fpm) {
        this.log.info(`[fpm] fpm not found: no tests of ${project.root}`);
        continue;
      }
      let names: string[];
      try {
        names = await listTargets(project, "test", fpm);
      } catch (err) {
        this.log.error(`[fpm] listing the tests of ${project.root}: ${String(err)}`);
        continue;
      }
      const targets = await Promise.all(names.map((name) => this.targetItem(project, { kind: "test", name })));
      if (projects.length > 1) {
        const label = project.manifest.name ?? path.basename(project.root);
        const item = this.controller.createTestItem(project.root, label, vscode.Uri.file(project.root));
        item.children.replace(targets);
        this.data.set(item, { project, target: { kind: "test", name: "" } });
        top.push(item);
      } else {
        top.push(...targets);
      }
    }
    this.controller.items.replace(top);
  }

  private async targetItem(project: FpmProject, target: Target): Promise<vscode.TestItem> {
    const program = await this.programOf(project, target);
    const item = this.controller.createTestItem(
      `${project.root}::${target.name}`,
      target.name,
      program ? vscode.Uri.file(program) : undefined,
    );
    this.data.set(item, { project, target, program });
    if (program) {
      item.range = new vscode.Range(0, 0, 0, 0);
      this.addTestDrive(item, project, target, program);
    }
    return item;
  }

  /** The main program of a target: its `main`, or the program named after
   * it in its directory */
  private async programOf(project: FpmProject, target: Target): Promise<string | undefined> {
    const where = sourcesOfTarget(project.manifest, target);
    if (where.file) {
      const file = path.resolve(project.root, where.file);
      return fs.existsSync(file) ? file : undefined;
    }
    const files = await vscode.workspace.findFiles(
      new vscode.RelativePattern(path.join(project.root, where.dir), `**/${where.stem}.*`),
    );
    for (const f of files) {
      if (/\.(f90|f95|f03|f08|f18|fpp|f|for|f77)$/i.test(f.fsPath) && isProgram(readText(f.fsPath))) {
        return f.fsPath;
      }
    }
    return undefined;
  }

  /** The suites and tests of test-drive that the target's program runs:
   * the suites it makes, and the tests their collect procedures return, in
   * the sources next to it */
  private addTestDrive(item: vscode.TestItem, project: FpmProject, target: Target, program: string): void {
    const { suites } = testDriveDefs(readText(program));
    if (!suites.length) {
      return;
    }
    const tests = new Map<string, (TestDef & { file: string })[]>();
    for (const file of fortranFiles(path.dirname(program))) {
      for (const t of testDriveDefs(readText(file)).tests) {
        if (t.collect) {
          const list = tests.get(t.collect) ?? [];
          list.push({ ...t, file });
          tests.set(t.collect, list);
        }
      }
    }
    for (const s of suites) {
      const suite = this.controller.createTestItem(`${item.id}::${s.name}`, s.name, vscode.Uri.file(program));
      suite.range = new vscode.Range(s.line, 0, s.line, 0);
      this.data.set(suite, { project, target, program, suite: s.name });
      for (const t of tests.get(s.collect) ?? []) {
        const test = this.controller.createTestItem(`${suite.id}::${t.name}`, t.name, vscode.Uri.file(t.file));
        test.range = new vscode.Range(t.line, 0, t.line, 0);
        this.data.set(test, { project, target, program, suite: s.name, test: t.name });
        suite.children.add(test);
      }
      item.children.add(suite);
    }
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
    if (picked.includes(target) || !d.program || !selectsTests(readText(d.program))) {
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
function sessionEnd(): { promise: Promise<void>; dispose: () => void } {
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

function readText(file: string): string {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

/** The Fortran files in `dir` and below */
function fortranFiles(dir: string): string[] {
  const out: string[] = [];
  const walk = (d: string, depth: number): void => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && depth < 8 && e.name !== "build") {
        walk(p, depth + 1);
      } else if (e.isFile() && /\.(f90|f95|f03|f08|f18|fpp|f|for|f77)$/i.test(e.name)) {
        out.push(p);
      }
    }
  };
  walk(dir, 0);
  return out;
}

function lastLines(text: string, n: number): string {
  return text.trimEnd().split(/\r?\n/).slice(-n).join("\n");
}
