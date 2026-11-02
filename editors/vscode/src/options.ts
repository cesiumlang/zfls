// The zfls command line from the zfls.* settings of a workspace folder.

import * as path from "node:path";
import * as vscode from "vscode";
import { expandDirectoryGlob } from "./lint/paths";
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
  args.push(...formattingArguments(folder));
  args.push(...fortitudeArguments(folder));
  args.push(...codeeArguments(folder));
  args.push(...config.get<string[]>("arguments", []));
  return args;
}

/** Directories of a setting, with variables resolved and globs expanded */
function directories(patterns: string[], folder: vscode.WorkspaceFolder | undefined): string[] {
  const base = folder?.uri.fsPath;
  const dirs = patterns.filter((p) => p.trim()).map((p) => {
    const dir = resolvePath(p, folder);
    return base && !path.isAbsolute(dir) ? path.join(base, dir) : dir;
  });
  return [...new Set(dirs.flatMap(expandDirectoryGlob))];
}

/** The zfls options of the compiler that checks files (zfls's compiler
 * diagnostics, src/server/compile.zig), from the zfls.linter settings: the
 * compiler, its path, arguments, include and module directories, when it
 * checks, and fypp. zfls's own include directories (`zfls.includeDirs`) are
 * passed too. */
export function linterArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const config = vscode.workspace.getConfiguration("zfls.linter", folder?.uri);
  const compiler = config.get<string>("compiler", "gfortran");
  if (compiler === "Disabled") {
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
  const includes = directories(config.get<string[]>("includePaths", []), folder);
  if (includes.length) {
    args.push("--compiler_include_dirs", ...includes);
  }
  const modDir = config.get<string>("modOutput", "").trim();
  if (modDir) {
    args.push("--compiler_mod_dir", resolvePath(modDir, folder));
  }
  if (!config.get<boolean>("lintOnSave", true)) {
    args.push("--compiler_no_save");
  }
  if (config.get<boolean>("lintOnType", false)) {
    args.push("--compiler_on_change", "--compiler_change_delay", String(Math.max(0, config.get<number>("lintOnTypeDelay", 1000))));
  }
  if (!config.get<boolean>("resolveModules", true)) {
    args.push("--compiler_no_dependencies");
  }
  if (config.get<boolean>("fypp.enabled", false)) {
    const fypp = config.get<string>("fypp.path", "fypp").trim() || "fypp";
    // a name is looked for on the PATH; a path is resolved
    args.push("--compiler_fypp", programPath(fypp, folder));
    const fyppArgs = [
      ...directories(config.get<string[]>("fypp.includes", []), folder).map((d) => `-I${d}`),
      ...Object.entries(config.get<Record<string, string>>("fypp.definitions", {})).map(([k, v]) => (v ? `-D${k}=${v}` : `-D${k}`)),
      ...config.get<string[]>("fypp.extraArgs", []).filter((a) => a !== "").map((a) => resolvePath(a, folder)),
    ];
    if (fyppArgs.length) {
      args.push(`--compiler_fypp_args=${fyppArgs.join(" ")}`);
    }
  }
  return args;
}

/** A program's path setting: a name is looked for on the PATH, a path is
 * resolved */
function programPath(value: string, folder: vscode.WorkspaceFolder | undefined): string {
  return /[\\/]/.test(value) ? resolvePath(value, folder) : expandVariables(value, folderVariables(folder));
}

/** The zfls options of fortitude (zfls.fortitude settings): zfls runs it
 * and offers its fixes (src/server/linters.zig) */
function fortitudeArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const config = vscode.workspace.getConfiguration("zfls.fortitude", folder?.uri);
  if (!config.get<boolean>("enabled", false)) {
    return [];
  }
  const args = ["--fortitude"];
  const exe = config.get<string>("path", "").trim();
  if (exe) {
    args.push("--fortitude_path", programPath(exe, folder));
  }
  const extra = config.get<string[]>("args", []).filter((a) => a !== "");
  if (extra.length) {
    args.push(`--fortitude_args=${extra.map((a) => resolvePath(a, folder)).join(" ")}`);
  }
  if (config.get<boolean>("lintOnType", false)) {
    args.push("--fortitude_on_change", "--fortitude_change_delay", String(Math.max(0, config.get<number>("lintOnTypeDelay", 500))));
  }
  return args;
}

/** The zfls options of Codee (zfls.codee settings); `${file}` in its
 * arguments is left for zfls, which puts each file there */
function codeeArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const config = vscode.workspace.getConfiguration("zfls.codee", folder?.uri);
  if (!config.get<boolean>("enabled", false)) {
    return [];
  }
  const args = ["--codee"];
  const exe = config.get<string>("path", "").trim();
  if (exe) {
    args.push("--codee_path", programPath(exe, folder));
  }
  const extra = config.get<string[]>("args", []).filter((a) => a !== "");
  if (extra.length) {
    args.push(`--codee_args=${extra.map((a) => resolvePath(a, folder)).join(" ")}`);
  }
  return args;
}

/** The zfls options of the formatter (zfls.formatting.*), which zfls runs
 * for Format Document and Format Selection. The formatter and its
 * arguments can differ by language: free form's are zfls's `formatter`,
 * fixed form's its `formatter_fixed`. None when neither has one. */
export function formattingArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const forms = [
    { languageId: "FortranFreeForm", flag: "--formatter", argsFlag: "--formatter_args" },
    { languageId: "FortranFixedForm", flag: "--formatter_fixed", argsFlag: "--formatter_fixed_args" },
  ];
  const args: string[] = [];
  let any = false;
  for (const { languageId, flag, argsFlag } of forms) {
    const config = vscode.workspace.getConfiguration("zfls.formatting", { uri: folder?.uri, languageId });
    const formatter = config.get<string>("formatter", "Disabled");
    if (formatter !== "findent" && formatter !== "fprettify") {
      args.push(flag, "none");
      continue;
    }
    any = true;
    args.push(flag, formatter);
    const extra = config.get<string[]>(`${formatter}Args`, []).filter((a) => a !== "");
    if (extra.length) {
      args.push(`${argsFlag}=${extra.map((a) => resolvePath(a, folder)).join(" ")}`);
    }
  }
  if (!any) {
    return [];
  }
  const exe = vscode.workspace.getConfiguration("zfls.formatting", folder?.uri).get<string>("path", "").trim();
  if (exe) {
    args.push("--formatter_path", resolvePath(exe, folder));
  }
  return args;
}

/** Whether a configuration change needs the language servers restarted */
export function affectsServer(e: vscode.ConfigurationChangeEvent): boolean {
  return (
    e.affectsConfiguration("zfls.path") ||
    e.affectsConfiguration("zfls.arguments") ||
    e.affectsConfiguration("zfls.linter") ||
    e.affectsConfiguration("zfls.fortitude") ||
    e.affectsConfiguration("zfls.codee") ||
    e.affectsConfiguration("zfls.formatting") ||
    OPTIONS.some((o) => e.affectsConfiguration(`zfls.${o.setting}`))
  );
}
