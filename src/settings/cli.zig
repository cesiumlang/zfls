//! The command line: its options with their help, read into `Settings`
//! (port of `fortls.interface`). Long options may be abbreviated to any
//! unique prefix, like Python's argparse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const json5 = @import("../json5.zig");
const settings = @import("../settings.zig");
const suffixes = settings.suffixes;
const Settings = settings.Settings;
const StrList = settings.StrList;
const applyPpDefs = settings.applyPpDefs;
const applyDiagnosticSeverity = settings.applyDiagnosticSeverity;
const applyFileAssociations = settings.applyFileAssociations;
const arg_lists = settings.arg_lists;
const isArgList = settings.isArgList;
const argList = settings.argList;
const json5ErrorMessage = settings.json5ErrorMessage;

/// The extensions of Fortran sources indexed by default, in upper case
const default_suffixes: []const u8 = blk: {
    var list: []const u8 = "";
    for (suffixes.all, 0..) |s, i| {
        if (i > 0) list = list ++ ", ";
        for (s.ext) |c| list = list ++ &[_]u8{std.ascii.toUpper(c)};
    }
    break :blk list;
};

pub const Kind = enum { flag, int, string, list, json, help, debug_help, version };

pub const Opt = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    kind: Kind,
    metavar: []const u8 = "",
    help: []const u8,
    debug: bool = false,
    group: []const u8 = "",
};

