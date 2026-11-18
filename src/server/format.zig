//! Formatting (`formatter`): `textDocument/formatting` and `rangeFormatting`
//! run findent, fprettify, Codee's formatter, forformat or a command of the
//! user's on the document's text as zfls has it, given on stdin, and answer
//! with the smallest edit that turns the old lines into the formatted ones.
//! No files are written.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const str = @import("../str.zig");
const paths = @import("../paths.zig");
const parser = @import("../parser.zig");
const C = @import("../constants.zig");

const FortranFile = parser.FortranFile;
const Value = json.Value;

const textedits = @import("textedits.zig");
const lineEdits = textedits.lineEdits;

const srv = @import("../server.zig");
const Server = srv.Server;

const is_windows = builtin.target.os.tag == .windows;
/// A formatter run that takes longer is stopped
const timeout_s = 30;

pub const Formatter = enum {
    findent,
    fprettify,
    /// Codee's formatter, `codee format`
    codee,
    forformat,
    /// `formatter_path` with `formatter_args`
    custom,

    /// The formatter of an option's value; null for none, `none` and
    /// names zfls does not know
    pub fn fromName(name: ?[]const u8) ?Formatter {
        return std.meta.stringToEnum(Formatter, std.mem.trim(u8, name orelse return null, " "));
    }

    /// How to install it, for the message when it is missing
    fn installHint(f: Formatter) []const u8 {
        return switch (f) {
            .findent => "`pip install findent` (or `conda install -c conda-forge findent`)",
            .fprettify => "`pip install fprettify` (or `conda install -c conda-forge fprettify`)",
            .codee => "Codee (https://www.codee.com), whose `codee` zfls also runs for `codee_path`",
            .forformat => "forformat (see its project for how)",
            .custom => "the command of your formatter",
        };
    }

    /// Whether the tool formats only whole files: a selection is then
    /// formatted with the rest of the file, and only the edits inside it
    /// are kept
    pub fn wholeFile(f: Formatter) bool {
        return f == .codee or f == .forformat;
    }
};

/// The names of the formatters, for messages
const formatter_names = "findent, fprettify, codee, forformat or custom";

/// Whether a formatter is configured, for the server's capabilities
pub fn enabled(self: *const Server) bool {
    return Formatter.fromName(self.s.formatter) != null or Formatter.fromName(self.s.formatter_fixed) != null;
}

/// Warns about a `formatter` or `formatter_fixed` that is no formatter zfls
/// knows
pub fn checkSetting(self: *Server, a: Allocator) !void {
    inline for (.{ "formatter", "formatter_fixed" }) |option| {
        if (@field(self.s, option)) |name| {
            const trimmed = std.mem.trim(u8, name, " ");
            if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "none") and Formatter.fromName(name) == null)
                self.postMessage(a, try a.print(option ++ ": unknown formatter \"{s}\"; it is " ++ formatter_names, .{name}), C.Severity.warn);
        }
    }
}

// --------------------------------------------------------------------------
// The pure parts: the arguments, the lines of a selection, the edit

/// The arguments for a formatter that reads the source from stdin and
/// writes the result to stdout.
///
/// - findent cannot see the file name, so the input form is given with
///   `-ifixed` or `-ifree`, unless the user's arguments set one (`-i...`
///   form or `--input_format`/`--input-format`). For a selection, `-Ia`
///   makes the first selected line's indentation the starting indentation.
/// - fprettify reads stdin when given no file.
/// - `codee format - -o -` reads stdin and writes stdout.
/// - forformat gets the file's name (`--stdin-filename=`) and its form
///   (`-ifree`, `-ifixed`), unless the user's arguments set one.
/// - `custom` gets the user's arguments only, in which `${file}` stands for
///   the document's path and `${form}` for `free` or `fixed`.
///
/// The user's arguments come last, so they can override the defaults where
/// the tool takes the last of repeated options.
pub fn formatterArgs(a: Allocator, formatter: Formatter, fixed: bool, user: []const []const u8, selection: bool, path: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    switch (formatter) {
        .findent => {
            if (!anyOf(user, isFindentInputFormat)) try args.append(a, if (fixed) "-ifixed" else "-ifree");
            if (selection and !anyOf(user, isFindentStartIndent)) try args.append(a, "-Ia");
        },
        .fprettify => {},
        .codee => try args.appendSlice(a, &.{ "format", "-", "-o", "-" }),
        .forformat => {
            try args.append(a, try a.print("--stdin-filename={s}", .{path}));
            if (!anyOf(user, isFindentInputFormat)) try args.append(a, if (fixed) "-ifixed" else "-ifree");
        },
        .custom => {
            for (user) |u| try args.append(a, try substitute(a, u, path, fixed));
            return args.items;
        },
    }
    try args.appendSlice(a, user);
    return args.items;
}

