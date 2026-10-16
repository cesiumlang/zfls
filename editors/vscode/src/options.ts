// The zfls command line from the zfls.* settings of a workspace folder.

import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";

/** A setting and the zfls option it becomes */
type Option =
  | { setting: string; flag: string; kind: "flag" }
  | { setting: string; flag: string; kind: "int" }
  | { setting: string; flag: string; kind: "string"; path?: boolean }
  | { setting: string; flag: string; kind: "list"; path?: boolean }
  | { setting: string; flag: string; kind: "json" };

/** The typed settings, in the order their options are passed */
export const OPTIONS: readonly Option[] = [
  { setting: "incrementalSync", flag: "--incremental_sync", kind: "flag" },
  { setting: "signatureHelp", flag: "--use_signature_help", kind: "flag" },
  { setting: "codeActions", flag: "--enable_code_actions", kind: "flag" },
  { setting: "hoverSignature", flag: "--hover_signature", kind: "flag" },
  { setting: "lowercaseIntrinsics", flag: "--lowercase_intrinsics", kind: "flag" },
  { setting: "autocompleteNameOnly", flag: "--autocomplete_name_only", kind: "flag" },
  { setting: "autocompleteNoSnippets", flag: "--autocomplete_no_snippets", kind: "flag" },
  { setting: "sortKeywords", flag: "--sort_keywords", kind: "flag" },
  { setting: "symbolSkipMembers", flag: "--symbol_skip_mem", kind: "flag" },
  { setting: "disableDiagnostics", flag: "--disable_diagnostics", kind: "flag" },
  { setting: "notifyInit", flag: "--notify_init", kind: "flag" },
  { setting: "nthreads", flag: "--nthreads", kind: "int" },
  { setting: "maxLineLength", flag: "--max_line_length", kind: "int" },
  { setting: "maxCommentLineLength", flag: "--max_comment_line_length", kind: "int" },
  { setting: "configFile", flag: "--config", kind: "string", path: true },
  { setting: "sourceDirs", flag: "--source_dirs", kind: "list", path: true },
  { setting: "includeDirs", flag: "--include_dirs", kind: "list", path: true },
  { setting: "excludePaths", flag: "--excl_paths", kind: "list", path: true },
  { setting: "includeSuffixes", flag: "--incl_suffixes", kind: "list" },
  { setting: "excludeSuffixes", flag: "--excl_suffixes", kind: "list" },
  { setting: "ppSuffixes", flag: "--pp_suffixes", kind: "list" },
  { setting: "ppDefs", flag: "--pp_defs", kind: "json" },
];

/** `${workspaceFolder}`, `${workspaceFolder:name}`, `${userHome}`,
 * `${env:NAME}` and a leading `~` in a path setting */
export function resolvePath(value: string, folder: vscode.WorkspaceFolder | undefined): string {
  let v = value.replace(/\$\{(workspaceFolder(?::([^}]+))?|userHome|env:([^}]+))\}/g, (all, what: string, name?: string, env?: string) => {
    if (env !== undefined) {
      return process.env[env] ?? "";
    }
    if (what === "userHome") {
      return os.homedir();
    }
    if (name !== undefined) {
      const named = vscode.workspace.workspaceFolders?.find((f) => f.name === name);
      return named ? named.uri.fsPath : all;
    }
    return folder ? folder.uri.fsPath : all;
  });
  if (v === "~" || v.startsWith("~/") || v.startsWith("~\\")) {
    v = path.join(os.homedir(), v.slice(1));
  }
  return v;
}

/** The zfls arguments for `folder` (or for files outside any folder): the
 * typed settings that differ from zfls's own defaults, then
 * `zfls.arguments` */
export function serverArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const config = vscode.workspace.getConfiguration("zfls", folder?.uri);
  const args: string[] = [];
  for (const o of OPTIONS) {
    const value = config.get<unknown>(o.setting);
    if (value === undefined || value === null) {
      continue;
    }
    switch (o.kind) {
      case "flag":
        if (value === true) {
          args.push(o.flag);
        }
        break;
      case "int":
        if (typeof value === "number" && Number.isInteger(value) && value >= 0) {
          args.push(o.flag, String(value));
        }
        break;
      case "string":
        if (typeof value === "string" && value !== "") {
          args.push(o.flag, o.path ? resolvePath(value, folder) : value);
        }
        break;
      case "list":
        if (Array.isArray(value) && value.length > 0) {
          const items = value.filter((x): x is string => typeof x === "string" && x !== "");
          if (items.length > 0) {
            args.push(o.flag, ...items.map((x) => (o.path ? resolvePath(x, folder) : x)));
          }
        }
        break;
      case "json":
        if (typeof value === "object" && Object.keys(value as object).length > 0) {
          args.push(o.flag, JSON.stringify(value));
        }
        break;
    }
  }
  args.push(...config.get<string[]>("arguments", []));
  return args;
}

/** Whether a configuration change needs the language servers restarted */
export function affectsServer(e: vscode.ConfigurationChangeEvent): boolean {
  return (
    e.affectsConfiguration("zfls.path") ||
    e.affectsConfiguration("zfls.arguments") ||
    OPTIONS.some((o) => e.affectsConfiguration(`zfls.${o.setting}`))
  );
}
