//! Command line interface and configuration options (port of
//! `fortls.interface`). Long options may be abbreviated to any unique prefix,
//! like Python's argparse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const json = @import("json.zig");
const json5 = @import("json5.zig");

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
    /// Hover and go to definition use the implementation of a procedure
    /// declared in an interface (a separate module procedure's body in a
    /// submodule) rather than the interface
    prefer_implementation: bool = false,
    /// Keywords in hover in lowercase (`real, intent(in) :: x`)
    lowercase_hover: bool = false,
    // Diagnostic options
    max_line_length: i64 = -1,
    max_comment_line_length: i64 = -1,
    /// The columns of code in a fixed-form line (gfortran's
    /// -ffixed-line-length-n); the rest is a comment. -1: no limit
    fixed_line_length: i64 = -1,
    disable_diagnostics: bool = false,
    /// Publish the diagnostics of every workspace file, not only of the
    /// open ones
    workspace_diagnostics: bool = false,
    /// Severities by diagnostic code (`off` to hide a code)
    diagnostic_severity: std.ArrayList(DiagLevel) = .empty,
    /// Glob patterns of modules USE may name that are not in the project
    external_modules: StrList = .{},
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
    /// Where the compiler's .mod files go, relative to the root; null: in
    /// zfls's cache directory
    compiler_mod_dir: ?[]const u8 = null,
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
    // Symbols / code actions
    symbol_skip_mem: bool = false,
    enable_code_actions: bool = false,
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
};

const Kind = enum { flag, int, string, list, json, help, debug_help, version };

const Opt = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    kind: Kind,
    metavar: []const u8 = "",
    help: []const u8,
    debug: bool = false,
    group: []const u8 = "",
};

