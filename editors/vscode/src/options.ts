// The zfls command line from the zfls.* settings of a workspace folder.

import * as vscode from "vscode";
import { expandVariables } from "./tools";
import { folderVariables } from "./variables";

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
  { setting: "preferImplementation", flag: "--prefer_implementation", kind: "flag" },
  { setting: "lowercaseHover", flag: "--lowercase_hover", kind: "flag" },
  { setting: "lowercaseIntrinsics", flag: "--lowercase_intrinsics", kind: "flag" },
  { setting: "autocompleteNameOnly", flag: "--autocomplete_name_only", kind: "flag" },
  { setting: "autocompleteNoSnippets", flag: "--autocomplete_no_snippets", kind: "flag" },
  { setting: "autocompleteNoAutoUse", flag: "--autocomplete_no_auto_use", kind: "flag" },
  { setting: "sortKeywords", flag: "--sort_keywords", kind: "flag" },
  { setting: "symbolSkipMembers", flag: "--symbol_skip_mem", kind: "flag" },
  { setting: "disableDiagnostics", flag: "--disable_diagnostics", kind: "flag" },
  { setting: "workspaceDiagnostics", flag: "--workspace_diagnostics", kind: "flag" },
  { setting: "notifyInit", flag: "--notify_init", kind: "flag" },
  { setting: "nthreads", flag: "--nthreads", kind: "int" },
  { setting: "maxLineLength", flag: "--max_line_length", kind: "int" },
  { setting: "maxCommentLineLength", flag: "--max_comment_line_length", kind: "int" },
  { setting: "fixedFormLineLength", flag: "--fixed_line_length", kind: "int" },
  { setting: "configFile", flag: "--config", kind: "string", path: true },
  { setting: "sourceDirs", flag: "--source_dirs", kind: "list", path: true },
  { setting: "includeDirs", flag: "--include_dirs", kind: "list", path: true },
  { setting: "excludePaths", flag: "--excl_paths", kind: "list", path: true },
  { setting: "commentMarkers", flag: "--comment_markers", kind: "list" },
  { setting: "compileCommands", flag: "--compile_commands", kind: "string", path: true },
  { setting: "includeSuffixes", flag: "--incl_suffixes", kind: "list" },
  { setting: "excludeSuffixes", flag: "--excl_suffixes", kind: "list" },
  { setting: "ppSuffixes", flag: "--pp_suffixes", kind: "list" },
  { setting: "ppDefs", flag: "--pp_defs", kind: "json" },
  { setting: "diagnosticSeverity", flag: "--diagnostic_severity", kind: "json" },
  { setting: "externalModules", flag: "--external_modules", kind: "list" },
];

/** A path setting of `folder` with its variables expanded; the server
 * takes a relative one as relative to its root */
function resolvePath(value: string, folder: vscode.WorkspaceFolder | undefined): string {
  return expandVariables(value, folderVariables(folder));
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
  args.push(...linterArguments(folder));
  args.push(...config.get<string[]>("arguments", []));
  return args;
}

/** With zfls.linter.runner set to `server`, the zfls options of the
 * compiler that checks files: `zfls.linter.compiler`, its path, its
 * arguments and its module directory. Its include directories are zfls's
 * (`zfls.includeDirs`). */
export function linterArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const config = vscode.workspace.getConfiguration("zfls.linter", folder?.uri);
  const compiler = config.get<string>("compiler", "gfortran");
  if (config.get<string>("runner", "extension") !== "server" || compiler === "Disabled") {
    return [];
  }
  const args = ["--compiler_diagnostics", compiler];
  const exe = config.get<string>("compilerPath", "").trim();
  if (exe) {
    args.push("--compiler_path", resolvePath(exe, folder));
  }
  const extra = config.get<string[]>("extraArgs", []).filter((a) => a !== "");
  if (extra.length) {
    args.push(`--compiler_args=${extra.map((a) => resolvePath(a, folder)).join(" ")}`);
  }
  const modDir = config.get<string>("modOutput", "").trim();
  if (modDir) {
    args.push("--compiler_mod_dir", resolvePath(modDir, folder));
  }
  return args;
}

/** Whether a configuration change needs the language servers restarted */
export function affectsServer(e: vscode.ConfigurationChangeEvent): boolean {
  return (
    e.affectsConfiguration("zfls.path") ||
    e.affectsConfiguration("zfls.arguments") ||
    e.affectsConfiguration("zfls.linter.runner") ||
    (["compiler", "compilerPath", "extraArgs", "modOutput"].some((s) => e.affectsConfiguration(`zfls.linter.${s}`)) &&
      vscode.workspace.getConfiguration("zfls.linter").get<string>("runner", "extension") === "server") ||
    OPTIONS.some((o) => e.affectsConfiguration(`zfls.${o.setting}`))
  );
}
