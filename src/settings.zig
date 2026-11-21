//! Configuration options (port of `fortls.interface`): `Settings`, read
//! from configuration files and from the command line (settings/cli.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const json = @import("json.zig");
const json5 = @import("json5.zig");
/// The extensions of Fortran sources (also for build/generated.zig)
pub const suffixes = @import("suffixes.zig");

// The command line (settings/cli.zig)
const cli = @import("settings/cli.zig");
pub const opts = cli.opts;
pub const CliResult = cli.CliResult;
pub const parseArgs = cli.parseArgs;

/// Ordered list of unique strings (stand-in for Python `set[str]`)
pub const StrList = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *StrList, a: Allocator, s: []const u8) !void {
        for (self.items.items) |it| if (std.mem.eql(u8, it, s)) return;
        try self.items.append(a, s);
    }

    pub fn contains(self: *const StrList, s: []const u8) bool {
        for (self.items.items) |it| if (std.mem.eql(u8, it, s)) return true;
        return false;
    }

    pub fn slice(self: *const StrList) []const []const u8 {
        return self.items.items;
    }

    pub fn len(self: *const StrList) usize {
        return self.items.items.len;
    }
};

pub const PpDef = struct { name: []const u8, value: []const u8 };

/// The severity given to the diagnostics of a code: `off`, `error`,
/// `warning`, `information` or `hint`
pub const DiagLevel = struct { code: []const u8, level: []const u8 };

