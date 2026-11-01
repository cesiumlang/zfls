// The Fortran Module Variables view of Run and Debug: while a program is
// stopped in a Fortran file, the module variables that the selected
// frame's line sees (`zfls/moduleVariables`), with their values, which the
// C debuggers' Variables view leaves out (FortranBreaker #10). The debugger
// is asked for each by the names that the compilers give module variables,
// until one has a value; the form that worked is tried first after.

import * as vscode from "vscode";
import type { LanguageClient } from "vscode-languageclient/node";
import { ModuleVariable, NameForm, byModule, expression, isErrorValue, tryOrder } from "./moduleVariables";

const LANGUAGES = ["FortranFreeForm", "FortranFixedForm"];
/** Set while the selected frame is in a Fortran file: the view shows */
const CONTEXT_KEY = "zfls.fortranFrame";

interface Frame {
  session: vscode.DebugSession;
  frameId: number;
  uri: vscode.Uri;
  /** 1-based, as the debugger gives it */
  line: number;
}

type Node =
  | { kind: "module"; module: string; vars: Node[] }
  | {
      kind: "variable";
      session: vscode.DebugSession;
      v: ModuleVariable;
      value?: string;
      type?: string;
      ref: number;
      expression?: string;
    }
  | { kind: "member"; session: vscode.DebugSession; name: string; value: string; type?: string; ref: number };

interface EvaluateResponse {
  result: string;
  type?: string;
  variablesReference?: number;
}

interface DapVariable {
  name: string;
  value: string;
  type?: string;
  variablesReference?: number;
}

export function registerModuleVariables(
  context: vscode.ExtensionContext,
  clientFor: (uri: vscode.Uri) => Promise<LanguageClient | undefined>,
): void {
  const view = new ModuleVariablesView(clientFor);
  const tree = vscode.window.createTreeView("zfls.moduleVariables", { treeDataProvider: view });
  view.tree = tree;
  context.subscriptions.push(
    tree,
    view,
    vscode.debug.onDidChangeActiveStackItem(() => void view.refresh()),
    vscode.debug.onDidTerminateDebugSession((s) => view.ended(s)),
  );
}

class ModuleVariablesView implements vscode.TreeDataProvider<Node>, vscode.Disposable {
  tree?: vscode.TreeView<Node>;
  private roots: Node[] = [];
  private readonly changed = new vscode.EventEmitter<Node | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  /** The name form that gave a value, by debug session */
  private readonly worked = new Map<string, NameForm>();
  /** Bumped by each refresh: an older one's results are dropped */
  private generation = 0;

  constructor(private readonly clientFor: (uri: vscode.Uri) => Promise<LanguageClient | undefined>) {}

  dispose(): void {
    this.changed.dispose();
  }

  ended(session: vscode.DebugSession): void {
    this.worked.delete(session.id);
    if (!vscode.debug.activeDebugSession) {
      this.show([]);
    }
  }

  async refresh(): Promise<void> {
    const generation = ++this.generation;
    const frame = await this.selectedFrame();
    if (generation !== this.generation) {
      return;
    }
    if (!frame) {
      this.show([]);
      return;
    }
    const client = await this.clientFor(frame.uri);
    let vars: ModuleVariable[] = [];
    try {
      vars =
        (await client?.sendRequest<ModuleVariable[] | null>("zfls/moduleVariables", {
          textDocument: { uri: client.code2ProtocolConverter.asUri(frame.uri) },
          position: { line: frame.line - 1, character: 0 },
        })) ?? [];
    } catch {
      // an older zfls, or one stopping
    }
    const roots: Node[] = byModule(vars).map((g) => ({
      kind: "module",
      module: g.module,
      vars: g.vars.map((v) => ({ kind: "variable", session: frame.session, v, ref: 0 })),
    }));
    await Promise.all(
      roots.flatMap((m) => (m.kind === "module" ? m.vars : [])).map((n) => this.evaluate(frame, n)),
    );
    if (generation === this.generation) {
      this.show(roots, vars.length === 0 ? vscode.l10n.t("No module variables are visible here.") : undefined);
    }
  }