/// `arg` with `${file}` replaced by `path` and `${form}` by `free` or
/// `fixed`
pub fn substitute(a: Allocator, arg: []const u8, path: []const u8, fixed: bool) ![]const u8 {
    const with_file = try std.mem.replaceOwned(u8, a, arg, "${file}", path);
    return std.mem.replaceOwned(u8, a, with_file, "${form}", if (fixed) "fixed" else "free");
}

fn anyOf(args: []const []const u8, pred: fn ([]const u8) bool) bool {
    for (args) |x| if (pred(x)) return true;
    return false;
}

/// `--name` or `--name=...`, with `_` or `-` between its words
fn isLongOption(arg: []const u8, comptime name: []const u8) bool {
    inline for (.{ name, comptime dashed(name) }) |n| {
        if (std.mem.startsWith(u8, arg, "--" ++ n)) {
            const rest = arg[n.len + 2 ..];
            if (rest.len == 0 or rest[0] == '=') return true;
        }
    }
    return false;
}

fn dashed(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = name[0..name.len].*;
    std.mem.replaceScalar(u8, &out, '_', '-');
    const final = out;
    return &final;
}

fn isFindentInputFormat(arg: []const u8) bool {
    for ([_][]const u8{ "-ifixed", "-ifree", "-iauto" }) |x| if (std.mem.eql(u8, arg, x)) return true;
    return isLongOption(arg, "input_format");
}

fn isFindentStartIndent(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-I") or isLongOption(arg, "start_indent");
}

/// The whole lines a selection covers, as first and last (0-based,
/// inclusive). A selection that ends at the start of a line, after covering
/// earlier lines, does not include that line.
pub fn selectedLines(start_line: usize, end_line: usize, end_character: usize) [2]usize {
    const last = if (end_line > start_line and end_character == 0) end_line - 1 else end_line;
    return .{ start_line, last };
}

/// The lines of a formatter's output, without a final line terminator
pub fn outputLines(a: Allocator, stdout: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < stdout.len) : (i += 1) {
        const c = stdout[i];
        if (c != '\n' and c != '\r') continue;
        try lines.append(a, stdout[start..i]);
        if (c == '\r' and i + 1 < stdout.len and stdout[i + 1] == '\n') i += 1;
        start = i + 1;
    }
    // text after the last line break, unless it is the empty rest of a
    // final terminator
    if (start < stdout.len or lines.items.len == 0) try lines.append(a, stdout[start..]);
    return lines.items;
}

/// The text to give a formatter for some lines: each ends with a newline
pub fn inputText(a: Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.items;
}

// --------------------------------------------------------------------------
// Running a formatter

pub const Run = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

/// `std.process.run` with `input` on the child's stdin. It is written on a
/// thread of its own, then closed, so that a child that writes before it
/// has read all of it cannot block on a full pipe.
pub fn runWithInput(a: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, input: []const u8, timeout: Io.Timeout) !Run {
    var writer: ?std.Thread = null;
    defer if (writer) |t| t.join();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .create_no_window = true,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // a child still running (after an error) is killed before the writer
    // is joined, which ends its write
    defer child.kill(io);
    const stdin = child.stdin.?;
    child.stdin = null;
    writer = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, writeInput, .{ io, stdin, input }) catch |e| {
        stdin.close(io);
        return e;
    };

    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const deadline = timeout.toDeadline(io);
    while (multi.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try multi.toOwnedSlice(0), .stderr = try multi.toOwnedSlice(1) };
}

fn writeInput(io: Io, file: Io.File, input: []const u8) void {
    defer file.close(io);
    // a child that ends without reading all of it: its output tells
    file.writeStreamingAll(io, input) catch {};
}