const opts = [_]Opt{
    .{ .long = "help", .short = "-h", .kind = .help, .help = "show this help message and exit" },
    .{ .long = "version", .short = "-v", .kind = .version, .help = "Print server version number and exit" },
    .{ .long = "config", .short = "-c", .kind = .string, .metavar = "CONFIG", .help = "Configuration options file (default file name: .fortlsrc, other default supported names: .fortls.json, .fortls)" },
    .{ .long = "nthreads", .short = "-n", .kind = .int, .metavar = "INTEGER", .help = "Number of threads to use during workspace initialization (default: 4)" },
    .{ .long = "notify_init", .kind = .flag, .help = "Send notification message when workspace initialization is complete" },
    .{ .long = "incremental_sync", .kind = .flag, .help = "Use incremental document synchronization (beta)" },
    .{ .long = "recursion_limit", .kind = .int, .metavar = "INTEGER", .help = "Set the maximum recursion depth for the parser (default: 1000)" },
    .{ .long = "sort_keywords", .kind = .flag, .help = "Display variable keywords information, function/subroutine definitions, etc. in a consistent (sorted) manner default: no sorting, display code as is)" },
    .{ .long = "disable_autoupdate", .kind = .flag, .help = "Accepted for compatibility with fortls and ignored: zfls does not update itself." },
    .{ .long = "preserve_keyword_order", .kind = .flag, .help = "DEPRECATED, this is now the default. To sort use sort_keywords" },
    .{ .long = "debug_log", .kind = .flag, .help = "Generate debug log in project root folder" },
    .{ .long = "disable_index_cache", .kind = .flag, .help = "Do not keep the texts of the workspace's files in one file of zfls's cache, from which a start reads those that have not changed instead of reading each file" },
    .{ .long = "debug_help", .kind = .debug_help, .help = "Display options for debugging zfls" },

    .{ .long = "source_dirs", .kind = .list, .metavar = "[DIRS ...]", .help = "Folders containing source files (default: set())", .group = "Sources file parsing options" },
    .{ .long = "incl_suffixes", .kind = .list, .metavar = "[SUFFIXES ...]", .help = "Consider additional file extensions to the default (default: .F, .F77, .F90, .F95, .F03, .F08, .FOR, .FPP, .CUF (lower & upper casing))", .group = "Sources file parsing options" },
    .{ .long = "excl_suffixes", .kind = .list, .metavar = "[SUFFIXES ...]", .help = "Source file extensions to be excluded (default: set())", .group = "Sources file parsing options" },
    .{ .long = "excl_paths", .kind = .list, .metavar = "[DIRS ...]", .help = "Folders to exclude from parsing", .group = "Sources file parsing options" },

    .{ .long = "autocomplete_no_prefix", .kind = .flag, .help = "Do not filter autocomplete results by variable prefix", .group = "Autocomplete options" },
    .{ .long = "autocomplete_no_auto_use", .kind = .flag, .help = "Do not offer the public names of modules that are not used yet (completing one adds its USE statement)", .group = "Autocomplete options" },
    .{ .long = "autocomplete_no_snippets", .kind = .flag, .help = "Do not use snippets with place holders in autocomplete results", .group = "Autocomplete options" },
    .{ .long = "autocomplete_name_only", .kind = .flag, .help = "Complete only the name of procedures and not the parameters", .group = "Autocomplete options" },
    .{ .long = "lowercase_intrinsics", .kind = .flag, .help = "Use lowercase for intrinsics and keywords in autocomplete requests", .group = "Autocomplete options" },
    .{ .long = "use_signature_help", .kind = .flag, .help = "Use signature help instead of subroutine/function snippets. This effectively sets --autocomplete_no_snippets", .group = "Autocomplete options" },

    .{ .long = "variable_hover", .kind = .flag, .help = "DEPRECATED: This option is always on. Show hover information for variables", .group = "Hover options" },
    .{ .long = "hover_signature", .kind = .flag, .help = "Show signature information in hover for arguments ", .group = "Hover options" },
    .{ .long = "hover_language", .kind = .string, .metavar = "HOVER_LANGUAGE", .help = "Language used for responses to hover requests a VSCode language id (default: fortran90)", .group = "Hover options" },
    .{ .long = "lowercase_hover", .kind = .flag, .help = "Show the keywords of hover in lowercase (real, intent(in) :: x)", .group = "Hover options" },
    .{ .long = "prefer_implementation", .kind = .flag, .help = "Hover and go to definition use the implementation of a procedure declared in an interface (e.g. a separate module procedure in a submodule) instead of the interface", .group = "Hover options" },

    .{ .long = "max_line_length", .kind = .int, .metavar = "INTEGER", .help = "Maximum line length (default: -1)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "max_comment_line_length", .kind = .int, .metavar = "INTEGER", .help = "Maximum comment line length (default: -1)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "fixed_line_length", .kind = .int, .metavar = "INTEGER", .help = "Columns of code in a fixed-form line, as gfortran's -ffixed-line-length-n (72, 80, 132): the rest is highlighted as a comment and is not read for names (default: -1, no limit)", .group = "Sources file parsing options" },
    .{ .long = "disable_diagnostics", .kind = .flag, .help = "Disable diagnostics", .group = "Diagnostic options (error swigles)" },
    .{ .long = "workspace_diagnostics", .kind = .flag, .help = "Publish the diagnostics of every file of the workspace, not only of the open ones (after initialization, and again when files change)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "diagnostic_severity", .kind = .json, .metavar = "JSON", .help = "Severity of the diagnostics of each code, e.g. {\"masks-parent\": \"off\"}: off, error, warning, information or hint", .group = "Diagnostic options (error swigles)" },
    .{ .long = "external_modules", .kind = .list, .metavar = "[MODULES ...]", .help = "Modules from outside the project (glob patterns, e.g. mpi petsc*) that USE statements name without a diagnostic", .group = "Diagnostic options (error swigles)" },

    .{ .long = "compiler_diagnostics", .kind = .string, .metavar = "COMPILER", .help = "Check each file with a compiler when it is opened and saved, and publish its errors and warnings with zfls's diagnostics: gfortran, ifx, ifort, flang, nvfortran, nagfor or lfortran (default: none). The modules a file uses are compiled first", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_path", .kind = .string, .metavar = "PATH", .help = "The compiler executable, or the directory that holds it (default: the one on the PATH)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_args", .kind = .string, .metavar = "ARGS", .help = "The compiler's arguments, separated by spaces on the command line and a list in a configuration file (default: the compiler's warnings, e.g. -Wall for gfortran). Include directories and preprocessor definitions are added", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_mod_dir", .kind = .string, .metavar = "DIR", .help = "Where the compiler writes .mod files, relative to the root (default: a directory in zfls's cache)", .group = "Compiler diagnostics options" },

    .{ .long = "pp_suffixes", .kind = .list, .metavar = "[SUFFIXES ...]", .help = "File extensions to be parsed ONLY for preprocessor commands (default: all uppercase source file suffixes)", .group = "Preprocessor options" },
    .{ .long = "include_dirs", .kind = .list, .metavar = "[DIRS ...]", .help = "Folders containing preprocessor files with extensions PP_SUFFIXES.", .group = "Preprocessor options" },
    .{ .long = "compile_commands", .kind = .string, .metavar = "PATH", .help = "compile_commands.json (or its directory) whose Fortran entries add include directories and preprocessor definitions; empty for none (default: compile_commands.json in the root, root/build or root/builddir)", .group = "Preprocessor options" },
    .{ .long = "disable_compile_commands", .kind = .flag, .help = "Do not read a compile_commands.json", .group = "Preprocessor options" },
    .{ .long = "pp_defs", .kind = .json, .metavar = "JSON", .help = "A dictionary with additional preprocessor definitions. Preprocessor definitions are normally included via INCLUDE_DIRS", .group = "Preprocessor options" },

    .{ .long = "symbol_skip_mem", .kind = .flag, .help = "Do not include type members in document symbol results", .group = "Symbols options" },
    .{ .long = "enable_code_actions", .kind = .flag, .help = "Enable experimental code actions (default: false)", .group = "CodeActions options [limited]" },

    .{ .long = "debug_filepath", .kind = .string, .metavar = "DEBUG_FILEPATH", .help = "File path for language server tests", .debug = true },
    .{ .long = "debug_rootpath", .kind = .string, .metavar = "DEBUG_ROOTPATH", .help = "Root path for language server tests", .debug = true },
    .{ .long = "debug_parser", .kind = .flag, .help = "Test source code parser on specified file", .debug = true },
    .{ .long = "debug_preproc", .kind = .flag, .help = "Test source code preprocessor parser on specified file", .debug = true },
    .{ .long = "debug_hover", .kind = .flag, .help = "Test `textDocument/hover` request for specified file and position", .debug = true },
    .{ .long = "debug_rename", .kind = .string, .metavar = "RENAME_STRING", .help = "Test `textDocument/rename` request for specified file and position", .debug = true },
    .{ .long = "debug_actions", .kind = .flag, .help = "Test `textDocument/codeAction` request for specified file and position", .debug = true },
    .{ .long = "debug_symbols", .kind = .flag, .help = "Test `textDocument/documentSymbol` request for specified file", .debug = true },
    .{ .long = "debug_completion", .kind = .flag, .help = "Test `textDocument/completion` request for specified file and position", .debug = true },
    .{ .long = "debug_signature", .kind = .flag, .help = "Test `textDocument/signatureHelp` request for specified file and position", .debug = true },
    .{ .long = "debug_definition", .kind = .flag, .help = "Test `textDocument/definition` request for specified file and position", .debug = true },
    .{ .long = "debug_references", .kind = .flag, .help = "Test `textDocument/references` request for specified file and position", .debug = true },
    .{ .long = "debug_diagnostics", .kind = .flag, .help = "Test diagnostic notifications for specified file", .debug = true },
    .{ .long = "debug_implementation", .kind = .flag, .help = "Test `textDocument/implementation` request for specified file and position", .debug = true },
    .{ .long = "debug_workspace_symbols", .kind = .string, .metavar = "QUERY_STRING", .help = "Test `workspace/symbol` request", .debug = true },
    .{ .long = "debug_line", .kind = .int, .metavar = "INTEGER", .help = "Line position for language server tests (1-indexed)", .debug = true },
    .{ .long = "debug_char", .kind = .int, .metavar = "INTEGER", .help = "Character position for language server tests (1-indexed)", .debug = true },
    .{ .long = "debug_full_result", .kind = .flag, .help = "Print full result object instead of condensed version", .debug = true },
};

