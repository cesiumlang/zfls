// The zfls command line from the zfls.* settings of a workspace folder, and
// the same settings under zfls's configuration-file names, which a running
// server takes over LSP (workspace/didChangeConfiguration).

import * as path from "node:path";
import * as vscode from "vscode";
import { FORMATTERS, type ServerSettings, withoutArguments } from "./settingsSync";
import { fileAssociations } from "./sourceForm";
import { expandVariables } from "./tools";
import { folderVariables } from "./variables";

/** A setting and the zfls option it becomes. `restart`: a running server
 * cannot change it (it is read at start-up only). `fallback`: zfls's own
 * default, for a value the command line leaves out. `rewatch`: it changes
 * which files the file watcher follows, so a change restarts the server. */
export type Option =
  | { setting: string; flag: string; kind: "flag"; restart?: true }
  | { setting: string; flag: string; kind: "int"; fallback: number }
  | { setting: string; flag: string; kind: "string"; path?: boolean; restart?: true }
  | { setting: string; flag: string; kind: "list"; path?: boolean; rewatch?: true }
  | { setting: string; flag: string; kind: "json" };

/** The typed settings, in the order their options are passed */
export const OPTIONS: readonly Option[] = [
  { setting: "incrementalSync", flag: "--incremental_sync", kind: "flag", restart: true },
  { setting: "signatureHelp", flag: "--use_signature_help", kind: "flag" },
  { setting: "codeActions", flag: "--enable_code_actions", kind: "flag" },
  { setting: "hoverSignature", flag: "--hover_signature", kind: "flag" },
  { setting: "docMath", flag: "--doc_math", kind: "string" },
  { setting: "preferImplementation", flag: "--prefer_implementation", kind: "flag" },
  { setting: "lowercaseHover", flag: "--lowercase_hover", kind: "flag" },
  { setting: "hoverNoTypeComponents", flag: "--hover_no_type_components", kind: "flag" },
  { setting: "hoverPlainComments", flag: "--hover_plain_comments", kind: "flag" },
  { setting: "lowercaseIntrinsics", flag: "--lowercase_intrinsics", kind: "flag" },
  { setting: "autocompleteNameOnly", flag: "--autocomplete_name_only", kind: "flag" },
  { setting: "autocompleteNoSnippets", flag: "--autocomplete_no_snippets", kind: "flag" },
  { setting: "autocompleteNoAutoUse", flag: "--autocomplete_no_auto_use", kind: "flag" },
  { setting: "sortKeywords", flag: "--sort_keywords", kind: "flag" },
  { setting: "symbolSkipMembers", flag: "--symbol_skip_mem", kind: "flag" },
  { setting: "codeLensNoReferences", flag: "--code_lens_no_references", kind: "flag" },
  { setting: "codeLensNoRun", flag: "--code_lens_no_run", kind: "flag" },
  { setting: "disableDiagnostics", flag: "--disable_diagnostics", kind: "flag" },
  { setting: "debugLog", flag: "--debug_log", kind: "flag", restart: true },
  { setting: "disableIndexCache", flag: "--disable_index_cache", kind: "flag" },
  { setting: "disableCompileCommands", flag: "--disable_compile_commands", kind: "flag" },
  { setting: "disableBindCSearch", flag: "--disable_bind_c_search", kind: "flag" },
  { setting: "bindCClangd", flag: "--bind_c_clangd", kind: "string", path: true },
  { setting: "workspaceDiagnostics", flag: "--workspace_diagnostics", kind: "flag" },
  { setting: "diagnosticsChangeDelay", flag: "--diagnostics_change_delay", kind: "int", fallback: 300 },
  { setting: "notifyInit", flag: "--notify_init", kind: "flag" },
  { setting: "nthreads", flag: "--nthreads", kind: "int", fallback: 4 },
  { setting: "maxLineLength", flag: "--max_line_length", kind: "int", fallback: -1 },
  { setting: "maxCommentLineLength", flag: "--max_comment_line_length", kind: "int", fallback: -1 },
  { setting: "fixedFormLineLength", flag: "--fixed_line_length", kind: "int", fallback: -1 },
  { setting: "configFile", flag: "--config", kind: "string", path: true, restart: true },
  { setting: "sourceDirs", flag: "--source_dirs", kind: "list", path: true },
  { setting: "includeDirs", flag: "--include_dirs", kind: "list", path: true },
  { setting: "excludePaths", flag: "--excl_paths", kind: "list", path: true },
  { setting: "commentMarkers", flag: "--comment_markers", kind: "list" },
  { setting: "disableOpenmpConditional", flag: "--disable_openmp_conditional", kind: "flag" },
  { setting: "fixedFormDLines", flag: "--d_lines", kind: "string" },
  { setting: "compileCommands", flag: "--compile_commands", kind: "string", path: true },
  { setting: "includeSuffixes", flag: "--incl_suffixes", kind: "list", rewatch: true },
  { setting: "excludeSuffixes", flag: "--excl_suffixes", kind: "list" },
  { setting: "ppSuffixes", flag: "--pp_suffixes", kind: "list", rewatch: true },
  { setting: "ppDefs", flag: "--pp_defs", kind: "json" },
  { setting: "disableIntelDirectives", flag: "--disable_intel_directives", kind: "flag" },
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
  const associations = editorAssociations();
  if (Object.keys(associations).length > 0) {
    args.push("--file_associations", JSON.stringify(associations));
  }
  args.push(...linterArguments(folder));
  args.push(...formattingArguments(folder));
  args.push(...fortitudeArguments(folder));
  args.push(...codeeArguments(folder));
  args.push(...extraArguments(config));
  return args;
}