/// The executables to try: `formatter_path` (a file, or a directory that
/// holds the formatter), else the formatter's name, found on the PATH
fn executables(self: *Server, a: Allocator, formatter: Formatter) ![]const []const u8 {
    const name = @tagName(formatter);
    var configured = std.mem.trim(u8, self.s.formatter_path orelse "", " ");
    // Codee's formatter is the `codee` of the checks, unless formatter_path
    // says otherwise
    if (configured.len == 0 and formatter == .codee) configured = std.mem.trim(u8, self.s.codee_path orelse "", " ");
    // a custom formatter has no name of its own to look for
    if (configured.len == 0) return if (formatter == .custom) &.{} else a.dupe([]const u8, &.{name});
    const p = if (std.Io.Dir.path.isAbsolute(configured)) configured else try paths.join(a, &.{ self.root_path, configured });
    if (!paths.isDir(self.io, p)) return a.dupe([]const u8, &.{p});
    if (!is_windows) return a.dupe([]const u8, &.{try paths.join(a, &.{ p, name })});
    return a.dupe([]const u8, &.{
        try paths.join(a, &.{ p, try a.print("{s}.exe", .{name}) }),
        try paths.join(a, &.{ p, try a.print("{s}.bat", .{name}) }),
    });
}

/// Whether `file` is fixed form: by its extension, as editors and compilers
/// take it, else as zfls detected it from the text (an unindented free-form
/// file looks fixed form)
fn isFixedForm(file: *const FortranFile) bool {
    const ext = std.Io.Dir.path.extension(file.path);
    for ([_][]const u8{ ".f", ".for", ".ftn", ".f77" }) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    for ([_][]const u8{ ".f90", ".f95", ".f03", ".f08", ".f18", ".cuf", ".pf", ".fypp" }) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return false;
    return file.fixed;
}

/// Posts a message, once for each `key` (format on save would repeat it)
fn reportOnce(self: *Server, a: Allocator, key: []const u8, message: []const u8, severity: i32) void {
    const h = std.hash.Wyhash.hash(0, key);
    if (std.mem.findScalar(u64, self.format_reported.items, h) == null) {
        self.format_reported.append(self.gpa, h) catch {};
        self.postMessage(a, message, severity);
    } else self.log.warn("{s}", .{message});
}

pub fn serveFormatting(self: *Server, a: Allocator, params: lsp.DocumentFormattingParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    if (file.nLines() == 0) return json.from(a, [_]lsp.TextEdit{});
    return format(self, a, file, 0, file.nLines() - 1, false);
}

pub fn serveRangeFormatting(self: *Server, a: Allocator, params: lsp.DocumentRangeFormattingParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const r = params.range;
    const lines = selectedLines(r.start.line, r.end.line, r.end.character);
    if (lines[0] >= file.nLines()) return json.from(a, [_]lsp.TextEdit{});
    return format(self, a, file, lines[0], @min(lines[1], file.nLines() -| 1), true);
}