  private show(roots: Node[], message?: string): void {
    this.roots = roots;
    if (this.tree) {
      this.tree.message = message;
    }
    this.changed.fire(undefined);
  }

  /** The selected stack frame, when it is in a Fortran file */
  private async selectedFrame(): Promise<Frame | undefined> {
    const item = vscode.debug.activeStackItem;
    const fortran = async (): Promise<Frame | undefined> => {
      if (!(item instanceof vscode.DebugStackFrame)) {
        return undefined;
      }
      let frames: { id: number; line: number; source?: { path?: string } }[];
      try {
        const r = await item.session.customRequest("stackTrace", { threadId: item.threadId, startFrame: 0, levels: 200 });
        frames = r?.stackFrames ?? [];
      } catch {
        return undefined;
      }
      const f = frames.find((x) => x.id === item.frameId);
      if (!f?.source?.path) {
        return undefined;
      }
      const uri = vscode.Uri.file(f.source.path);
      try {
        const doc = await vscode.workspace.openTextDocument(uri);
        if (!LANGUAGES.includes(doc.languageId)) {
          return undefined;
        }
      } catch {
        return undefined;
      }
      return { session: item.session, frameId: item.frameId, uri, line: f.line };
    };
    const frame = await fortran();
    void vscode.commands.executeCommand("setContext", CONTEXT_KEY, frame !== undefined);
    return frame;
  }

  /** Asks the debugger for a variable's value, by each form of its name */
  private async evaluate(frame: Frame, node: Node): Promise<void> {
    if (node.kind !== "variable") {
      return;
    }
    const session = frame.session;
    for (const form of tryOrder(session.type, this.worked.get(session.id))) {
      const expr = expression(form, node.v.module, node.v.name);
      try {
        const r: EvaluateResponse | undefined = await session.customRequest("evaluate", {
          expression: expr,
          frameId: frame.frameId,
          context: "watch",
        });
        if (!r || typeof r.result !== "string" || isErrorValue(r.result)) {
          continue;
        }
        this.worked.set(session.id, form);
        node.value = r.result;
        node.type = r.type;
        node.ref = r.variablesReference ?? 0;
        node.expression = expr;
        return;
      } catch {
        // not a name this debugger knows
      }
    }
  }

  getTreeItem(node: Node): vscode.TreeItem {
    switch (node.kind) {
      case "module": {
        const item = new vscode.TreeItem(node.module, vscode.TreeItemCollapsibleState.Expanded);
        item.iconPath = new vscode.ThemeIcon("symbol-module");
        return item;
      }
      case "variable": {
        const v = node.v;
        const renamed = v.local.toLowerCase() !== v.name.toLowerCase();
        const label = renamed ? vscode.l10n.t("{0} (renamed from {1})", v.local, v.name) : v.local;
        const item = new vscode.TreeItem(
          label,
          node.ref > 0 ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None,
        );
        item.description = node.value ?? vscode.l10n.t("not available");
        item.iconPath = new vscode.ThemeIcon("symbol-variable");
        const tip = new vscode.MarkdownString().appendCodeblock(`${v.type} :: ${v.name}`, "fortran");
        tip.appendMarkdown(
          node.expression
            ? vscode.l10n.t("Evaluated as `{0}`", node.expression)
            : vscode.l10n.t("The debugger has no value for it here."),
        );
        item.tooltip = tip;
        return item;
      }
      case "member": {
        const item = new vscode.TreeItem(
          node.name,
          node.ref > 0 ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None,
        );
        item.description = node.value;
        item.tooltip = node.type;
        return item;
      }
    }
  }

  async getChildren(node?: Node): Promise<Node[]> {
    if (!node) {
      return this.roots;
    }
    if (node.kind === "module") {
      return node.vars;
    }
    if (node.ref <= 0) {
      return [];
    }
    try {
      const r = await node.session.customRequest("variables", { variablesReference: node.ref });
      return ((r?.variables ?? []) as DapVariable[]).map((x) => ({
        kind: "member",
        session: node.session,
        name: x.name,
        value: x.value,
        type: x.type,
        ref: x.variablesReference ?? 0,
      }));
    } catch {
      return [];
    }
  }
}
