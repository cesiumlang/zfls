//! In-process harness for the tests of upstream fortls issues: a temporary
//! workspace of source files served by a zfls `Server`, plus helpers to send
//! it LSP requests and to state what the correct answer is.
//!
//! A test describes the behavior a user would expect (not what fortls does)
//! and says whether zfls gets it right:
//!
//! - `.fixed`: zfls behaves correctly; a failure is a regression.
//! - `.known_failure`: the bug still exists in zfls. The expectations must
//!   fail; when they start to pass, the test fails until the marker is
//!   changed to `.fixed`. A known failure is the oracle for a future patch.

const std = @import("std");
const zfls = @import("zfls");
const json = zfls.json;
const paths = zfls.paths;
const Server = zfls.server.Server;
const Logger = zfls.logger;
const Settings = zfls.settings.Settings;
const Value = json.Value;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gpa = std.testing.allocator;
const io = std.testing.io;

// --------------------------------------------------------------------------
// Expectations

pub const Status = enum { fixed, known_failure };

var note_buf: [1024]u8 = undefined;
var note_len: usize = 0;

/// The reason of the last unmet expectation
fn note() []const u8 {
    return note_buf[0..note_len];
}

/// Fail the current expectation with a message
pub fn unmet(comptime fmt: []const u8, args: anytype) error{Unmet} {
    note_len = if (std.fmt.bufPrint(&note_buf, fmt, args)) |s| s.len else |_| note_buf.len;
    return error.Unmet;
}

pub fn expect(ok: bool, comptime fmt: []const u8, args: anytype) error{Unmet}!void {
    if (!ok) return unmet(fmt, args);
}

/// Evaluate the outcome `result` of a test's expectations for `issue`
/// (see the module comment).
pub fn check(issue: u32, status: Status, result: anyerror!void) !void {
    const why = if (result) |_| "passes" else |e| if (e == error.Unmet) note() else @errorName(e);
    record(issue, status, why);
    switch (status) {
        .fixed => result catch |e| {
            std.debug.print("\nfortls issue #{d} is not handled correctly: {s}\n", .{ issue, why });
            return e;
        },
        .known_failure => if (result) |_| {
            std.debug.print("\nfortls issue #{d} is marked as a known failure but now passes: mark it .fixed\n", .{issue});
            return error.UnexpectedlyFixed;
        } else |_| {},
    }
}

// What each test found, for the table in README.md: written to
// .zig-cache/issue-tests.txt as the tests run
var report: std.ArrayList(u8) = .empty;