/** Whether fypp runs: on, and in a trusted workspace */
function fyppAllowed(config: vscode.WorkspaceConfiguration): boolean {
  return vscode.workspace.isTrusted && config.get<boolean>("fypp.enabled", false);
}

/** `zfls.arguments`; the settings editor's "Add Item" leaves empty items
 * easily */
function extraArguments(config: vscode.WorkspaceConfiguration): string[] {
  return config.get<unknown[]>("arguments", []).filter((a): a is string => typeof a === "string" && a.trim() !== "");
}

/** Directories of a setting, with variables resolved, relative to the
 * workspace folder; zfls expands the glob patterns among them */
function directories(patterns: string[], folder: vscode.WorkspaceFolder | undefined): string[] {
  const base = folder?.uri.fsPath;
  const dirs = patterns.filter((p) => p.trim()).map((p) => {
    const dir = resolvePath(p, folder);
    return base && !path.isAbsolute(dir) ? path.join(base, dir) : dir;
  });
  return [...new Set(dirs)];
}

/** lintOnTypeDelay as whole milliseconds, never negative. */
function delayMs(config: vscode.WorkspaceConfiguration, fallback: number): number {
  const value = Math.round(config.get<number>("lintOnTypeDelay", fallback));
  return Number.isFinite(value) ? Math.max(0, value) : fallback;
}

/** The zfls options of the compiler that checks files (zfls's compiler
 * diagnostics, src/server/compile.zig), from the zfls.linter settings: the
 * compiler, its path, arguments, include and module directories, when it
 * checks, and fypp. zfls's own include directories (`zfls.includeDirs`) are
 * passed too. */