pub const opts = [_]Opt{
    .{ .long = "help", .short = "-h", .kind = .help, .help = "show this help message and exit" },
    .{ .long = "version", .short = "-v", .kind = .version, .help = "Print server version number and exit" },
    .{ .long = "config", .short = "-c", .kind = .string, .metavar = "CONFIG", .help = "Configuration options file, TOML or JSON (default file name: .zflsrc, other default supported names: .fortlsrc, .fortls.json, .fortls)" },
    .{ .long = "nthreads", .short = "-n", .kind = .int, .metavar = "INTEGER", .help = "Number of threads to use during workspace initialization (default: 4)" },
    .{ .long = "notify_init", .kind = .flag, .help = "Send notification message when workspace initialization is complete" },
    .{ .long = "incremental_sync", .kind = .flag, .help = "Use incremental document synchronization (beta)" },
    .{ .long = "recursion_limit", .kind = .int, .metavar = "INTEGER", .help = "Set the maximum recursion depth for the parser (default: 1000)" },
    .{ .long = "sort_keywords", .kind = .flag, .help = "Display variable keywords information, function/subroutine definitions, etc. in a consistent (sorted) manner default: no sorting, display code as is)" },
    .{ .long = "disable_autoupdate", .kind = .flag, .help = "Accepted for compatibility with fortls and ignored: zfls does not update itself." },
    .{ .long = "preserve_keyword_order", .kind = .flag, .help = "DEPRECATED, this is now the default. To sort use sort_keywords" },
    .{ .long = "debug_log", .kind = .flag, .help = "Generate debug log in project root folder" },
    .{ .long = "disable_index_cache", .kind = .flag, .help = "Do not keep the workspace's files, and what zfls parsed from them, in one file of zfls's cache, from which a start reads those that have not changed instead of reading and parsing each file" },
    .{ .long = "debug_help", .kind = .debug_help, .help = "Display options for debugging zfls" },

    .{ .long = "source_dirs", .kind = .list, .metavar = "[DIRS ...]", .help = "Folders containing source files (default: set())", .group = "Sources file parsing options" },
    .{ .long = "incl_suffixes", .kind = .list, .metavar = "[SUFFIXES ...]", .help = "Consider additional file extensions to the default (default: " ++ default_suffixes ++ " (lower & upper casing))", .group = "Sources file parsing options" },
    .{ .long = "excl_suffixes", .kind = .list, .metavar = "[SUFFIXES ...]", .help = "Source file extensions to be excluded (default: set())", .group = "Sources file parsing options" },
    .{ .long = "excl_paths", .kind = .list, .metavar = "[DIRS ...]", .help = "Folders to exclude from parsing", .group = "Sources file parsing options" },
    .{ .long = "comment_markers", .kind = .list, .metavar = "[MARKERS ...]", .help = "Further markers that start a comment as ! does, outside strings, such as ;* of a dialect that a preprocessor turns into Fortran", .group = "Sources file parsing options" },
    .{ .long = "disable_openmp_conditional", .kind = .flag, .help = "Read OpenMP conditional compilation lines (!$ followed by a blank, in fixed form also c$ and *$ in column 1) as comments, as a build without OpenMP does; by default they are code", .group = "Sources file parsing options" },
    .{ .long = "d_lines", .kind = .string, .metavar = "READING", .help = "How a fixed-form line with D or d in column 1 (a debug line) is read: comment, or code (the D is a blank), as compilers do by an option (default: comment)", .group = "Sources file parsing options" },
    .{ .long = "file_associations", .kind = .json, .metavar = "JSON", .help = "The editor's languages of files by glob pattern, as VS Code's files.associations, e.g. {\"*.fpp\": \"FortranFixedForm\"}: a .fpp file whose language is FortranFreeForm or FortranFixedForm is read in that form, not as its text suggests (a pattern with / matches the absolute path, one without the file name; the longest matching pattern wins)", .group = "Sources file parsing options" },

    .{ .long = "autocomplete_no_prefix", .kind = .flag, .help = "Do not filter autocomplete results by variable prefix", .group = "Autocomplete options" },
    .{ .long = "autocomplete_no_auto_use", .kind = .flag, .help = "Do not offer the public names of modules that are not used yet (completing one adds its USE statement)", .group = "Autocomplete options" },
    .{ .long = "autocomplete_no_snippets", .kind = .flag, .help = "Do not use snippets with place holders in autocomplete results", .group = "Autocomplete options" },
    .{ .long = "autocomplete_name_only", .kind = .flag, .help = "Complete only the name of procedures and not the parameters", .group = "Autocomplete options" },
    .{ .long = "lowercase_intrinsics", .kind = .flag, .help = "Use lowercase for intrinsics and keywords in autocomplete requests", .group = "Autocomplete options" },
    .{ .long = "use_signature_help", .kind = .flag, .help = "Use signature help instead of subroutine/function snippets. This effectively sets --autocomplete_no_snippets", .group = "Autocomplete options" },

    .{ .long = "variable_hover", .kind = .flag, .help = "DEPRECATED: This option is always on. Show hover information for variables", .group = "Hover options" },
    .{ .long = "hover_signature", .kind = .flag, .help = "Hover on an actual argument of a call also shows the dummy argument it is passed to", .group = "Hover options" },
    .{ .long = "hover_language", .kind = .string, .metavar = "HOVER_LANGUAGE", .help = "Language used for responses to hover requests a VSCode language id (default: fortran90)", .group = "Hover options" },
    .{ .long = "doc_math", .kind = .string, .metavar = "MODE", .help = "The formulas of documentation comments (\\f$ x \\f$, \\( x \\), \\f[ x \\f]) in hover, completion and signature help: keep (as written), dollar ($x$ and $$x$$, for clients that render math) or plain (in backticks, without the markers) (default: keep)", .group = "Hover options" },
    .{ .long = "lowercase_hover", .kind = .flag, .help = "Show the keywords of hover in lowercase (real, intent(in) :: x)", .group = "Hover options" },
    .{ .long = "hover_no_type_components", .kind = .flag, .help = "Hover on a derived type or a variable of one does not list the type's components and type-bound procedures", .group = "Hover options" },
    .{ .long = "hover_plain_comments", .kind = .flag, .help = "Plain comments directly above a declaration, at the end of its line or right under a procedure's header are its documentation when it has no !>, !< or !! documentation", .group = "Hover options" },
    .{ .long = "prefer_implementation", .kind = .flag, .help = "Hover and go to definition use the implementation of a procedure declared in an interface (e.g. a separate module procedure in a submodule) instead of the interface", .group = "Hover options" },

    .{ .long = "max_line_length", .kind = .int, .metavar = "INTEGER", .help = "Maximum line length (default: -1)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "max_comment_line_length", .kind = .int, .metavar = "INTEGER", .help = "Maximum comment line length (default: -1)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "fixed_line_length", .kind = .int, .metavar = "INTEGER", .help = "Columns of code in a fixed-form line, as gfortran's -ffixed-line-length-n (72, 80, 132): the rest is highlighted as a comment and is not read for names (default: -1, no limit)", .group = "Sources file parsing options" },
    .{ .long = "disable_diagnostics", .kind = .flag, .help = "Disable diagnostics", .group = "Diagnostic options (error swigles)" },
    .{ .long = "diagnostics_change_delay", .kind = .int, .metavar = "MS", .help = "The milliseconds without a change before the diagnostics of a document that is edited are published again (default: 300; 0: with each change; negative: only when it is opened and saved)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "workspace_diagnostics", .kind = .flag, .help = "Publish the diagnostics of every file of the workspace, not only of the open ones (after initialization, and again when files change)", .group = "Diagnostic options (error swigles)" },
    .{ .long = "diagnostic_severity", .kind = .json, .metavar = "JSON", .help = "Severity of the diagnostics of each code, e.g. {\"masks-parent\": \"off\"}: off, error, warning, information or hint", .group = "Diagnostic options (error swigles)" },
    .{ .long = "disable_bind_c_search", .kind = .flag, .help = "Go to definition of a BIND(C) procedure does not search the workspace's C files for its C declaration (an editor with a C language server can ask that instead)", .group = "Symbols options" },
    .{ .long = "bind_c_clangd", .kind = .string, .metavar = "PATH", .help = "Start this clangd (its path, or clangd for the one on the PATH) and ask it for the C declarations and calls of BIND(C) procedures too, besides zfls's search of the C files: its index of the project's compile_commands.json has those of headers outside the source directories and of names a macro makes", .group = "Symbols options" },
    .{ .long = "external_modules", .kind = .list, .metavar = "[MODULES ...]", .help = "Modules from outside the project (glob patterns, e.g. mpi petsc*) that USE statements name without a diagnostic", .group = "Diagnostic options (error swigles)" },

    .{ .long = "compiler_diagnostics", .kind = .string, .metavar = "COMPILER", .help = "Check each file with a compiler when it is opened and saved, and publish its errors and warnings with zfls's diagnostics: gfortran, ifx, ifort, flang, nvfortran, nagfor or lfortran (default: none). The modules a file uses are compiled first", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_path", .kind = .string, .metavar = "PATH", .help = "The compiler executable, or the directory that holds it (default: the one on the PATH)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_args", .kind = .string, .metavar = "ARGS", .help = "The compiler's arguments, separated by spaces (or a JSON list) on the command line and a list in a configuration file (default: the compiler's warnings, e.g. -Wall for gfortran). Include directories and preprocessor definitions are added", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_diagnostics_fixed", .kind = .string, .metavar = "COMPILER", .help = "The compiler that checks fixed-form files, as compiler_diagnostics, or none (default: compiler_diagnostics). The modules a file uses are compiled with the compiler of the file", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_path_fixed", .kind = .string, .metavar = "PATH", .help = "The executable of compiler_diagnostics_fixed, as compiler_path (default: compiler_path)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_args_fixed", .kind = .string, .metavar = "ARGS", .help = "The arguments of the compiler for fixed-form files, as compiler_args (default: compiler_args; empty: the compiler's defaults)", .group = "Compiler diagnostics options" },
    .{ .long = "lint_dialect", .kind = .string, .metavar = "DIALECT", .help = "The dialect zfls's own checks lint against: neutral (only what gfortran, ifx and Flang agree on), gfortran, ifx or flang, which also reports that compiler's quirks as you type (default: the dialect of compiler_diagnostics, else neutral)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_mod_dir", .kind = .string, .metavar = "DIR", .help = "Where the compiler writes .mod files, relative to the root (default: a directory in zfls's cache)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_include_dirs", .kind = .list, .metavar = "[DIRS ...]", .help = "Further include directories for the compiler, relative to the root; glob patterns match directories (zfls's include_dirs are passed too)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_no_save", .kind = .flag, .help = "Do not check a file with the compiler when it is saved, only when it is opened (and while it is edited, with compiler_on_change)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_on_change", .kind = .flag, .help = "Also check a file while it is edited: its unsaved text, after compiler_change_delay milliseconds without a change", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_change_delay", .kind = .int, .metavar = "MS", .help = "With compiler_on_change, the milliseconds without a change before a check (default: 1000)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_no_dependencies", .kind = .flag, .help = "Do not compile the workspace modules a file uses before checking it, nor check again the open files that use a module when its file is saved", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_no_compile_commands", .kind = .flag, .help = "Do not check a file with the arguments of its command in compile_commands.json (used when compiler_args is not set)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_fypp", .kind = .string, .metavar = "FYPP", .help = "Run fypp (this executable) on each file before the compiler checks it, with line markers naming the file (default: none)", .group = "Compiler diagnostics options" },
    .{ .long = "compiler_fypp_args", .kind = .string, .metavar = "ARGS", .help = "fypp's further arguments (-I, -D, ...), separated by spaces (or a JSON list) on the command line and a list in a configuration file", .group = "Compiler diagnostics options" },

    .{ .long = "fortitude", .kind = .flag, .help = "Lint files with fortitude (pip install fortitude-lint) when they are opened and saved: its problems are warnings, its fixes quick fixes, and source.fixAll.fortitude applies the safe ones", .group = "Linter options" },
    .{ .long = "fortitude_path", .kind = .string, .metavar = "PATH", .help = "fortitude's executable (default: the one on the PATH)", .group = "Linter options" },
    .{ .long = "fortitude_args", .kind = .string, .metavar = "ARGS", .help = "fortitude check's further arguments, such as --select; separated by spaces (or a JSON list) on the command line and a list in a configuration file", .group = "Linter options" },
    .{ .long = "fortitude_on_change", .kind = .flag, .help = "Also lint a file with fortitude while it is edited, after fortitude_change_delay milliseconds without a change", .group = "Linter options" },
    .{ .long = "fortitude_change_delay", .kind = .int, .metavar = "MS", .help = "With fortitude_on_change, the milliseconds without a change before linting (default: 500)", .group = "Linter options" },
    .{ .long = "codee", .kind = .flag, .help = "Check files with Codee (codee checks, a commercial tool) when they are opened and saved", .group = "Linter options" },
    .{ .long = "codee_path", .kind = .string, .metavar = "PATH", .help = "Codee's executable (default: the one on the PATH)", .group = "Linter options" },
    .{ .long = "codee_args", .kind = .string, .metavar = "ARGS", .help = "codee checks's further arguments; ${file} stands for the file (else it comes last). Separated by spaces (or a JSON list) on the command line and a list in a configuration file", .group = "Linter options" },

    .{ .long = "formatter", .kind = .string, .metavar = "FORMATTER", .help = "Format documents and selections with zfls, its own formatter, which needs no tool; or with findent, fprettify, codee (Codee's codee format), forformat, or custom (formatter_path with formatter_args), installed separately, which zfls gives the text on stdin and reads the result from stdout; none: no formatting (default: zfls)", .group = "Formatting options" },
    .{ .long = "formatter_path", .kind = .string, .metavar = "PATH", .help = "The formatter executable, or the directory that holds it (default: the one on the PATH; for codee, codee_path's); the command of the custom formatter", .group = "Formatting options" },
    .{ .long = "formatter_args", .kind = .string, .metavar = "ARGS", .help = "The formatter's further arguments, separated by spaces (or a JSON list) on the command line and a list in a configuration file. findent gets -ifree or -ifixed from the file's form unless these set the input format, and -Ia (keep the indentation) for a selection; fprettify also reads .fprettify.rc files from the file's directory up; codee gets format - -o -, forformat --stdin-filename=FILE and -ifree or -ifixed; for custom they are the whole command line, in which ${file} is the document's path and ${form} free or fixed", .group = "Formatting options" },
    .{ .long = "formatter_fixed", .kind = .string, .metavar = "FORMATTER", .help = "The formatter of fixed-form files: zfls, findent, codee, forformat, custom, or none (default: the formatter option's; fprettify formats free form only)", .group = "Formatting options" },
    .{ .long = "formatter_fixed_args", .kind = .string, .metavar = "ARGS", .help = "The further arguments of formatter_fixed, as formatter_args", .group = "Formatting options" },

    .{ .long = "pp_suffixes", .kind = .list, .metavar = "[SUFFIXES ...]", .help = "File extensions to be parsed ONLY for preprocessor commands (default: all uppercase source file suffixes, and .fpp)", .group = "Preprocessor options" },
    .{ .long = "include_dirs", .kind = .list, .metavar = "[DIRS ...]", .help = "Folders containing preprocessor files with extensions PP_SUFFIXES.", .group = "Preprocessor options" },
    .{ .long = "compile_commands", .kind = .string, .metavar = "PATH", .help = "compile_commands.json (or its directory) whose Fortran entries add include directories and preprocessor definitions; empty for none (default: compile_commands.json in the root, root/build or root/builddir)", .group = "Preprocessor options" },
    .{ .long = "disable_compile_commands", .kind = .flag, .help = "Do not read a compile_commands.json", .group = "Preprocessor options" },
    .{ .long = "disable_intel_directives", .kind = .flag, .help = "Read Intel's conditional compilation directives (!DEC$ IF DEFINED (X), !DIR$ IF (expr), ELSEIF, ELSE, ENDIF, DEFINE, UNDEFINE) as comments; by default the branches they leave out are skipped, in every Fortran file", .group = "Preprocessor options" },
    .{ .long = "pp_defs", .kind = .json, .metavar = "JSON", .help = "A dictionary with additional preprocessor definitions. Preprocessor definitions are normally included via INCLUDE_DIRS", .group = "Preprocessor options" },

    .{ .long = "symbol_skip_mem", .kind = .flag, .help = "Do not include type members in document symbol results", .group = "Symbols options" },
    .{ .long = "enable_code_actions", .kind = .flag, .help = "Enable experimental code actions (default: false)", .group = "CodeActions options [limited]" },

    .{ .long = "code_lens_no_references", .kind = .flag, .help = "Do not show the number of references above each module, procedure and derived type (a code lens, counted when the editor shows it)", .group = "Code lens options" },
    .{ .long = "code_lens_no_run", .kind = .flag, .help = "Do not show Run and Debug above a program (code lenses, for an editor that has those commands, as the VS Code extension does)", .group = "Code lens options" },
    .{ .long = "closing_hint_lines", .kind = .int, .metavar = "INTEGER", .help = "An inlay hint after the END of a construct or procedure of this many lines or more, with its opening statement (default: 25; 0: none)", .group = "Inlay hint options" },

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
        "default named '.zflsrc' (TOML), '.fortlsrc', '.fortls.json' or '.fortls' (other names/paths can specified " ++
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
    for (args) |arg| if (std.mem.find(u8, arg, "--debug_") != null) {
        any_debug_arg = true;
    };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        var arg = args[i];
        var inline_val: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.findScalar(u8, arg, '=')) |eq| {
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
            .ambiguous => return .{ .exit_err = try a.print("{s}zfls: error: ambiguous option: {s}\n", .{ usage, arg }) },
            .none => return .{ .exit_err = try a.print("{s}zfls: error: unrecognized arguments: {s}\n", .{ usage, args[i] }) },
        };
        switch (o.kind) {
            .help => return .{ .exit_ok = try helpText(a, version, any_debug_arg) },
            .debug_help => return .{ .exit_ok = try helpText(a, version, true) },
            .version => return .{ .exit_ok = try a.print("{s}\n", .{version}) },
            .flag => {
                if (inline_val != null) return .{ .exit_err = try a.print("{s}zfls: error: argument --{s}: ignored explicit argument '{s}'\n", .{ usage, o.long, inline_val.? }) };
                inline for (@typeInfo(Settings).@"struct".field_names) |fname| {
                    if (std.mem.eql(u8, fname, o.long)) {
                        if (@TypeOf(@field(s, fname)) == bool) @field(s, fname) = true;
                    }
                }
            },
            .int, .string, .json => {
                const val = inline_val orelse blk: {
                    if (i + 1 >= args.len) return .{ .exit_err = try a.print("{s}zfls: error: argument --{s}: expected one argument\n", .{ usage, o.long }) };
                    i += 1;
                    break :blk args[i];
                };
                if (o.kind == .json) {
                    const v = json5.parse(a, val) catch {
                        return .{ .exit_err = try a.print("{s}zfls: error: argument --{s}: invalid loads value: '{s}'\n", .{ usage, o.long, val }) };
                    };
                    if (std.mem.eql(u8, o.long, "pp_defs")) try applyPpDefs(a, &s, v);
                    if (std.mem.eql(u8, o.long, "diagnostic_severity")) try applyDiagnosticSeverity(a, &s, v);
                    if (std.mem.eql(u8, o.long, "file_associations")) try applyFileAssociations(a, &s, v);
                    continue;
                }
                if (isArgList(o.long)) {
                    const list = try cliArgList(a, val);
                    inline for (arg_lists) |name| if (std.mem.eql(u8, o.long, name)) {
                        @field(s, name) = if (@FieldType(Settings, name) == StrList) list else @as(?StrList, list);
                    };
                    continue;
                }
                var handled = false;
                inline for (@typeInfo(Settings).@"struct".field_names) |fname| {
                    if (!handled and std.mem.eql(u8, fname, o.long)) {
                        const FT = @TypeOf(@field(s, fname));
                        if (FT == i64 or FT == ?i64) {
                            @field(s, fname) = std.fmt.parseInt(i64, str.strip(val), 10) catch {
                                return .{ .exit_err = try a.print("{s}zfls: error: argument --{s}: invalid int value: '{s}'\n", .{ usage, o.long, val }) };
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
                if (std.mem.eql(u8, o.long, "comment_markers")) s.comment_markers = list;
                if (std.mem.eql(u8, o.long, "include_dirs")) s.include_dirs = list;
                if (std.mem.eql(u8, o.long, "pp_suffixes")) s.pp_suffixes = list;
                if (std.mem.eql(u8, o.long, "external_modules")) s.external_modules = list;
                if (std.mem.eql(u8, o.long, "compiler_include_dirs")) s.compiler_include_dirs = list;
            },
        }
    }
    return .{ .run = s };
}

/// Arguments on the command line: a JSON list of strings, which keeps an
/// argument with a space whole, else a string split at spaces
fn cliArgList(a: Allocator, val: []const u8) !StrList {
    if (std.mem.startsWith(u8, str.strip(val), "[")) {
        if (json.parse(a, val)) |v| {
            if (v == .array) if (try argList(a, v)) |list| return list;
        } else |e| if (e == error.OutOfMemory) return e;
    }
    return (try argList(a, .{ .string = val })).?;
}

test "program arguments on the command line: a JSON list keeps an argument with a space whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseArgs(a, &.{ "--compiler_args=[\"-I/a b/inc\", \"-Wall\"]", "--fortitude_args", "[1, \"x\"", "--codee_args=[]" }, "0.1.0");
    const s = r.run;
    try std.testing.expectEqual(@as(usize, 2), s.compiler_args.?.len());
    try std.testing.expectEqualStrings("-I/a b/inc", s.compiler_args.?.slice()[0]);
    try std.testing.expectEqualStrings("-Wall", s.compiler_args.?.slice()[1]);
    // not JSON: split at spaces, as before
    try std.testing.expectEqual(@as(usize, 2), s.fortitude_args.len());
    try std.testing.expectEqualStrings("[1,", s.fortitude_args.slice()[0]);
    try std.testing.expectEqual(@as(usize, 0), s.codee_args.len());
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