pub const CliResult = union(enum) {
    run: Settings,
    /// Text to print to stdout before exiting with code 0
    exit_ok: []const u8,
    /// Text to print to stderr before exiting with code 2
    exit_err: []const u8,
};

const usage = "usage: zfls [options] [debug options]\n";

fn helpText(a: Allocator, prog_version: []const u8, show_debug: bool) ![]const u8 {
    _ = prog_version;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, usage);
    try out.appendSlice(a, "\nfortls - Fortran Language Server\n");
    var group: []const u8 = "";
    try out.appendSlice(a, "\noptions:\n");
    for (opts) |o| {
        if (o.debug and !show_debug) continue;
        const g = if (o.debug) "DEBUG" else o.group;
        if (!std.mem.eql(u8, g, group)) {
            group = g;
            try out.print(a, "\n{s}:\n", .{g});
            if (o.debug) try out.appendSlice(a, "  Options for debugging language server\n\n");
        }
        var left: std.ArrayList(u8) = .empty;
        try left.appendSlice(a, "  ");
        if (o.short) |s| {
            try left.appendSlice(a, s);
            if (o.metavar.len > 0) try left.print(a, " {s}", .{o.metavar});
            try left.appendSlice(a, ", ");
        }
        try left.print(a, "--{s}", .{o.long});
        if (o.metavar.len > 0) try left.print(a, " {s}", .{o.metavar});
        try out.appendSlice(a, left.items);
        if (left.items.len < 60) {
            try out.appendNTimes(a, ' ', 62 - left.items.len);
        } else {
            try out.append(a, '\n');
            try out.appendNTimes(a, ' ', 62);
        }
        try out.appendSlice(a, o.help);
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "\nAll options starting with '--' can also be set in a configuration file, by " ++
        "default named '.fortlsrc', '.fortls.json' or '.fortls' (other names/paths can specified " ++
        "via -c or --config). For more details see our documentation: " ++
        "https://fortls.fortran-lang.org/options.html#available-options\n");
    return out.items;
}