export function linterArguments(folder: vscode.WorkspaceFolder | undefined): string[] {
  const config = vscode.workspace.getConfiguration("zfls.linter", folder?.uri);
  const compiler = config.get<string>("compiler", "gfortran");
  const fixed = fixedCompilerSettings(config, folder);
  const dialect = config.get<string>("dialect", "").trim();
  const lint = dialect ? ["--lint_dialect", dialect] : [];
  if (compiler === "Disabled" && !fixed.compiler_diagnostics_fixed) {
    return lint;
  }
  const args = [...lint, "--compiler_diagnostics", compiler === "Disabled" ? "none" : compiler];
  if (fixed.compiler_diagnostics_fixed) {
    args.push("--compiler_diagnostics_fixed", fixed.compiler_diagnostics_fixed);
  }
  if (fixed.compiler_path_fixed) {
    args.push("--compiler_path_fixed", fixed.compiler_path_fixed);
  }
  if (fixed.compiler_args_fixed !== null) {
    args.push(argOption("--compiler_args_fixed", fixed.compiler_args_fixed));
  }
  const exe = config.get<string>("compilerPath", "").trim();
  if (exe) {
    args.push("--compiler_path", resolvePath(exe, folder));
  }
  const extra = config.get<string[]>("extraArgs", []).filter((a) => a !== "");
  if (extra.length) {
    args.push(argOption("--compiler_args", extra.map((a) => resolvePath(a, folder))));
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
    args.push("--compiler_on_change", "--compiler_change_delay", String(delayMs(config, 1000)));
  }
  if (!config.get<boolean>("resolveModules", true)) {
    args.push("--compiler_no_dependencies");
  }
  if (config.get<boolean>("noCompileCommands", false)) {
    args.push("--compiler_no_compile_commands");
  }
  // fypp runs the Python of the files it reads: not in a workspace the user
  // has not trusted (its own value of the setting is restricted, a user's
  // is not)
  if (fyppAllowed(config)) {
    const fypp = config.get<string>("fypp.path", "fypp").trim() || "fypp";
    // a name is looked for on the PATH; a path is resolved
    args.push("--compiler_fypp", programPath(fypp, folder));
    const fyppArgs = [
      ...directories(config.get<string[]>("fypp.includes", []), folder).map((d) => `-I${d}`),
      ...Object.entries(config.get<Record<string, string>>("fypp.definitions", {})).map(([k, v]) => (v ? `-D${k}=${v}` : `-D${k}`)),
      ...config.get<string[]>("fypp.extraArgs", []).filter((a) => a !== "").map((a) => resolvePath(a, folder)),
    ];
    if (fyppArgs.length) {
      args.push(argOption("--compiler_fypp_args", fyppArgs));
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
    args.push(argOption("--fortitude_args", extra.map((a) => resolvePath(a, folder))));
  }
  if (config.get<boolean>("lintOnType", false)) {
    args.push("--fortitude_on_change", "--fortitude_change_delay", String(delayMs(config, 500)));
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
    args.push(argOption("--codee_args", extra.map((a) => resolvePath(a, folder))));
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
  let codee = false;
  for (const { languageId, flag, argsFlag } of forms) {
    const config = vscode.workspace.getConfiguration("zfls.formatting", { uri: folder?.uri, languageId });
    const formatter = config.get<string>("formatter", "Disabled");
    if (!FORMATTERS.includes(formatter)) {
      args.push(flag, "none");
      continue;
    }
    any = true;
    codee ||= formatter === "codee";
    args.push(flag, formatter);
    const extra = config.get<string[]>(`${formatter}Args`, []).filter((a) => a !== "");
    if (extra.length) {
      args.push(argOption(argsFlag, extra.map((a) => resolvePath(a, folder))));
    }
  }
  if (!any) {
    return [];
  }
  const exe = formatterPath(folder, codee);
  if (exe) {
    args.push("--formatter_path", resolvePath(exe, folder));
  }
  return args;
}

/** zfls.formatting.path, else for Codee's formatter zfls.codee.path */
function formatterPath(folder: vscode.WorkspaceFolder | undefined, codee: boolean): string {
  const exe = vscode.workspace.getConfiguration("zfls.formatting", folder?.uri).get<string>("path", "").trim();
  if (exe || !codee) {
    return exe;
  }
  return vscode.workspace.getConfiguration("zfls.codee", folder?.uri).get<string>("path", "").trim();
}

/** The settings of `serverArguments` (but `zfls.arguments`, those its
 * options set, and those a running server cannot change) under zfls's
 * configuration-file names, each with its value: what the command line
 * would set, else zfls's default. Sent at start (`initializationOptions`)
 * and to a running server, they take over from its command line and the
 * user's configuration file. `source_dirs` is left out when empty: zfls's
 * default (the root) has no value to send. */
export function serverSettings(folder: vscode.WorkspaceFolder | undefined): ServerSettings {
  const config = vscode.workspace.getConfiguration("zfls", folder?.uri);
  const out: ServerSettings = {};
  for (const o of OPTIONS) {
    if ("restart" in o) {
      continue;
    }
    const key = o.flag.slice(2);
    const value = config.get<unknown>(o.setting);
    switch (o.kind) {
      case "flag":
        out[key] = value === true;
        break;
      case "int":
        out[key] = typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : o.fallback;
        break;
      case "string":
        out[key] = typeof value === "string" && value !== "" ? (o.path ? resolvePath(value, folder) : value) : null;
        break;
      case "list": {
        const items = (Array.isArray(value) ? value : []).filter((x): x is string => typeof x === "string" && x !== "");
        const list = items.map((x) => (o.path ? resolvePath(x, folder) : x));
        if (key === "source_dirs" && list.length === 0) {
          break;
        }
        // no pp_suffixes: the default rule (uppercase extensions)
        out[key] = key === "pp_suffixes" && list.length === 0 ? null : list;
        break;
      }
      case "json":
        out[key] = value !== null && typeof value === "object" ? value : {};
        break;
    }
  }
  const all = {
    ...out,
    file_associations: editorAssociations(),
    ...linterSettings(folder),
    ...formattingSettings(folder),
    ...fortitudeSettings(folder),
    ...codeeSettings(folder),
  };
  return withoutArguments(all, extraArguments(config));
}

/** The settings sent at start (`initializationOptions`): `serverSettings`,
 * and those a server reads only then (`incremental_sync`) */
export function startSettings(folder: vscode.WorkspaceFolder | undefined): ServerSettings {
  const config = vscode.workspace.getConfiguration("zfls", folder?.uri);
  const flags = OPTIONS.filter((o) => "restart" in o && o.kind === "flag").map((o) => [o.flag.slice(2), config.get(o.setting) === true]);
  return withoutArguments({ ...serverSettings(folder), ...Object.fromEntries(flags) }, extraArguments(config));
}

/** `files.associations` for zfls (`fileAssociations`): as VS Code's
 * languages read it, of no folder */
function editorAssociations(): Record<string, string> {
  return fileAssociations(vscode.workspace.getConfiguration("files").get<unknown>("associations"));
}

/** The compiler of fixed-form files (`zfls.linter.fixedCompiler`, its path
 * and arguments) as settings; null: those of free form */
function fixedCompilerSettings(config: vscode.WorkspaceConfiguration, folder: vscode.WorkspaceFolder | undefined) {
  const name = config.get<string>("fixedCompiler", "").trim();
  const exe = config.get<string>("fixedCompilerPath", "").trim();
  const extra = config.get<string[] | null>("fixedExtraArgs", null);
  return {
    compiler_diagnostics_fixed: name === "" ? null : name === "Disabled" ? "none" : name,
    compiler_path_fixed: exe ? resolvePath(exe, folder) : null,
    compiler_args_fixed: Array.isArray(extra) ? extra.filter((a) => a !== "").map((a) => resolvePath(a, folder)) : null,
  };
}

/** `linterArguments` as settings */
function linterSettings(folder: vscode.WorkspaceFolder | undefined): ServerSettings {
  const config = vscode.workspace.getConfiguration("zfls.linter", folder?.uri);
  const compiler = config.get<string>("compiler", "gfortran");
  const fixed = fixedCompilerSettings(config, folder);
  const on = compiler !== "Disabled" || fixed.compiler_diagnostics_fixed !== null;
  const exe = config.get<string>("compilerPath", "").trim();
  const extra = config.get<string[]>("extraArgs", []).filter((a) => a !== "");
  const modDir = config.get<string>("modOutput", "").trim();
  const fypp = on && fyppAllowed(config);
  return {
    compiler_diagnostics: compiler !== "Disabled" ? compiler : null,
    ...fixed,
    compiler_path: on && exe ? resolvePath(exe, folder) : null,
    lint_dialect: config.get<string>("dialect", "").trim() || null,
    compiler_args: on && extra.length ? extra.map((a) => resolvePath(a, folder)) : null,
    compiler_include_dirs: on ? directories(config.get<string[]>("includePaths", []), folder) : [],
    compiler_mod_dir: on && modDir ? resolvePath(modDir, folder) : null,
    compiler_no_save: on && !config.get<boolean>("lintOnSave", true),
    compiler_on_change: on && config.get<boolean>("lintOnType", false),
    compiler_change_delay: delayMs(config, 1000),
    compiler_no_dependencies: on && !config.get<boolean>("resolveModules", true),
    compiler_no_compile_commands: on && config.get<boolean>("noCompileCommands", false),
    compiler_fypp: fypp ? programPath(config.get<string>("fypp.path", "fypp").trim() || "fypp", folder) : null,
    compiler_fypp_args: fypp
      ? [
          ...directories(config.get<string[]>("fypp.includes", []), folder).map((d) => `-I${d}`),
          ...Object.entries(config.get<Record<string, string>>("fypp.definitions", {})).map(([k, v]) => (v ? `-D${k}=${v}` : `-D${k}`)),
          ...config.get<string[]>("fypp.extraArgs", []).filter((a) => a !== "").map((a) => resolvePath(a, folder)),
        ]
      : [],
  };
}

/** A zfls option that holds a program's arguments, on the command line:
 * the arguments separated by spaces, or, when one has a space in it (a
 * folder under a path with a space), as a JSON list, which zfls keeps item
 * by item. The settings sent over LSP are lists. */
export function argOption(flag: string, args: string[]): string {
  const list = args.some((a) => /\s/.test(a)) || args[0]?.trimStart().startsWith("[");
  return `${flag}=${list ? JSON.stringify(args) : args.join(" ")}`;
}

/** `fortitudeArguments` as settings */
function fortitudeSettings(folder: vscode.WorkspaceFolder | undefined): ServerSettings {
  const config = vscode.workspace.getConfiguration("zfls.fortitude", folder?.uri);
  const on = config.get<boolean>("enabled", false);
  const exe = config.get<string>("path", "").trim();
  return {
    fortitude: on,
    fortitude_path: on && exe ? programPath(exe, folder) : null,
    fortitude_args: on ? config.get<string[]>("args", []).filter((a) => a !== "").map((a) => resolvePath(a, folder)) : [],
    fortitude_on_change: on && config.get<boolean>("lintOnType", false),
    fortitude_change_delay: delayMs(config, 500),
  };
}

/** `codeeArguments` as settings */
function codeeSettings(folder: vscode.WorkspaceFolder | undefined): ServerSettings {
  const config = vscode.workspace.getConfiguration("zfls.codee", folder?.uri);
  const on = config.get<boolean>("enabled", false);
  const exe = config.get<string>("path", "").trim();
  return {
    codee: on,
    codee_path: on && exe ? programPath(exe, folder) : null,
    codee_args: on ? config.get<string[]>("args", []).filter((a) => a !== "").map((a) => resolvePath(a, folder)) : [],
  };
}

/** `formattingArguments` as settings */
function formattingSettings(folder: vscode.WorkspaceFolder | undefined): ServerSettings {
  const out: ServerSettings = {};
  let any = false;
  let codee = false;
  for (const [languageId, key] of [
    ["FortranFreeForm", "formatter"],
    ["FortranFixedForm", "formatter_fixed"],
  ]) {
    const config = vscode.workspace.getConfiguration("zfls.formatting", { uri: folder?.uri, languageId });
    const formatter = config.get<string>("formatter", "Disabled");
    const on = FORMATTERS.includes(formatter);
    any ||= on;
    codee ||= formatter === "codee";
    out[key] = on ? formatter : "none";
    const extra = on ? config.get<string[]>(`${formatter}Args`, []).filter((a) => a !== "") : [];
    out[`${key}_args`] = extra.map((a) => resolvePath(a, folder));
  }
  const exe = formatterPath(folder, codee);
  out.formatter_path = any && exe ? resolvePath(exe, folder) : null;
  return out;
}

/** Whether a configuration change restarts the language server of `scope`
 * (a workspace folder, or none): a change of a setting a running server
 * cannot change, or any while `zfls.arguments` has options, which may set
 * what a setting does (on the command line, under what the server is sent) */
export function restartsServer(e: vscode.ConfigurationChangeEvent, scope: vscode.Uri | undefined): boolean {
  return (
    e.affectsConfiguration("zfls.path", scope) ||
    e.affectsConfiguration("zfls.arguments", scope) ||
    OPTIONS.some((o) => ("restart" in o || "rewatch" in o) && e.affectsConfiguration(`zfls.${o.setting}`, scope)) ||
    extraArguments(vscode.workspace.getConfiguration("zfls", scope)).length > 0
  );
}

/** Whether a configuration change concerns the language servers */
export function affectsServer(e: vscode.ConfigurationChangeEvent): boolean {
  return (
    e.affectsConfiguration("zfls.path") ||
    e.affectsConfiguration("zfls.arguments") ||
    e.affectsConfiguration("zfls.linter") ||
    e.affectsConfiguration("zfls.fortitude") ||
    e.affectsConfiguration("zfls.codee") ||
    e.affectsConfiguration("zfls.formatting") ||
    e.affectsConfiguration("files.associations") ||
    OPTIONS.some((o) => e.affectsConfiguration(`zfls.${o.setting}`))
  );
}