pub const Settings = struct {
    // General options
    config: []const u8 = ".fortlsrc",
    nthreads: i64 = 4,
    notify_init: bool = false,
    incremental_sync: bool = false,
    recursion_limit: i64 = 1000,
    sort_keywords: bool = false,
    disable_autoupdate: bool = false,
    preserve_keyword_order: bool = false,
    debug_log: bool = false,
    /// Do not keep the texts of the workspace's files in zfls's cache
    disable_index_cache: bool = false,
    // File parsing options
    source_dirs: StrList = .{},
    incl_suffixes: StrList = .{},
    excl_suffixes: StrList = .{},
    excl_paths: StrList = .{},
    /// Further markers that start a comment as `!` does, such as `;*`
    comment_markers: StrList = .{},
    /// Read OpenMP conditional compilation lines (`!$ x = 1`) as comments,
    /// as a build without OpenMP does, not as code
    disable_openmp_conditional: bool = false,
    /// How a fixed-form line with D or d in column 1 (a debug line) is
    /// read: `comment` (null: the default) or `code`
    d_lines: ?[]const u8 = null,
    // Autocomplete options
    autocomplete_no_prefix: bool = false,
    /// Do not offer names of modules that are not used yet (with the USE
    /// statement that brings them in)
    autocomplete_no_auto_use: bool = false,
    autocomplete_no_snippets: bool = false,
    autocomplete_name_only: bool = false,
    lowercase_intrinsics: bool = false,
    use_signature_help: bool = false,
    // Hover options
    variable_hover: bool = false,
    hover_signature: bool = false,
    hover_language: []const u8 = "fortran90",
    /// How the formulas of documentation comments (`\f$ x \f$`) reach the
    /// client: `keep`, `dollar` (`$x$`) or `plain` (in backticks)
    doc_math: []const u8 = "keep",
    /// Hover and go to definition use the implementation of a procedure
    /// declared in an interface (a separate module procedure's body in a
    /// submodule) rather than the interface
    prefer_implementation: bool = false,
    /// Keywords in hover in lowercase (`real, intent(in) :: x`)
    lowercase_hover: bool = false,
    /// Hover on a derived type, or a variable of one, does not list the
    /// type's components and bindings
    hover_no_type_components: bool = false,
    /// Plain `!` comments above or after a declaration that has no `!>`,
    /// `!<` or `!!` documentation are its documentation
    hover_plain_comments: bool = false,
    // Diagnostic options
    max_line_length: i64 = -1,
    max_comment_line_length: i64 = -1,
    /// The columns of code in a fixed-form line (gfortran's
    /// -ffixed-line-length-n); the rest is a comment. -1: no limit
    fixed_line_length: i64 = -1,
    disable_diagnostics: bool = false,
    /// The milliseconds a document's text stays unchanged before zfls's
    /// diagnostics of it are published again (0: with each change;
    /// negative: not before it is saved)
    diagnostics_change_delay: i64 = 300,
    /// Publish the diagnostics of every workspace file, not only of the
    /// open ones
    workspace_diagnostics: bool = false,
    /// Severities by diagnostic code (`off` to hide a code)
    diagnostic_severity: std.ArrayList(DiagLevel) = .empty,
    /// Glob patterns of modules USE may name that are not in the project
    external_modules: StrList = .{},
    /// Do not search the workspace's C files for the declarations of the
    /// C names of `BIND(C)` procedures in go to definition
    disable_bind_c_search: bool = false,
    /// The clangd that zfls starts and asks for the C declarations and calls
    /// of `BIND(C)` procedures, before its own search of the C files
    bind_c_clangd: ?[]const u8 = null,
    // Compiler diagnostics
    /// The compiler whose errors and warnings are published with zfls's
    /// diagnostics (gfortran, ifx, ifort, flang, nvfortran, nagfor or
    /// lfortran); null: none
    compiler_diagnostics: ?[]const u8 = null,
    /// The compiler executable, or the directory that holds it; null: the
    /// one on the PATH
    compiler_path: ?[]const u8 = null,
    /// The compiler's arguments; null: its defaults (gfortran's -Wall)
    compiler_args: ?StrList = null,
    /// The compiler, its executable and its arguments for fixed-form
    /// files; null: those of free form (`compiler_diagnostics`,
    /// `compiler_path`, `compiler_args`)
    compiler_diagnostics_fixed: ?[]const u8 = null,
    compiler_path_fixed: ?[]const u8 = null,
    compiler_args_fixed: ?StrList = null,
    /// Where the compiler's .mod files go, relative to the root; null: in
    /// zfls's cache directory
    compiler_mod_dir: ?[]const u8 = null,
    /// Further include directories, for the compiler only
    compiler_include_dirs: StrList = .{},
    /// Do not check a file when it is saved (only when it is opened)
    compiler_no_save: bool = false,
    /// Check a file while it is edited, its unsaved text, after
    /// `compiler_change_delay` milliseconds without a change
    compiler_on_change: bool = false,
    compiler_change_delay: i64 = 1000,
    /// Do not compile the workspace modules a file uses first
    compiler_no_dependencies: bool = false,
    /// Do not check a file with its command from compile_commands.json
    /// (when `compiler_args` is not set)
    compiler_no_compile_commands: bool = false,
    /// fypp, run on each file before the compiler checks it; null: none
    compiler_fypp: ?[]const u8 = null,
    /// fypp's further arguments (-I, -D, ...)
    compiler_fypp_args: StrList = .{},
    // Linters
    /// Lint files with fortitude
    fortitude: bool = false,
    /// fortitude's executable; null: `fortitude` on the PATH
    fortitude_path: ?[]const u8 = null,
    fortitude_args: StrList = .{},
    /// Lint a file while it is edited too, after `fortitude_change_delay`
    /// milliseconds without a change
    fortitude_on_change: bool = false,
    fortitude_change_delay: i64 = 500,
    /// Check files with Codee (`codee checks`)
    codee: bool = false,
    /// Codee's executable; null: `codee` on the PATH
    codee_path: ?[]const u8 = null,
    codee_args: StrList = .{},
    // Formatting
    /// The formatter of `textDocument/formatting` and `rangeFormatting`:
    /// findent, fprettify, codee, forformat or custom; null or `none`: none
    formatter: ?[]const u8 = null,
    /// The formatter executable, or the directory that holds it; null: the
    /// one on the PATH
    formatter_path: ?[]const u8 = null,
    /// The formatter's further arguments
    formatter_args: StrList = .{},
    /// The formatter of fixed-form files; null: `formatter`
    formatter_fixed: ?[]const u8 = null,
    /// The further arguments of `formatter_fixed`
    formatter_fixed_args: StrList = .{},
    // Preprocessor options
    /// null: use the default rule (uppercase extensions are preprocessed)
    pp_suffixes: ?StrList = null,
    include_dirs: StrList = .{},
    pp_defs: std.ArrayList(PpDef) = .empty,
    /// The compilation database to read include directories and definitions
    /// from: null to look for one, empty for none
    compile_commands: ?[]const u8 = null,
    /// read no compilation database (the name of fortls's option, its
    /// upstream PR #504)
    disable_compile_commands: bool = false,
    /// Read Intel's conditional compilation directives (`!DEC$ IF DEFINED
    /// (X)`, `!DIR$ IF (expr)`) as comments, all branches included
    disable_intel_directives: bool = false,
    // Symbols / code actions
    symbol_skip_mem: bool = false,
    enable_code_actions: bool = false,
    // Code lenses
    /// No lens with the number of references above modules, procedures
    /// and derived types
    code_lens_no_references: bool = false,
    /// No Run and Debug lenses above a program
    code_lens_no_run: bool = false,
    // Debug options
    debug_filepath: ?[]const u8 = null,
    debug_rootpath: ?[]const u8 = null,
    debug_parser: bool = false,
    debug_preproc: bool = false,
    debug_hover: bool = false,
    debug_rename: ?[]const u8 = null,
    debug_actions: bool = false,
    debug_symbols: bool = false,
    debug_completion: bool = false,
    debug_signature: bool = false,
    debug_definition: bool = false,
    debug_references: bool = false,
    debug_diagnostics: bool = false,
    debug_implementation: bool = false,
    debug_workspace_symbols: ?[]const u8 = null,
    debug_line: ?i64 = null,
    debug_char: ?i64 = null,
    debug_full_result: bool = false,

    pub fn setPpDef(self: *Settings, a: Allocator, name: []const u8, value: []const u8) !void {
        for (self.pp_defs.items) |*d| if (std.mem.eql(u8, d.name, name)) {
            d.value = value;
            return;
        };
        try self.pp_defs.append(a, .{ .name = name, .value = value });
    }

    pub fn isDebugMode(self: *const Settings) bool {
        return self.debug_diagnostics or self.debug_symbols or self.debug_completion or
            self.debug_signature or self.debug_definition or self.debug_hover or
            self.debug_implementation or self.debug_references or self.debug_rename != null or
            self.debug_actions or self.debug_rootpath != null or self.debug_workspace_symbols != null;
    }

    /// Whether `d_lines` reads debug lines as code
    pub fn dLinesCode(self: *const Settings) bool {
        return if (self.d_lines) |v| std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " "), "code") else false;
    }

    /// `fixed_line_length` when it limits fixed-form lines
    pub fn fixedColumns(self: *const Settings) ?usize {
        return if (self.fixed_line_length > 0) @intCast(self.fixed_line_length) else null;
    }

    /// Whether the compiler of fixed-form files (`compiler_diagnostics_fixed`,
    /// else `compiler_diagnostics`) counts a TAB-format line's TAB as the
    /// columns up to 6 for `fixed_line_length`, as gfortran and LLVM Flang
    /// do; ifx and ifort count it as one, as zfls does without a compiler
    pub fn fixedTabWide(self: *const Settings) bool {
        const name = self.compiler_diagnostics_fixed orelse self.compiler_diagnostics orelse return false;
        const n = std.mem.trim(u8, name, " ");
        return std.ascii.eqlIgnoreCase(n, "gfortran") or std.ascii.eqlIgnoreCase(n, "flang");
    }
};