fn findOpt(arg: []const u8) union(enum) { found: *const Opt, ambiguous, none } {
    if (std.mem.startsWith(u8, arg, "--")) {
        const name = arg[2..];
        for (&opts) |*o| if (std.mem.eql(u8, o.long, name)) return .{ .found = o };
        var match: ?*const Opt = null;
        for (&opts) |*o| if (std.mem.startsWith(u8, o.long, name)) {
            if (match != null) return .ambiguous;
            match = o;
        };
        if (match) |m| return .{ .found = m };
        return .none;
    }
    for (&opts) |*o| if (o.short) |s| if (std.mem.eql(u8, s, arg)) return .{ .found = o };
    return .none;
}

fn setValue(a: Allocator, s: *Settings, comptime field: []const u8, v: anytype) void {
    _ = a;
    @field(s, field) = v;
}

/// Parse command line arguments (excluding the program name)
pub fn parseArgs(a: Allocator, args: []const []const u8, version: []const u8) !CliResult {
    var s: Settings = .{};
    var any_debug_arg = false;
    for (args) |arg| if (std.mem.indexOf(u8, arg, "--debug_") != null) {
        any_debug_arg = true;
    };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        var arg = args[i];
        var inline_val: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                inline_val = arg[eq + 1 ..];
                arg = arg[0..eq];
            }
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 2) {
            // short option with attached value, e.g. -n1
            inline_val = arg[2..];
            arg = arg[0..2];
        }
        const res = findOpt(arg);
        const o = switch (res) {
            .found => |o| o,
            .ambiguous => return .{ .exit_err = try std.fmt.allocPrint(a, "{s}zfls: error: ambiguous option: {s}\n", .{ usage, arg }) },
            .none => return .{ .exit_err = try std.fmt.allocPrint(a, "{s}zfls: error: unrecognized arguments: {s}\n", .{ usage, args[i] }) },
        };
        switch (o.kind) {
            .help => return .{ .exit_ok = try helpText(a, version, any_debug_arg) },
            .debug_help => return .{ .exit_ok = try helpText(a, version, true) },
            .version => return .{ .exit_ok = try std.fmt.allocPrint(a, "{s}\n", .{version}) },
            .flag => {
                if (inline_val != null) return .{ .exit_err = try std.fmt.allocPrint(a, "{s}zfls: error: argument --{s}: ignored explicit argument '{s}'\n", .{ usage, o.long, inline_val.? }) };
                inline for (@typeInfo(Settings).@"struct".field_names) |fname| {
                    if (std.mem.eql(u8, fname, o.long)) {
                        if (@TypeOf(@field(s, fname)) == bool) @field(s, fname) = true;
                    }
                }
            },
            .int, .string, .json => {
                const val = inline_val orelse blk: {
                    if (i + 1 >= args.len) return .{ .exit_err = try std.fmt.allocPrint(a, "{s}zfls: error: argument --{s}: expected one argument\n", .{ usage, o.long }) };
                    i += 1;
                    break :blk args[i];
                };
                if (o.kind == .json) {
                    const v = json5.parse(a, val) catch {
                        return .{ .exit_err = try std.fmt.allocPrint(a, "{s}zfls: error: argument --{s}: invalid loads value: '{s}'\n", .{ usage, o.long, val }) };
                    };
                    if (std.mem.eql(u8, o.long, "pp_defs")) try applyPpDefs(a, &s, v);
                    if (std.mem.eql(u8, o.long, "diagnostic_severity")) try applyDiagnosticSeverity(a, &s, v);
                    continue;
                }
                if (std.mem.eql(u8, o.long, "compiler_args")) {
                    var list: StrList = .{};
                    var words = std.mem.tokenizeAny(u8, val, " \t");
                    while (words.next()) |w| try list.items.append(a, w);
                    s.compiler_args = list;
                    continue;
                }
                var handled = false;
                inline for (@typeInfo(Settings).@"struct".field_names) |fname| {
                    if (!handled and std.mem.eql(u8, fname, o.long)) {
                        const FT = @TypeOf(@field(s, fname));
                        if (FT == i64 or FT == ?i64) {
                            @field(s, fname) = std.fmt.parseInt(i64, str.strip(val), 10) catch {
                                return .{ .exit_err = try std.fmt.allocPrint(a, "{s}zfls: error: argument --{s}: invalid int value: '{s}'\n", .{ usage, o.long, val }) };
                            };
                            handled = true;
                        } else if (FT == []const u8 or FT == ?[]const u8) {
                            @field(s, fname) = val;
                            handled = true;
                        }
                    }
                }
            },
            .list => {
                var list: StrList = .{};
                if (inline_val) |v| try list.add(a, v);
                while (i + 1 < args.len and !(std.mem.startsWith(u8, args[i + 1], "-") and args[i + 1].len > 1)) {
                    i += 1;
                    try list.add(a, args[i]);
                }
                if (std.mem.eql(u8, o.long, "source_dirs")) s.source_dirs = list;
                if (std.mem.eql(u8, o.long, "incl_suffixes")) s.incl_suffixes = list;
                if (std.mem.eql(u8, o.long, "excl_suffixes")) s.excl_suffixes = list;
                if (std.mem.eql(u8, o.long, "excl_paths")) s.excl_paths = list;
                if (std.mem.eql(u8, o.long, "include_dirs")) s.include_dirs = list;
                if (std.mem.eql(u8, o.long, "pp_suffixes")) s.pp_suffixes = list;
                if (std.mem.eql(u8, o.long, "external_modules")) s.external_modules = list;
            },
        }
    }
    return .{ .run = s };
}

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
        .integer => |x| try std.fmt.allocPrint(a, "{d}", .{x}),
        .float => |x| try std.fmt.allocPrint(a, "{d}", .{x}),
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

