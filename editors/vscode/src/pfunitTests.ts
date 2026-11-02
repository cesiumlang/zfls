// The test explorer for pFUnit: a test item per test program that CMake's
// `add_pfunit_ctest` makes, with the suite of each of its `.pf` files and
// their `@test` procedures below. Running builds the program with CMake,
// runs it with its results in an XML file (one test with `-f` when one is
// picked), and reports each test, with the place of a failed assertion;
// debugging runs the program under the `fortran` debug type. `.pf` files no
// `add_pfunit_ctest` names are listed too, to say so when run.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import { sessionEnd } from "./fpmTests";
import {
  CtestCommand,
  PfResult,
  PfSuite,
  PfTest,
  parseAddPfunitCtest,
  parseCtestJson,
  parsePf,
  parsePfunitXml,
  pfunitArgs,
  resultOf,
} from "./pfunit";
import { runTask } from "./runFile";
import { expandVariables, findExecutable, runProcess } from "./tools";
import { folderVariables } from "./variables";

const PROBLEM_MATCHERS = ["$zfls-gfortran", "$zfls-intel"];
const EXCLUDE = "**/{build,_deps,node_modules,.git}/**";

interface Program {
  folder: vscode.WorkspaceFolder;
  /** the CMakeLists.txt that makes it; none for `.pf` files of no program */
  cmakeLists?: string;
  name: string;
}

/** What a test item stands for */
interface ItemData {
  program: Program;
  file?: string;
  suite?: PfSuite;
  test?: PfTest;
}

export function registerPfunitTests(context: vscode.ExtensionContext, log: vscode.LogOutputChannel): void {
  let tests: PfunitTests | undefined;
  const update = (): void => {
    const enabled = vscode.workspace.getConfiguration("zfls.pfunit").get<boolean>("testExplorer", true);
    if (enabled && !tests) {
      tests = new PfunitTests(log);
    } else if (!enabled && tests) {
      tests.dispose();
      tests = undefined;
    }
  };
  update();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("zfls.pfunit.testExplorer")) {
        update();
      } else if (e.affectsConfiguration("zfls.pfunit")) {
        void tests?.discover();
      }
    }),
    { dispose: () => tests?.dispose() },
  );
}