/// The edits that format lines `first` to `last` of `file`
fn format(self: *Server, a: Allocator, file: *FortranFile, first: usize, last: usize, selection: bool) !Value {
    const none = try json.from(a, [_]lsp.TextEdit{});
    const fixed = isFixedForm(file);
    // fixed form: `formatter_fixed` when it is set
    const option = if (fixed and self.s.formatter_fixed != null) self.s.formatter_fixed else self.s.formatter;
    const user = if (fixed and self.s.formatter_fixed != null) self.s.formatter_fixed_args.slice() else self.s.formatter_args.slice();
    const formatter = Formatter.fromName(option) orelse return none;
    if (formatter == .fprettify and fixed) {
        reportOnce(self, a, "unsupported", "formatter: fprettify formats free-form Fortran only; set formatter_fixed to findent for fixed-form files", C.Severity.warn);
        return none;
    }
    const name = @tagName(formatter);
    // a tool that formats whole files only: the whole file, then the edits
    // inside the selection
    const whole = selection and formatter.wholeFile();
    const from = if (whole) 0 else first;
    const to = if (whole) file.nLines() - 1 else last;

    // the text as the editor has it (without zfls's comment markers)
    const lines = file.editLines()[from .. to + 1];
    const before = try std.mem.join(a, "\n", lines);
    const args = try formatterArgs(a, formatter, fixed, user, selection and !whole, file.path);
    // fprettify looks for .fprettify.rc from the current directory up
    const dir = paths.dirname(file.path);
    const cwd: ?[]const u8 = if (paths.isDir(self.io, dir)) dir else if (paths.isDir(self.io, self.root_path)) self.root_path else null;
    const input = try inputText(a, lines);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } };
    const run: Run = for (try executables(self, a, formatter)) |exe| {
        const argv = try a.alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        self.log.debug("[format] {s} {s} (lines {d}-{d})", .{ exe, try std.mem.join(a, " ", args), from + 1, to + 1 });
        break runWithInput(a, self.io, argv, cwd, input, timeout) catch |e| switch (e) {
            error.FileNotFound => continue,
            error.OutOfMemory => return e,
            else => {
                reportOnce(self, a, try a.print("failed:{s}:{s}", .{ name, @errorName(e) }), try a.print("formatter: running {s} failed ({s}); the document is unchanged", .{ name, @errorName(e) }), C.Severity.err);
                return none;
            },
        };
    } else {
        const configured = self.s.formatter_path orelse "";
        reportOnce(self, a, try a.print("missing:{s}:{s}", .{ name, configured }), if (formatter == .custom and std.mem.trim(u8, configured, " ").len == 0)
            try a.print("formatter: custom runs formatter_path with formatter_args; set formatter_path to {s}", .{formatter.installHint()})
        else if (std.mem.trim(u8, configured, " ").len > 0)
            try a.print("formatter: {s} was not found at {s} (formatter_path). Install it with {s}, or set formatter_path to it", .{ name, configured, formatter.installHint() })
        else
            try a.print("formatter: {s} was not found on the PATH. Install it with {s}, or set formatter_path to it", .{ name, formatter.installHint() }), C.Severity.err);
        return none;
    };

    const stderr = std.mem.trim(u8, run.stderr, " \t\r\n");
    if (stderr.len > 0) self.log.warn("[format] {s}: {s}", .{ name, stderr });
    if (!run.term.success()) {
        // the last line of the error output: where Python tools put the error
        const detail = if (std.mem.findLastAny(u8, stderr, "\r\n")) |i| stderr[i + 1 ..] else stderr;
        reportOnce(self, a, try a.print("failed:{s}:{s}", .{ name, run.stderr }), try a.print("formatter: {s} {f}{s}{s}; the document is unchanged", .{
            name,
            run.term,
            if (detail.len > 0) ": " else "",
            detail,
        }), C.Severity.err);
        return none;
    }
    const formatted = try outputLines(a, run.stdout);
    if (str.strip(try std.mem.join(a, "\n", formatted)).len == 0 and str.strip(before).len != 0) {
        reportOnce(self, a, try a.print("empty:{s}", .{name}), try a.print("formatter: {s} printed nothing; the document is unchanged", .{name}), C.Severity.err);
        return none;
    }
    // the client gives inserted line breaks the document's line ends
    if (!whole) return json.from(a, try lineEdits(a, lines, formatted, from));
    return json.from(a, try lineEdits(a, lines, try textedits.takeWithin(a, lines, formatted, first, last), 0));
}

// --------------------------------------------------------------------------

const testing = std.testing;

fn expectArgs(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, x| try testing.expectEqualStrings(e, x);
}

test "findent gets the input form from the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{"-ifree"}, try formatterArgs(a, .findent, false, &.{}, false, "/w/a.f90"));
    try expectArgs(&.{"-ifixed"}, try formatterArgs(a, .findent, true, &.{}, false, "/w/a.f90"));
    try expectArgs(&.{ "-ifree", "-i4" }, try formatterArgs(a, .findent, false, &.{"-i4"}, false, "/w/a.f90"));
}

test "findent input form and start indent from the user win" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{"-iauto"}, try formatterArgs(a, .findent, true, &.{"-iauto"}, false, "/w/a.f90"));
    try expectArgs(&.{"--input-format=fixed"}, try formatterArgs(a, .findent, false, &.{"--input-format=fixed"}, false, "/w/a.f90"));
    try expectArgs(&.{ "-Ia", "--input_format=auto" }, try formatterArgs(a, .findent, false, &.{"--input_format=auto"}, true, "/w/a.f90"));
    try expectArgs(&.{ "-ifree", "-I2" }, try formatterArgs(a, .findent, false, &.{"-I2"}, true, "/w/a.f90"));
    try expectArgs(&.{ "-ifree", "--start-indent=3" }, try formatterArgs(a, .findent, false, &.{"--start-indent=3"}, true, "/w/a.f90"));
    // not the option, only a longer one that starts like it
    try expectArgs(&.{ "-ifree", "--input_formats" }, try formatterArgs(a, .findent, false, &.{"--input_formats"}, false, "/w/a.f90"));
}

test "findent keeps the indentation of a selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectArgs(&.{ "-ifree", "-Ia" }, try formatterArgs(arena.allocator(), .findent, false, &.{}, true, "/w/a.f90"));
}