fn jsonInt(v: ?json.Value, default: i64) i64 {
    const x = v orelse return default;
    return json.int(x) orelse default;
}

/// Port of `_load_config_file_dirs`, `_load_config_file_general` and
/// `_load_config_file_preproc`. The keys read here, with their `opts` help
/// and `Settings` defaults, make up editors/vscode/schemas/fortls.schema.json:
/// run tools/gen_config_schema.py after changing them.
pub fn applyConfig(a: Allocator, s: *Settings, cfg: json.Value) !void {
    // Include and Exclude directories
    if (json.get(cfg, "excl_paths")) |v| s.excl_paths = try jsonList(a, v);
    if (json.get(cfg, "source_dirs")) |v| s.source_dirs = try jsonList(a, v);
    if (json.get(cfg, "incl_suffixes")) |v| s.incl_suffixes = try jsonList(a, v);
    if (json.get(cfg, "excl_suffixes")) |v| s.excl_suffixes = try jsonList(a, v);
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
    s.prefer_implementation = jsonBool(json.get(cfg, "prefer_implementation"), s.prefer_implementation);
    s.lowercase_hover = jsonBool(json.get(cfg, "lowercase_hover"), s.lowercase_hover);
    // Diagnostic options
    s.max_line_length = jsonInt(json.get(cfg, "max_line_length"), s.max_line_length);
    s.max_comment_line_length = jsonInt(json.get(cfg, "max_comment_line_length"), s.max_comment_line_length);
    s.fixed_line_length = jsonInt(json.get(cfg, "fixed_line_length"), s.fixed_line_length);
    s.disable_diagnostics = jsonBool(json.get(cfg, "disable_diagnostics"), s.disable_diagnostics);
    s.workspace_diagnostics = jsonBool(json.get(cfg, "workspace_diagnostics"), s.workspace_diagnostics);
    if (json.get(cfg, "diagnostic_severity")) |v| try applyDiagnosticSeverity(a, s, v);
    if (json.get(cfg, "external_modules")) |v| s.external_modules = try jsonList(a, v);
    // Compiler diagnostics
    if (json.get(cfg, "compiler_diagnostics")) |v| s.compiler_diagnostics = json.str(v);
    if (json.get(cfg, "compiler_path")) |v| s.compiler_path = json.str(v);
    if (json.get(cfg, "compiler_args")) |v| s.compiler_args = switch (v) {
        .null => null,
        .string => |x| blk: {
            var list: StrList = .{};
            var words = std.mem.tokenizeAny(u8, x, " \t");
            while (words.next()) |w| try list.items.append(a, w);
            break :blk list;
        },
        // a list keeps repeated arguments (-I a -I b)
        .array => |arr| blk: {
            var list: StrList = .{};
            for (arr.items) |item| try list.items.append(a, try jsonScalarString(a, item));
            break :blk list;
        },
        else => s.compiler_args,
    };
    if (json.get(cfg, "compiler_mod_dir")) |v| s.compiler_mod_dir = json.str(v);
    // Symbols options
    s.symbol_skip_mem = jsonBool(json.get(cfg, "symbol_skip_mem"), s.symbol_skip_mem);
    // Code Actions options
    s.enable_code_actions = jsonBool(json.get(cfg, "enable_code_actions"), s.enable_code_actions);
    // Preprocessor options
    // like every other option, a value in the file replaces the one from the
    // command line, and no value leaves it alone (upstream #536)
    if (json.get(cfg, "pp_suffixes")) |v| s.pp_suffixes = if (v == .null) null else try jsonList(a, v);
    if (json.get(cfg, "pp_defs")) |v| try applyPpDefs(a, s, v);
    if (json.get(cfg, "include_dirs")) |v| s.include_dirs = try jsonList(a, v);
    if (json.get(cfg, "compile_commands")) |v| s.compile_commands = json.str(v);
    s.disable_compile_commands = jsonBool(json.get(cfg, "disable_compile_commands"), s.disable_compile_commands);
    // Debug options
    if (jsonBool(json.get(cfg, "debug_log"), s.debug_log) and !s.debug_log) s.debug_log = true;
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
    if (pos >= src.len) return std.fmt.allocPrint(a, "<string>:{d} Unexpected end of input at column {d}", .{ line, col });
    return std.fmt.allocPrint(a, "<string>:{d} Unexpected \"{c}\" at column {d}", .{ line, src[pos], col });
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

test "cli parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseArgs(a, &.{ "--incremental_sync", "--sort_keywords", "-n1", "--source_dirs", "a", "b", "--hover_lang", "x" }, "0.1.0");
    const s = r.run;
    try std.testing.expect(s.incremental_sync);
    try std.testing.expectEqual(@as(i64, 1), s.nthreads);
    try std.testing.expectEqual(@as(usize, 2), s.source_dirs.len());
    try std.testing.expectEqualStrings("x", s.hover_language);
    const e = try json5ErrorMessage(a, "{\n    \"source_dirs\", \"s\"\n}\n", 19);
    try std.testing.expectEqualStrings("<string>:2 Unexpected \",\" at column 18", e);
}