/// Store a JSON `pp_defs` value (object, or list of names) into settings
pub fn applyPpDefs(a: Allocator, s: *Settings, v: json.Value) !void {
    s.pp_defs = .empty;
    switch (v) {
        .object => |o| for (o.keys(), o.values()) |k, x| {
            try s.setPpDef(a, k, try jsonScalarString(a, x));
        },
        .array => |arr| for (arr.items) |item| {
            try s.setPpDef(a, try jsonScalarString(a, item), "");
        },
        else => {},
    }
}

/// Store a JSON `diagnostic_severity` value, `{"code": "level"}`
pub fn applyDiagnosticSeverity(a: Allocator, s: *Settings, v: json.Value) !void {
    s.diagnostic_severity = .empty;
    if (v != .object) return;
    for (v.object.keys(), v.object.values()) |k, x| {
        try s.diagnostic_severity.append(a, .{ .code = k, .level = try jsonScalarString(a, x) });
    }
}

/// String form of a JSON scalar as Python's `str()` would render it
pub fn jsonScalarString(a: Allocator, v: json.Value) ![]const u8 {
    return switch (v) {
        .string => |x| x,
        .integer => |x| try a.print("{d}", .{x}),
        .float => |x| try a.print("{d}", .{x}),
        .bool => |x| if (x) "True" else "False",
        .null => "None",
        else => try json.stringify(a, v),
    };
}