fn record(issue: u32, status: Status, why: []const u8) void {
    const alloc = std.heap.page_allocator;
    report.print(alloc, "#{d}\t{s}\t{s}\n", .{ issue, @tagName(status), why }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/issue-tests.txt", .data = report.items }) catch {};
}

// --------------------------------------------------------------------------
// Results

pub const Pos = struct { line: i64, col: i64 };

pub const Diagnostic = struct { line: i64, severity: i64, message: []const u8 };

pub const Location = struct { uri: []const u8, line: i64, col: i64 };

pub const Edit = struct { uri: []const u8, line: i64, start: i64, end: i64, new_text: []const u8 };

pub const File = struct { name: []const u8, text: []const u8 };

pub const Options = struct {
    settings: Settings = .{},
    /// `--pp_defs`
    pp_defs: []const zfls.settings.PpDef = &.{},
};

// --------------------------------------------------------------------------
// Workspace

pub const Workspace = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    log: Logger,
    server: *Server,
    root: []const u8,
    files: []const File,

    /// Write `files` (names may contain subdirectories) to a temporary
    /// directory and start a server on it, as `initialize` would.
    pub fn init(files: []const File, opts: Options) !*Workspace {
        // what `main` does at start-up (both are idempotent)
        zfls.patterns.init();
        paths.init(io);
        const w = try gpa.create(Workspace);
        errdefer gpa.destroy(w);
        w.tmp = std.testing.tmpDir(.{});
        errdefer w.tmp.cleanup();
        w.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer w.arena.deinit();
        const aa = w.arena.allocator();
        w.files = files;
        for (files) |f| {
            if (std.fs.path.dirname(f.name)) |d| try w.tmp.dir.createDirPath(io, d);
            try w.tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = f.text });
        }
        w.root = try aa.dupe(u8, try w.tmp.dir.realPathFileAlloc(io, ".", aa));
        w.log = Logger.init(io);
        w.log.stderr_level = .off;
        var settings = opts.settings;
        for (opts.pp_defs) |d| try settings.pp_defs.append(aa, d);
        w.server = try Server.create(gpa, io, settings, &w.log);
        errdefer w.server.destroy();
        _ = try w.server.dispatchPublic(aa, "initialize", try json.from(aa, .{ .rootPath = w.root }));
        return w;
    }

    pub fn deinit(w: *Workspace) void {
        w.server.destroy();
        w.log.deinit();
        w.arena.deinit();
        w.tmp.cleanup();
        gpa.destroy(w);
    }

    fn a(w: *Workspace) Allocator {
        return w.arena.allocator();
    }

    pub fn path(w: *Workspace, name: []const u8) ![]const u8 {
        return std.fs.path.join(w.a(), &.{ w.root, name });
    }

    pub fn uri(w: *Workspace, name: []const u8) ![]const u8 {
        return paths.pathToUri(w.a(), try w.path(name));
    }

    /// Text of a file as written
    pub fn text(w: *Workspace, name: []const u8) []const u8 {
        for (w.files) |f| if (std.mem.eql(u8, f.name, name)) return f.text;
        return "";
    }

    /// Position (0-based line, character) of the `nth` (0-based) occurrence
    /// of `needle` in file `name`, advanced by `plus` characters
    pub fn pos(w: *Workspace, name: []const u8, needle: []const u8, nth: usize, plus: usize) Pos {
        const t = w.text(name);
        var from: usize = 0;
        var n: usize = 0;
        while (std.mem.indexOfPos(u8, t, from, needle)) |i| : (from = i + 1) {
            if (n == nth) {
                const before = t[0..i];
                const line = std.mem.count(u8, before, "\n");
                const bol = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |nl| nl + 1 else 0;
                return .{ .line = @intCast(line), .col = @intCast(i - bol + plus) };
            }
            n += 1;
        }
        std.debug.panic("test bug: no occurrence {d} of '{s}' in {s}", .{ nth, needle, name });
    }

    // ---- requests -----------------------------------------------------

    fn request(w: *Workspace, method: []const u8, params: anytype) !Value {
        return w.server.dispatchPublic(w.a(), method, try json.from(w.a(), params));
    }

    fn docParams(w: *Workspace, name: []const u8) !Value {
        return json.from(w.a(), .{ .textDocument = .{ .uri = try w.uri(name) } });
    }

    fn posParams(w: *Workspace, name: []const u8, p: Pos) !Value {
        return json.from(w.a(), .{
            .textDocument = .{ .uri = try w.uri(name) },
            .position = .{ .line = p.line, .character = p.col },
        });
    }

    /// Messages the server posted to the client (errors, warnings)
    pub fn messages(w: *Workspace) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (w.server.post_messages.items) |m| try out.append(w.a(), m.message);
        return out.items;
    }

    /// `textDocument/didSave`: (re)read and parse the file from disk
    pub fn save(w: *Workspace, name: []const u8) !void {
        _ = try w.server.dispatchPublic(w.a(), "textDocument/didSave", try w.docParams(name));
    }

    /// Replace a file's text on disk and in the server (didChange + didSave)
    pub fn replaceText(w: *Workspace, name: []const u8, new_text: []const u8) !void {
        try w.tmp.dir.writeFile(io, .{ .sub_path = name, .data = new_text });
        _ = try w.server.dispatchPublic(w.a(), "textDocument/didChange", try json.from(w.a(), .{
            .textDocument = .{ .uri = try w.uri(name) },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = new_text }},
        }));
        try w.save(name);
    }

    /// Diagnostics of a file, as published after a save
    pub fn diagnostics(w: *Workspace, name: []const u8) ![]const Diagnostic {
        try w.save(name);
        const v = (try w.server.getDiagnostics(w.a(), try w.uri(name))) orelse return &.{};
        var out: std.ArrayList(Diagnostic) = .empty;
        for (v.items()) |d| {
            try out.append(w.a(), .{
                .line = (d.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse -1,
                .severity = (d.get("severity") orelse json.null_value).asInt() orelse 0,
                .message = (d.get("message") orelse json.null_value).asStr() orelse "",
            });
        }
        return out.items;
    }

    pub fn hover(w: *Workspace, name: []const u8, p: Pos) !?[]const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/hover", try w.posParams(name, p));
        const c = v.get("contents") orelse return null;
        return (c.get("value") orelse return null).asStr();
    }

    fn location(v: Value) ?Location {
        if (v == .null) return null;
        return .{
            .uri = (v.get("uri") orelse return null).asStr() orelse return null,
            .line = (v.path(&.{ "range", "start", "line" }) orelse return null).asInt() orelse return null,
            .col = (v.path(&.{ "range", "start", "character" }) orelse return null).asInt() orelse return null,
        };
    }

    pub fn definition(w: *Workspace, name: []const u8, p: Pos) !?Location {
        return location(try w.server.dispatchPublic(w.a(), "textDocument/definition", try w.posParams(name, p)));
    }

    pub fn implementation(w: *Workspace, name: []const u8, p: Pos) !?Location {
        return location(try w.server.dispatchPublic(w.a(), "textDocument/implementation", try w.posParams(name, p)));
    }

    pub fn references(w: *Workspace, name: []const u8, p: Pos) ![]const Location {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/references", try w.posParams(name, p));
        var out: std.ArrayList(Location) = .empty;
        for (v.items()) |item| if (location(item)) |l| try out.append(w.a(), l);
        return out.items;
    }

    /// The edits of a rename, over all files
    pub fn rename(w: *Workspace, name: []const u8, p: Pos, new_name: []const u8) ![]const Edit {
        const params = try json.from(w.a(), .{
            .textDocument = .{ .uri = try w.uri(name) },
            .position = .{ .line = p.line, .character = p.col },
            .newName = new_name,
        });
        const v = try w.server.dispatchPublic(w.a(), "textDocument/rename", params);
        var out: std.ArrayList(Edit) = .empty;
        const changes = v.get("changes") orelse return &.{};
        if (changes != .object) return &.{};
        for (changes.object.entries.items) |entry| {
            for (entry.value.items()) |e| {
                try out.append(w.a(), .{
                    .uri = entry.key,
                    .line = (e.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse -1,
                    .start = (e.path(&.{ "range", "start", "character" }) orelse json.null_value).asInt() orelse -1,
                    .end = (e.path(&.{ "range", "end", "character" }) orelse json.null_value).asInt() orelse -1,
                    .new_text = (e.get("newText") orelse json.null_value).asStr() orelse "",
                });
            }
        }
        return out.items;
    }

    /// Labels of the completion items
    pub fn completion(w: *Workspace, name: []const u8, p: Pos) ![]const []const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/completion", try w.posParams(name, p));
        var out: std.ArrayList([]const u8) = .empty;
        for (v.items()) |item| try out.append(w.a(), (item.get("label") orelse json.null_value).asStr() orelse "");
        return out.items;
    }

    pub const Signature = struct { label: []const u8, active: i64 };

    pub fn signature(w: *Workspace, name: []const u8, p: Pos) !?Signature {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/signatureHelp", try w.posParams(name, p));
        if (v == .null) return null;
        const sigs = (v.get("signatures") orelse return null).items();
        if (sigs.len == 0) return null;
        return .{
            .label = (sigs[0].get("label") orelse json.null_value).asStr() orelse "",
            .active = (v.get("activeParameter") orelse json.null_value).asInt() orelse -1,
        };
    }

    /// Names of the symbols of a document
    pub fn documentSymbols(w: *Workspace, name: []const u8) ![]const []const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/documentSymbol", try w.docParams(name));
        var out: std.ArrayList([]const u8) = .empty;
        for (v.items()) |s| try out.append(w.a(), (s.get("name") orelse json.null_value).asStr() orelse "");
        return out.items;
    }

    /// Names of the workspace symbols matching `query`
    pub fn workspaceSymbols(w: *Workspace, query: []const u8) ![]const []const u8 {
        const v = try w.request("workspace/symbol", .{ .query = query });
        var out: std.ArrayList([]const u8) = .empty;
        for (v.items()) |s| try out.append(w.a(), (s.get("name") orelse json.null_value).asStr() orelse "");
        return out.items;
    }

    // ---- expectations -------------------------------------------------

    /// No diagnostics at all in `name`
    pub fn expectNoDiagnostics(w: *Workspace, name: []const u8) !void {
        const ds = try w.diagnostics(name);
        if (ds.len > 0) return unmet("{s}: expected no diagnostics, got {d}: line {d}: {s}", .{ name, ds.len, ds[0].line + 1, ds[0].message });
    }

    /// No diagnostic in `name` whose message contains `fragment`
    pub fn expectNoDiagnosticLike(w: *Workspace, name: []const u8, fragment: []const u8) !void {
        for (try w.diagnostics(name)) |d| {
            if (std.mem.indexOf(u8, d.message, fragment) != null)
                return unmet("{s}: unexpected diagnostic at line {d}: {s}", .{ name, d.line + 1, d.message });
        }
    }

    /// The hover text at `p` contains `fragment`
    pub fn expectHoverContains(w: *Workspace, name: []const u8, p: Pos, fragment: []const u8) !void {
        const h = (try w.hover(name, p)) orelse return unmet("{s}:{d}:{d}: no hover, expected one containing '{s}'", .{ name, p.line + 1, p.col, fragment });
        if (std.mem.indexOf(u8, h, fragment) == null)
            return unmet("{s}:{d}:{d}: hover does not contain '{s}': {s}", .{ name, p.line + 1, p.col, fragment, h });
    }
};