class PfunitTests implements vscode.Disposable {
  private readonly controller = vscode.tests.createTestController("zfls.pfunit", "pFUnit");
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
      vscode.l10n.t("Run"),
      vscode.TestRunProfileKind.Run,
      (request, token) => this.run(request, token),
      true,
    );
    this.controller.createRunProfile(
      vscode.l10n.t("Debug"),
      vscode.TestRunProfileKind.Debug,
      (request, token) => this.debug(request, token),
      true,
    );
    const pf = vscode.workspace.createFileSystemWatcher("**/*.pf");
    const cmake = vscode.workspace.createFileSystemWatcher("**/CMakeLists.txt");
    const later = (): void => this.later();
    this.disposables.push(
      this.controller,
      pf,
      cmake,
      pf.onDidCreate(later),
      pf.onDidChange(later),
      pf.onDidDelete(later),
      cmake.onDidCreate(later),
      cmake.onDidChange(later),
      cmake.onDidDelete(later),
    );
  }

  dispose(): void {
    clearTimeout(this.timer);
    for (const d of this.disposables) {
      d.dispose();
    }
  }

  private later(): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.discover(), 1000);
  }

  /** The test programs of `add_pfunit_ctest`, and the `.pf` files of none */
  async discover(): Promise<void> {
    const pfFiles = (await vscode.workspace.findFiles("**/*.pf", EXCLUDE)).map((u) => u.fsPath);
    if (!pfFiles.length) {
      this.controller.items.replace([]);
      return;
    }
    const top: vscode.TestItem[] = [];
    const used = new Set<string>();
    for (const cm of await vscode.workspace.findFiles("**/CMakeLists.txt", EXCLUDE)) {
      const folder = vscode.workspace.getWorkspaceFolder(cm);
      const text = readText(cm.fsPath);
      if (!folder || !/add_pfunit_ctest/i.test(text)) {
        continue;
      }
      for (const t of parseAddPfunitCtest(text)) {
        const program: Program = { folder, cmakeLists: cm.fsPath, name: t.name };
        const item = this.controller.createTestItem(`${cm.fsPath}::${t.name}`, t.name, cm);
        this.data.set(item, { program });
        for (const src of t.sources) {
          const file = path.resolve(path.dirname(cm.fsPath), src);
          if (fs.existsSync(file)) {
            used.add(path.normalize(file).toLowerCase());
            item.children.add(this.suiteItem(item.id, program, file));
          }
        }
        top.push(item);
      }
    }
    for (const file of pfFiles) {
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
      if (folder && !used.has(path.normalize(file).toLowerCase())) {
        top.push(this.suiteItem("pf", { folder, name: "" }, file));
      }
    }
    this.controller.items.replace(top);
  }

  private suiteItem(parent: string, program: Program, file: string): vscode.TestItem {
    const suite = parsePf(readText(file), path.basename(file, path.extname(file)));
    const uri = vscode.Uri.file(file);
    const item = this.controller.createTestItem(`${parent}::${file}`, suite.name, uri);
    item.range = new vscode.Range(suite.line, 0, suite.line, 0);
    this.data.set(item, { program, file, suite });
    for (const t of suite.tests) {
      const test = this.controller.createTestItem(`${item.id}::${t.name}`, t.name, uri);
      test.range = new vscode.Range(t.line, 0, t.line, 0);
      this.data.set(test, { program, file, suite, test: t });
      item.children.add(test);
    }
    return item;
  }

  /** The requested items, by program */
  private byProgram(request: vscode.TestRunRequest): Map<vscode.TestItem, vscode.TestItem[]> {
    const groups = new Map<vscode.TestItem, vscode.TestItem[]>();
    const excluded = new Set(request.exclude ?? []);
    const add = (item: vscode.TestItem): void => {
      if (excluded.has(item) || !this.data.has(item)) {
        return;
      }
      let top = item;
      while (top.parent) {
        top = top.parent;
      }
      groups.set(top, [...(groups.get(top) ?? []), item]);
    };
    if (request.include) {
      request.include.forEach(add);
    } else {
      this.controller.items.forEach(add);
    }
    return groups;
  }

  private async run(request: vscode.TestRunRequest, token: vscode.CancellationToken): Promise<void> {
    const run = this.controller.createTestRun(request);
    const abort = new AbortController();
    const cancelled = token.onCancellationRequested(() => abort.abort());
    try {
      const excluded = new Set(request.exclude ?? []);
      for (const [top, picked] of this.byProgram(request)) {
        if (token.isCancellationRequested) {
          break;
        }
        await this.runProgram(run, top, picked, excluded, abort.signal);
      }
    } finally {
      cancelled.dispose();
      run.end();
    }
  }

  /** The test items below `item`, and it, that report results */
  private tests(item: vscode.TestItem, excluded: ReadonlySet<vscode.TestItem>): vscode.TestItem[] {
    const out: vscode.TestItem[] = [];
    const walk = (i: vscode.TestItem): void => {
      if (excluded.has(i)) {
        return;
      }
      if (this.data.get(i)?.test) {
        out.push(i);
      }
      i.children.forEach(walk);
    };
    walk(item);
    return out;
  }

  private async runProgram(
    run: vscode.TestRun,
    top: vscode.TestItem,
    picked: vscode.TestItem[],
    excluded: ReadonlySet<vscode.TestItem>,
    signal: AbortSignal,
  ): Promise<void> {
    const tests = [...new Set(picked.flatMap((p) => this.tests(p, excluded)))];
    const suites = new Set(tests.map((t) => t.parent!).filter((s) => s));
    const all = [...tests, ...suites, ...(this.data.get(top)?.file ? [] : [top])];
    for (const i of all) {
      run.started(i);
    }
    const fail = (message: string): void => {
      for (const i of all) {
        run.errored(i, new vscode.TestMessage(message));
      }
    };
    const { program } = this.data.get(top)!;
    if (!program.cmakeLists) {
      fail(
        vscode.l10n.t(
          "No add_pfunit_ctest of a CMakeLists.txt names this file: zfls runs the pFUnit test programs that CMake builds.",
        ),
      );
      return;
    }
    const exe = await this.programCommand(run, program, signal);
    if (typeof exe === "string") {
      if (signal.aborted) {
        all.forEach((i) => run.skipped(i));
      } else {
        fail(exe);
      }
      return;
    }
    const single = tests.length === 1 ? this.data.get(tests[0]) : undefined;
    const only = single?.test && !single.test.parameterized ? `${single.suite!.name}.${single.test.name}` : undefined;
    const xmlFile = path.join(os.tmpdir(), `zfls-pfunit-${process.pid}-${Date.now()}.xml`);
    const userArgs = vscode.workspace.getConfiguration("zfls.pfunit", program.folder.uri).get<string[]>("args", []);
    const args = pfunitArgs(exe.command.slice(1), xmlFile, only, userArgs);
    const cwd = exe.workingDirectory ?? this.buildDirectory(program.folder);
    run.appendOutput(`> ${exe.command[0]} ${args.join(" ")}\r\n`);
    this.log.info(`[pfunit] ${exe.command[0]} ${args.join(" ")} (in ${cwd})`);
    const start = Date.now();
    const result = await runProcess(exe.command[0], args, { cwd, signal });
    const duration = Date.now() - start;
    const output = result.stdout + (result.stderr ? `\n${result.stderr}` : "");
    run.appendOutput(output.replace(/\r?\n/g, "\r\n") + "\r\n", undefined, top);
    const xml = readText(xmlFile);
    fs.rmSync(xmlFile, { force: true });
    if (result.error && signal.aborted) {
      all.forEach((i) => run.skipped(i));
      return;
    }
    if (result.error) {
      fail(vscode.l10n.t("the test program did not run: {0}", result.error.message));
      return;
    }
    const results = parsePfunitXml(xml);
    if (!results.length) {
      fail(lastLines(output, 30) || vscode.l10n.t("exit code {0}", String(result.code)));
      return;
    }
    const failedSuites = new Set<vscode.TestItem>();
    for (const t of tests) {
      const d = this.data.get(t)!;
      const mine = results.filter((r) => resultOf(r.name, d.suite!.name, d.test!.name));
      if (!mine.length) {
        if (result.code === 0) {
          run.skipped(t);
        } else {
          run.errored(t, new vscode.TestMessage(vscode.l10n.t("no result: see the output")));
        }
        continue;
      }
      const ms = mine.reduce((sum, r) => sum + (r.time ?? 0), 0) * 1000;
      const bad = mine.filter((r) => r.status !== "passed");
      if (!bad.length) {
        run.passed(t, ms);
        continue;
      }
      failedSuites.add(t.parent!);
      const messages = bad.flatMap((r) => this.messages(t, r, d.file!, mine.length > 1));
      if (bad.every((r) => r.status === "errored")) {
        run.errored(t, messages, ms);
      } else {
        run.failed(t, messages, ms);
      }
    }
    for (const s of suites) {
      if (failedSuites.has(s)) {
        run.failed(s, new vscode.TestMessage(vscode.l10n.t("some of its tests failed")));
      } else {
        run.passed(s);
      }
    }
    if (!this.data.get(top)?.file) {
      if (result.code === 0) {
        run.passed(top, duration);
      } else {
        run.failed(top, new vscode.TestMessage(vscode.l10n.t("exit code {0}", String(result.code))), duration);
      }
    }
  }

  /** The messages of a failed result, at the failed assertion when its file
   * is the test's */
  private messages(item: vscode.TestItem, r: PfResult, file: string, named: boolean): vscode.TestMessage[] {
    const list = r.messages.length ? r.messages : [{ text: vscode.l10n.t("failed") }];
    return list.map((m) => {
      const message = new vscode.TestMessage(named ? `${r.name}: ${m.text}` : m.text);
      const here = m.file && path.basename(m.file).toLowerCase() === path.basename(file).toLowerCase();
      if (here && m.line) {
        message.location = new vscode.Location(vscode.Uri.file(file), new vscode.Position(m.line - 1, 0));
      } else if (item.uri && item.range) {
        message.location = new vscode.Location(item.uri, item.range);
      }
      return message;
    });
  }

  /** The build directory: zfls.pfunit.buildDirectory, else CMake Tools'
   * cmake.buildDirectory (when it has no variables but the folder's), else
   * build/ */
  private buildDirectory(folder: vscode.WorkspaceFolder): string {
    const vars = folderVariables(folder);
    const own = expandVariables(
      vscode.workspace.getConfiguration("zfls.pfunit", folder.uri).get<string>("buildDirectory", "").trim(),
      vars,
    );
    if (own) {
      return path.resolve(folder.uri.fsPath, own);
    }
    const tools = expandVariables(
      vscode.workspace.getConfiguration("cmake", folder.uri).get<string>("buildDirectory", "").trim(),
      vars,
    );
    if (tools && !tools.includes("${")) {
      return path.resolve(folder.uri.fsPath, tools);
    }
    return path.join(folder.uri.fsPath, "build");
  }

  /** cmake, and ctest next to it: CMake Tools' cmake.cmakePath, else the
   * PATH's */
  private cmake(folder: vscode.WorkspaceFolder): { cmake?: string; ctest?: string } {
    const configured = vscode.workspace.getConfiguration("cmake", folder.uri).get<string>("cmakePath", "").trim();
    const cmake = findExecutable("cmake", configured && configured !== "cmake" ? configured : "", folder.uri.fsPath);
    const sibling = cmake && findExecutable("ctest", path.dirname(cmake));
    return { cmake, ctest: sibling || findExecutable("ctest") };
  }

  /** The program's command from CTest, after building it (zfls.pfunit.build);
   * a message when there is none */
  private async programCommand(
    run: vscode.TestRun,
    program: Program,
    signal: AbortSignal,
  ): Promise<CtestCommand | string> {
    const dir = this.buildDirectory(program.folder);
    const { cmake, ctest } = this.cmake(program.folder);
    if (!fs.existsSync(path.join(dir, "CMakeCache.txt"))) {
      return vscode.l10n.t(
        "{0} is not a CMake build directory: configure the project, or set zfls.pfunit.buildDirectory.",
        dir,
      );
    }
    if (!ctest) {
      return vscode.l10n.t("ctest was not found: put CMake on the PATH, or set cmake.cmakePath.");
    }
    if (cmake && vscode.workspace.getConfiguration("zfls.pfunit", program.folder.uri).get<boolean>("build", true)) {
      const task = new vscode.Task(
        { type: "zfls", task: "build", target: program.name },
        program.folder,
        `build ${program.name}`,
        "zfls",
        new vscode.ProcessExecution(cmake, ["--build", dir, "--target", program.name]),
        PROBLEM_MATCHERS,
      );
      run.appendOutput(`> cmake --build ${dir} --target ${program.name}\r\n`);
      const built = await runTask(task);
      if (signal.aborted) {
        return "";
      }
      if (built !== 0) {
        return typeof built === "number"
          ? vscode.l10n.t("building {0} failed (exit code {1}); see the terminal.", program.name, built)
          : vscode.l10n.t("could not run the build task of {0}.", program.name);
      }
    }
    const listed = await runProcess(ctest, ["--show-only=json-v1"], { cwd: dir, signal, timeout: 60_000 });
    const command = parseCtestJson(listed.stdout).get(program.name);
    if (!command) {
      this.log.error(`[pfunit] ${ctest} --show-only=json-v1 (in ${dir}): ${listed.stderr || listed.stdout.slice(0, 500)}`);
      return vscode.l10n.t("CTest has no test {0} in {1}: configure the project, or set zfls.pfunit.buildDirectory.", program.name, dir);
    }
    return command;
  }

  /** Debugs each requested program, one after the other */
  private async debug(request: vscode.TestRunRequest, token: vscode.CancellationToken): Promise<void> {
    const run = this.controller.createTestRun(request);
    const abort = new AbortController();
    const cancelled = token.onCancellationRequested(() => abort.abort());
    try {
      for (const [top, picked] of this.byProgram(request)) {
        if (token.isCancellationRequested) {
          break;
        }
        const { program } = this.data.get(top)!;
        run.started(top);
        const exe = program.cmakeLists
          ? await this.programCommand(run, program, abort.signal)
          : vscode.l10n.t("No add_pfunit_ctest of a CMakeLists.txt names this file: zfls runs the pFUnit test programs that CMake builds.");
        if (typeof exe === "string") {
          run.errored(top, new vscode.TestMessage(exe));
          continue;
        }
        const tests = picked.flatMap((p) => this.tests(p, new Set(request.exclude ?? [])));
        const single = tests.length === 1 ? this.data.get(tests[0]) : undefined;
        const filter = single?.test && !single.test.parameterized ? ["-f", `${single.suite!.name}.${single.test.name}`] : [];
        const ended = sessionEnd();
        const started = await vscode.debug.startDebugging(program.folder, {
          type: "fortran",
          request: "launch",
          name: vscode.l10n.t("Debug {0}", program.name),
          program: exe.command[0],
          args: [...exe.command.slice(1), ...filter],
          cwd: exe.workingDirectory ?? this.buildDirectory(program.folder),
        });
        if (started) {
          await ended.promise;
          run.skipped(top);
        } else {
          ended.dispose();
          run.errored(top, new vscode.TestMessage(vscode.l10n.t("the debugger did not start")));
        }
      }
    } finally {
      cancelled.dispose();
      run.end();
    }
  }
}

function readText(file: string): string {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function lastLines(text: string, n: number): string {
  return text.trimEnd().split(/\r?\n/).slice(-n).join("\n");
}