test "codee format reads stdin and writes stdout, in both forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{ "format", "-", "-o", "-" }, try formatterArgs(a, .codee, false, &.{}, false, "/w/a.f90"));
    try expectArgs(&.{ "format", "-", "-o", "-", "--x" }, try formatterArgs(a, .codee, true, &.{"--x"}, false, "/w/a.f"));
}

test "forformat gets the file name and the form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{ "--stdin-filename=/w/a.f90", "-ifree" }, try formatterArgs(a, .forformat, false, &.{}, false, "/w/a.f90"));
    try expectArgs(&.{ "--stdin-filename=/w/a.f", "-ifixed", "-v" }, try formatterArgs(a, .forformat, true, &.{"-v"}, false, "/w/a.f"));
    try expectArgs(&.{ "--stdin-filename=/w/a.f", "-ifree" }, try formatterArgs(a, .forformat, true, &.{"-ifree"}, false, "/w/a.f"));
}

test "a custom formatter gets the user's arguments with ${file} and ${form}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{}, try formatterArgs(a, .custom, false, &.{}, true, "/w/a.f90"));
    try expectArgs(&.{ "--name=/w/a.f90", "free", "-" }, try formatterArgs(a, .custom, false, &.{ "--name=${file}", "${form}", "-" }, false, "/w/a.f90"));
    try expectArgs(&.{ "--form=fixed", "/w/a.f:/w/a.f" }, try formatterArgs(a, .custom, true, &.{ "--form=${form}", "${file}:${file}" }, false, "/w/a.f"));
}

test "fprettify gets only the user's arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{}, try formatterArgs(a, .fprettify, false, &.{}, true, "/w/a.f90"));
    try expectArgs(&.{ "-i", "4", "--enable-decl" }, try formatterArgs(a, .fprettify, false, &.{ "-i", "4", "--enable-decl" }, false, "/w/a.f90"));
}

test "formatter names" {
    try testing.expectEqual(Formatter.findent, Formatter.fromName(" findent").?);
    try testing.expectEqual(Formatter.fprettify, Formatter.fromName("fprettify").?);
    try testing.expectEqual(Formatter.codee, Formatter.fromName("codee").?);
    try testing.expectEqual(Formatter.forformat, Formatter.fromName("forformat").?);
    try testing.expectEqual(Formatter.custom, Formatter.fromName("custom ").?);
    try testing.expectEqual(@as(?Formatter, null), Formatter.fromName("none"));
    try testing.expectEqual(@as(?Formatter, null), Formatter.fromName(null));
}

test "a selection covers whole lines" {
    try testing.expectEqual([2]usize{ 3, 3 }, selectedLines(3, 3, 5));
    try testing.expectEqual([2]usize{ 3, 7 }, selectedLines(3, 7, 2));
    // ending at the start of line 8 (a full-line selection) stops at line 7
    try testing.expectEqual([2]usize{ 3, 7 }, selectedLines(3, 8, 0));
    // an empty selection at the start of a line is that line
    try testing.expectEqual([2]usize{ 3, 3 }, selectedLines(3, 3, 0));
}

test "formatter input and output lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a\nb\n", try inputText(a, &.{ "a", "b" }));
    try expectArgs(&.{ "a", "b" }, try outputLines(a, "a\r\nb\r\n"));
    try expectArgs(&.{ "a", "b" }, try outputLines(a, "a\nb"));
    try expectArgs(&.{ "a", "" }, try outputLines(a, "a\n\n"));
    try expectArgs(&.{""}, try outputLines(a, ""));
}

test "a formatter gets its input on stdin" {
    if (!is_windows and builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a large input, more than a pipe holds, comes back whole
    const line = "      x = 1 ! a line of the input\n";
    const input = try a.alloc(u8, line.len * 20000);
    for (0..20000) |i| @memcpy(input[i * line.len ..][0..line.len], line);
    // a filter that writes each line as it reads it
    const argv: []const []const u8 = if (is_windows) &.{ "findstr", "x" } else &.{"cat"};
    const r = try runWithInput(a, testing.io, argv, null, input, .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } });
    try testing.expect(r.term.success());
    try testing.expectEqual(@as(usize, 20000), (try outputLines(a, r.stdout)).len);
    try testing.expectEqualStrings("      x = 1 ! a line of the input", (try outputLines(a, r.stdout))[19999]);
}