fn jsonList(a: Allocator, v: json.Value) !StrList {
    var list: StrList = .{};
    switch (v) {
        .array => |arr| for (arr.items) |item| try list.add(a, try jsonScalarString(a, item)),
        .string => |x| {
            // Python's set("abc") iterates characters
            for (x, 0..) |_, k| try list.add(a, x[k .. k + 1]);
        },
        .object => |o| for (o.keys()) |k| try list.add(a, k),
        else => {},
    }
    return list;
}

fn jsonBool(v: ?json.Value, default: bool) bool {
    const x = v orelse return default;
    return switch (x) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .null => false,
        .string => |s| s.len > 0,
        else => default,
    };
}

/// The options that are arguments of another program: one string, split at
/// spaces, or a JSON list, on the command line, and a list or a string in a
/// configuration file
pub const arg_lists = .{ "compiler_args", "compiler_args_fixed", "compiler_fypp_args", "fortitude_args", "codee_args", "formatter_args", "formatter_fixed_args" };

pub fn isArgList(name: []const u8) bool {
    inline for (arg_lists) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Arguments: a string split at spaces, or a list, which keeps repeated
/// ones (-I a -I b); null for anything else
pub fn argList(a: Allocator, v: json.Value) !?StrList {
    var list: StrList = .{};
    switch (v) {
        .string => |x| {
            var words = std.mem.tokenizeAny(u8, x, " \t");
            while (words.next()) |w| try list.items.append(a, w);
        },
        .array => |arr| for (arr.items) |item| try list.items.append(a, try jsonScalarString(a, item)),
        else => return null,
    }
    return list;
}

fn jsonInt(v: ?json.Value, default: i64) i64 {
    const x = v orelse return default;
    return json.int(x) orelse default;
}

/// Port of `_load_config_file_dirs`, `_load_config_file_general` and
/// `_load_config_file_preproc`. The keys read here, with their `opts` help
/// and `Settings` defaults, make up editors/vscode/schemas/fortls.schema.json:
/// run `zig build generated` after changing them.
pub fn applyConfig(a: Allocator, s: *Settings, cfg: json.Value) !void {
    // Include and Exclude directories
    if (json.get(cfg, "excl_paths")) |v| s.excl_paths = try jsonList(a, v);
    if (json.get(cfg, "source_dirs")) |v| s.source_dirs = try jsonList(a, v);
    if (json.get(cfg, "incl_suffixes")) |v| s.incl_suffixes = try jsonList(a, v);
    if (json.get(cfg, "excl_suffixes")) |v| s.excl_suffixes = try jsonList(a, v);
    if (json.get(cfg, "comment_markers")) |v| s.comment_markers = try jsonList(a, v);
    s.disable_openmp_conditional = jsonBool(json.get(cfg, "disable_openmp_conditional"), s.disable_openmp_conditional);
    if (json.get(cfg, "d_lines")) |v| s.d_lines = json.str(v);
    // General options
    s.nthreads = jsonInt(json.get(cfg, "nthreads"), s.nthreads);
    s.notify_init = jsonBool(json.get(cfg, "notify_init"), s.notify_init);
    s.incremental_sync = jsonBool(json.get(cfg, "incremental_sync"), s.incremental_sync);
    s.recursion_limit = jsonInt(json.get(cfg, "recursion_limit"), s.recursion_limit);
    s.sort_keywords = jsonBool(json.get(cfg, "sort_keywords"), s.sort_keywords);
    s.disable_autoupdate = jsonBool(json.get(cfg, "disable_autoupdate"), s.disable_autoupdate);
    s.disable_index_cache = jsonBool(json.get(cfg, "disable_index_cache"), s.disable_index_cache);
    // Autocomplete options
    s.autocomplete_no_prefix = jsonBool(json.get(cfg, "autocomplete_no_prefix"), s.autocomplete_no_prefix);
    s.autocomplete_no_auto_use = jsonBool(json.get(cfg, "autocomplete_no_auto_use"), s.autocomplete_no_auto_use);
    s.autocomplete_no_snippets = jsonBool(json.get(cfg, "autocomplete_no_snippets"), s.autocomplete_no_snippets);
    s.autocomplete_name_only = jsonBool(json.get(cfg, "autocomplete_name_only"), s.autocomplete_name_only);
    s.lowercase_intrinsics = jsonBool(json.get(cfg, "lowercase_intrinsics"), s.lowercase_intrinsics);
    s.use_signature_help = jsonBool(json.get(cfg, "use_signature_help"), s.use_signature_help);
    // Hover options
    s.hover_signature = jsonBool(json.get(cfg, "hover_signature"), s.hover_signature);
    if (json.str(json.get(cfg, "hover_language"))) |hl| s.hover_language = hl;
    if (json.str(json.get(cfg, "doc_math"))) |dm| s.doc_math = dm;
    s.prefer_implementation = jsonBool(json.get(cfg, "prefer_implementation"), s.prefer_implementation);
    s.lowercase_hover = jsonBool(json.get(cfg, "lowercase_hover"), s.lowercase_hover);
    s.hover_no_type_components = jsonBool(json.get(cfg, "hover_no_type_components"), s.hover_no_type_components);
    s.hover_plain_comments = jsonBool(json.get(cfg, "hover_plain_comments"), s.hover_plain_comments);
    // Diagnostic options
    s.max_line_length = jsonInt(json.get(cfg, "max_line_length"), s.max_line_length);
    s.max_comment_line_length = jsonInt(json.get(cfg, "max_comment_line_length"), s.max_comment_line_length);
    s.fixed_line_length = jsonInt(json.get(cfg, "fixed_line_length"), s.fixed_line_length);
    s.disable_diagnostics = jsonBool(json.get(cfg, "disable_diagnostics"), s.disable_diagnostics);
    s.diagnostics_change_delay = jsonInt(json.get(cfg, "diagnostics_change_delay"), s.diagnostics_change_delay);
    s.workspace_diagnostics = jsonBool(json.get(cfg, "workspace_diagnostics"), s.workspace_diagnostics);
    if (json.get(cfg, "diagnostic_severity")) |v| try applyDiagnosticSeverity(a, s, v);
    if (json.get(cfg, "external_modules")) |v| s.external_modules = try jsonList(a, v);
    // Compiler diagnostics
    if (json.get(cfg, "compiler_diagnostics")) |v| s.compiler_diagnostics = json.str(v);
    if (json.get(cfg, "compiler_path")) |v| s.compiler_path = json.str(v);
    if (json.get(cfg, "compiler_args")) |v| s.compiler_args = if (v == .null) null else try argList(a, v) orelse s.compiler_args;
    if (json.get(cfg, "compiler_diagnostics_fixed")) |v| s.compiler_diagnostics_fixed = json.str(v);
    if (json.get(cfg, "compiler_path_fixed")) |v| s.compiler_path_fixed = json.str(v);
    if (json.get(cfg, "compiler_args_fixed")) |v| s.compiler_args_fixed = if (v == .null) null else try argList(a, v) orelse s.compiler_args_fixed;
    if (json.get(cfg, "compiler_mod_dir")) |v| s.compiler_mod_dir = json.str(v);
    if (json.get(cfg, "compiler_include_dirs")) |v| s.compiler_include_dirs = try jsonList(a, v);
    s.compiler_no_save = jsonBool(json.get(cfg, "compiler_no_save"), s.compiler_no_save);
    s.compiler_on_change = jsonBool(json.get(cfg, "compiler_on_change"), s.compiler_on_change);
    s.compiler_change_delay = jsonInt(json.get(cfg, "compiler_change_delay"), s.compiler_change_delay);
    s.compiler_no_dependencies = jsonBool(json.get(cfg, "compiler_no_dependencies"), s.compiler_no_dependencies);
    s.compiler_no_compile_commands = jsonBool(json.get(cfg, "compiler_no_compile_commands"), s.compiler_no_compile_commands);
    if (json.get(cfg, "compiler_fypp")) |v| s.compiler_fypp = json.str(v);
    if (json.get(cfg, "compiler_fypp_args")) |v| if (try argList(a, v)) |l| {
        s.compiler_fypp_args = l;
    };
    // Linters
    s.fortitude = jsonBool(json.get(cfg, "fortitude"), s.fortitude);
    if (json.get(cfg, "fortitude_path")) |v| s.fortitude_path = json.str(v);
    if (json.get(cfg, "fortitude_args")) |v| if (try argList(a, v)) |l| {
        s.fortitude_args = l;
    };
    s.fortitude_on_change = jsonBool(json.get(cfg, "fortitude_on_change"), s.fortitude_on_change);
    s.fortitude_change_delay = jsonInt(json.get(cfg, "fortitude_change_delay"), s.fortitude_change_delay);
    s.codee = jsonBool(json.get(cfg, "codee"), s.codee);
    if (json.get(cfg, "codee_path")) |v| s.codee_path = json.str(v);
    if (json.get(cfg, "codee_args")) |v| if (try argList(a, v)) |l| {
        s.codee_args = l;
    };
    // Formatting
    if (json.get(cfg, "formatter")) |v| s.formatter = json.str(v);
    if (json.get(cfg, "formatter_path")) |v| s.formatter_path = json.str(v);
    if (json.get(cfg, "formatter_args")) |v| if (try argList(a, v)) |l| {
        s.formatter_args = l;
    };
    if (json.get(cfg, "formatter_fixed")) |v| s.formatter_fixed = json.str(v);
    if (json.get(cfg, "formatter_fixed_args")) |v| if (try argList(a, v)) |l| {
        s.formatter_fixed_args = l;
    };
    // Symbols options
    s.symbol_skip_mem = jsonBool(json.get(cfg, "symbol_skip_mem"), s.symbol_skip_mem);
    s.disable_bind_c_search = jsonBool(json.get(cfg, "disable_bind_c_search"), s.disable_bind_c_search);
    if (json.get(cfg, "bind_c_clangd")) |v| s.bind_c_clangd = json.str(v);
    // Code Actions options
    s.enable_code_actions = jsonBool(json.get(cfg, "enable_code_actions"), s.enable_code_actions);
    // Code lens options
    s.code_lens_no_references = jsonBool(json.get(cfg, "code_lens_no_references"), s.code_lens_no_references);
    s.code_lens_no_run = jsonBool(json.get(cfg, "code_lens_no_run"), s.code_lens_no_run);
    // Preprocessor options
    // like every other option, a value in the file replaces the one from the
    // command line, and no value leaves it alone (upstream #536)
    if (json.get(cfg, "pp_suffixes")) |v| s.pp_suffixes = if (v == .null) null else try jsonList(a, v);
    if (json.get(cfg, "pp_defs")) |v| try applyPpDefs(a, s, v);
    if (json.get(cfg, "include_dirs")) |v| s.include_dirs = try jsonList(a, v);
    if (json.get(cfg, "compile_commands")) |v| s.compile_commands = json.str(v);
    s.disable_compile_commands = jsonBool(json.get(cfg, "disable_compile_commands"), s.disable_compile_commands);
    s.disable_intel_directives = jsonBool(json.get(cfg, "disable_intel_directives"), s.disable_intel_directives);
    // Debug options
    if (jsonBool(json.get(cfg, "debug_log"), s.debug_log) and !s.debug_log) s.debug_log = true;
}

/// A copy of `s` whose lists are its own, so that adding to them leaves
/// `s` alone. The strings are shared: settings never change one in place.
pub fn clone(a: Allocator, s: Settings) Allocator.Error!Settings {
    var out = s;
    inline for (@typeInfo(Settings).@"struct".field_names) |name| {
        const v = @field(s, name);
        switch (@FieldType(Settings, name)) {
            StrList => @field(out, name) = .{ .items = try v.items.clone(a) },
            ?StrList => if (v) |l| {
                @field(out, name) = StrList{ .items = try l.items.clone(a) };
            },
            std.ArrayList(PpDef), std.ArrayList(DiagLevel) => @field(out, name) = try v.clone(a),
            else => {},
        }
    }
    return out;
}

/// The names of the configuration file looked for in the root, after the
/// one `config` names (`-c`), the first found being read
pub const default_config_files = [_][]const u8{ ".fortlsrc", ".fortls.json", ".fortls" };

pub fn configFileNames(config: []const u8) [1 + default_config_files.len][]const u8 {
    return .{config} ++ default_config_files;
}

/// The options as a JSON object, under the configuration file's names,
/// for the log; without the debug requests' options
pub fn toJson(a: Allocator, s: *const Settings) Allocator.Error!json.Value {
    var obj: json.ObjectMap = .empty;
    inline for (@typeInfo(Settings).@"struct".field_names) |name| {
        if (comptime !std.mem.startsWith(u8, name, "debug_") or std.mem.eql(u8, name, "debug_log")) {
            const v = @field(s, name);
            const out: json.Value = switch (@FieldType(Settings, name)) {
                StrList => try json.from(a, v.slice()),
                ?StrList => if (v) |l| try json.from(a, l.slice()) else .null,
                std.ArrayList(PpDef), std.ArrayList(DiagLevel) => blk: {
                    var m: json.ObjectMap = .empty;
                    for (v.items) |x| {
                        const kv = if (@TypeOf(x) == PpDef) .{ x.name, x.value } else .{ x.code, x.level };
                        try m.put(a, kv[0], .{ .string = kv[1] });
                    }
                    break :blk .{ .object = m };
                },
                else => try json.from(a, v),
            };
            try obj.put(a, name, out);
        }
    }
    return .{ .object = obj };
}

/// Whether option `name` has the same value in `x` and `y`
pub fn sameValue(x: *const Settings, y: *const Settings, comptime name: []const u8) bool {
    return eqlValue(@FieldType(Settings, name), @field(x, name), @field(y, name));
}

fn eqlValue(comptime T: type, x: T, y: T) bool {
    switch (@typeInfo(T)) {
        .optional => |o| return if (x) |xv| (if (y) |yv| eqlValue(o.child, xv, yv) else false) else y == null,
        .bool, .int => return x == y,
        .pointer => |p| {
            if (p.child == u8) return std.mem.eql(u8, x, y);
            if (x.len != y.len) return false;
            for (x, y) |xi, yi| if (!eqlValue(p.child, xi, yi)) return false;
            return true;
        },
        .@"struct" => |st| {
            if (T == StrList) return eqlValue([]const []const u8, x.slice(), y.slice());
            // an ArrayList: its items, whatever its capacity
            if (@hasField(T, "capacity")) return eqlValue(@FieldType(T, "items"), x.items, y.items);
            inline for (st.field_names) |name| if (!eqlValue(@FieldType(T, name), @field(x, name), @field(y, name))) return false;
            return true;
        },
        else => @compileError("no comparison of " ++ @typeName(T)),
    }
}

/// Format a JSON5 parse error like the Python json5 library
pub fn json5ErrorMessage(a: Allocator, src: []const u8, pos: usize) ![]const u8 {
    var line: usize = 1;
    var col: usize = 1;
    for (src[0..@min(pos, src.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    if (pos >= src.len) return a.print("<string>:{d} Unexpected end of input at column {d}", .{ line, col });
    return a.print("<string>:{d} Unexpected \"{c}\" at column {d}", .{ line, src[pos], col });
}

test "a config file only replaces the preprocessor options it sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Settings = .{};
    try s.setPpDef(a, "FROM_CLI", "1");
    s.pp_suffixes = .{};
    try s.pp_suffixes.?.add(a, ".inc");
    try applyConfig(a, &s, try json5.parse(a, "{}"));
    try std.testing.expectEqual(@as(usize, 1), s.pp_defs.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.pp_suffixes.?.len());
    try applyConfig(a, &s, try json5.parse(a, "{\"pp_defs\": {\"FROM_FILE\": \"2\"}, \"pp_suffixes\": [\".a\", \".b\"]}"));
    try std.testing.expectEqualStrings("FROM_FILE", s.pp_defs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), s.pp_defs.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.pp_suffixes.?.len());
}

test "a clone's lists are its own, and compare equal until changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Settings = .{};
    try s.source_dirs.add(a, "src");
    try s.setPpDef(a, "A", "1");
    var c = try clone(a, s);
    inline for (@typeInfo(Settings).@"struct".field_names) |name| try std.testing.expect(sameValue(&s, &c, name));
    try c.source_dirs.add(a, "lib");
    try c.setPpDef(a, "A", "2");
    try std.testing.expectEqual(@as(usize, 1), s.source_dirs.len());
    try std.testing.expectEqualStrings("1", s.pp_defs.items[0].value);
    try std.testing.expect(!sameValue(&s, &c, "source_dirs"));
    try std.testing.expect(!sameValue(&s, &c, "pp_defs"));
    c.compiler_args = .{};
    try std.testing.expect(!sameValue(&s, &c, "compiler_args"));
}

test "formatter arguments: a string split at spaces, or a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseArgs(a, &.{ "--formatter", "findent", "--formatter_args=-i4  -r1", "--formatter_fixed_args", "" }, "0.1.0");
    var s = r.run;
    try std.testing.expectEqualStrings("findent", s.formatter.?);
    try std.testing.expectEqual(@as(usize, 2), s.formatter_args.len());
    try std.testing.expectEqualStrings("-r1", s.formatter_args.slice()[1]);
    try std.testing.expectEqual(@as(usize, 0), s.formatter_fixed_args.len());
    try applyConfig(a, &s, try json5.parse(a, "{\"formatter\": \"fprettify\", \"formatter_args\": [\"-i\", \"4\", \"-i\", \"4\"], \"formatter_fixed_args\": \"-ifixed -i2\"}"));
    try std.testing.expectEqualStrings("fprettify", s.formatter.?);
    try std.testing.expectEqual(@as(usize, 4), s.formatter_args.len());
    try std.testing.expectEqual(@as(usize, 2), s.formatter_fixed_args.len());
}

test "the options as JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Settings = .{ .debug_filepath = "x.f90" };
    try s.setPpDef(a, "A", "1");
    try s.include_dirs.add(a, "inc");
    const text = try json.stringify(a, try toJson(a, &s));
    try std.testing.expect(std.mem.find(u8, text, "\"pp_defs\":{\"A\":\"1\"}") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"include_dirs\":[\"inc\"]") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"pp_suffixes\":null") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"debug_log\":false") != null);
    try std.testing.expect(std.mem.find(u8, text, "debug_filepath") == null);
}
