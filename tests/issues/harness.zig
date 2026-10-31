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

/// The tracker an issue number belongs to
pub const Repo = enum {
    /// fortran-lang/fortls
    fortls,
    /// hansec/fortran-language-server, which fortls was forked from
    hansec,
    /// fortran-lang/vscode-fortran-support (Modern Fortran), the VS Code
    /// extension that runs fortls
    modern_fortran,
};

/// Evaluate the outcome `result` of a test's expectations for fortls issue
/// `issue` (see the module comment).
pub fn check(issue: u32, status: Status, result: anyerror!void) !void {
    return checkIn(.fortls, issue, status, result);
}

/// `check` for an issue of another tracker
pub fn checkIn(repo: Repo, issue: u32, status: Status, result: anyerror!void) !void {
    const why = if (result) |_| "passes" else |e| if (e == error.Unmet) note() else @errorName(e);
    record(repo, issue, status, why);
    switch (status) {
        .fixed => result catch |e| {
            std.debug.print("\n{s} issue #{d} is not handled correctly: {s}\n", .{ @tagName(repo), issue, why });
            return e;
        },
        .known_failure => if (result) |_| {
            std.debug.print("\n{s} issue #{d} is marked as a known failure but now passes: mark it .fixed\n", .{ @tagName(repo), issue });
            return error.UnexpectedlyFixed;
        } else |_| {},
    }
}

// What each test found, for the table in README.md: written to
// .zig-cache/issue-tests.txt as the tests run
var report: std.ArrayList(u8) = .empty;

fn record(repo: Repo, issue: u32, status: Status, why: []const u8) void {
    const alloc = std.heap.page_allocator;
    const prefix = if (repo == .fortls) "" else @tagName(repo);
    report.print(alloc, "{s}#{d}\t{s}\t{s}\n", .{ prefix, issue, @tagName(status), why }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/issue-tests.txt", .data = report.items }) catch {};
}

// --------------------------------------------------------------------------
// Results

pub const Pos = struct { line: i64, col: i64 };

pub const Diagnostic = struct { line: i64, severity: i64, message: []const u8, code: []const u8 = "" };

pub const Location = struct { uri: []const u8, line: i64, col: i64 };

pub const Edit = struct { uri: []const u8, line: i64, start: i64, end: i64, new_text: []const u8 };

pub const File = struct { name: []const u8, text: []const u8 };

/// A semantic token: 0-based line, its text and its type (`variable`, ...)
pub const Token = struct { line: i64, text: []const u8, type: []const u8 };

/// A folding range: 0-based first and last lines
pub const Fold = struct { start: i64, end: i64 };

pub const Link = struct { name: []const u8, target: []const u8 };

pub const Options = struct {
    settings: Settings = .{},
    /// symbolic links to create next to the files (a test is skipped where
    /// the platform does not allow them)
    links: []const Link = &.{},
    /// directories to create without any permission (a test is skipped
    /// where that is not possible, e.g. on Windows or as root)
    unreadable: []const []const u8 = &.{},
    /// `--pp_defs`
    pp_defs: []const zfls.settings.PpDef = &.{},
    /// `--external_modules`
    external_modules: []const []const u8 = &.{},
    /// `--diagnostic_severity`
    diagnostic_severity: []const zfls.settings.DiagLevel = &.{},
    /// the client takes a tree of document symbols (as VS Code does)
    hierarchical_symbols: bool = false,
    /// the `workDoneToken` of the initialize request
    progress_token: ?i64 = null,
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
    unreadable: []const []const u8,
    /// the notifications the server sent (JSON texts)
    sent: std.ArrayList([]const u8) = .empty,

    fn collect(ctx: ?*anyopaque, body: []const u8) void {
        const w: *Workspace = @ptrCast(@alignCast(ctx.?));
        const aa = w.arena.allocator();
        w.sent.append(aa, aa.dupe(u8, body) catch return) catch return;
    }

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
        w.unreadable = &.{};
        w.sent = .empty;
        for (files) |f| {
            if (std.fs.path.dirname(f.name)) |d| try w.tmp.dir.createDirPath(io, d);
            try w.tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = f.text });
        }
        for (opts.links) |l| w.tmp.dir.symLink(io, l.target, l.name, .{}) catch return error.SkipZigTest;
        for (opts.unreadable) |d| {
            if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
            try w.tmp.dir.createDirPath(io, d);
            w.tmp.dir.setFilePermissions(io, d, @fromBackingInt(@intCast(0)), .{}) catch return error.SkipZigTest;
            // root reads it anyway
            if (w.tmp.dir.openDir(io, d, .{ .iterate = true })) |opened| {
                opened.close(io);
                w.tmp.dir.setFilePermissions(io, d, .default_dir, .{}) catch {};
                return error.SkipZigTest;
            } else |_| {}
        }
        w.unreadable = opts.unreadable;
        w.root = try aa.dupe(u8, try w.tmp.dir.realPathFileAlloc(io, ".", aa));
        w.log = Logger.init(io);
        w.log.stderr_level = .off;
        var settings = opts.settings;
        for (opts.pp_defs) |d| try settings.pp_defs.append(aa, d);
        for (opts.external_modules) |m| try settings.external_modules.add(aa, m);
        for (opts.diagnostic_severity) |d| try settings.diagnostic_severity.append(aa, d);
        w.server = try Server.create(gpa, io, settings, &w.log);
        errdefer w.server.destroy();
        w.server.sink = .{ .ctx = w, .sendFn = collect };
        _ = try w.server.dispatchPublic(aa, "initialize", try json.from(aa, .{
            .rootPath = w.root,
            .capabilities = .{ .textDocument = .{ .documentSymbol = .{
                .hierarchicalDocumentSymbolSupport = opts.hierarchical_symbols,
            } } },
            .workDoneToken = opts.progress_token,
        }));
        return w;
    }

    pub fn deinit(w: *Workspace) void {
        for (w.unreadable) |d| w.tmp.dir.setFilePermissions(io, d, .default_dir, .{}) catch {};
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
        for (json.items(v)) |d| {
            try out.append(w.a(), .{
                .line = json.int(json.path(d, &.{ "range", "start", "line" })) orelse -1,
                .severity = json.int(json.get(d, "severity")) orelse 0,
                .message = json.str(json.get(d, "message")) orelse "",
                .code = json.str(json.get(d, "code")) orelse "",
            });
        }
        return out.items;
    }

    pub fn hover(w: *Workspace, name: []const u8, p: Pos) !?[]const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/hover", try w.posParams(name, p));
        return json.str(json.path(v, &.{ "contents", "value" }));
    }

    fn location(v: Value) ?Location {
        if (v == .null) return null;
        return .{
            .uri = json.str(json.get(v, "uri")) orelse return null,
            .line = json.int(json.path(v, &.{ "range", "start", "line" })) orelse return null,
            .col = json.int(json.path(v, &.{ "range", "start", "character" })) orelse return null,
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
        for (json.items(v)) |item| if (location(item)) |l| try out.append(w.a(), l);
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
        const changes = json.get(v, "changes") orelse return &.{};
        if (changes != .object) return &.{};
        for (changes.object.keys(), changes.object.values()) |file_uri, edits| {
            for (json.items(edits)) |e| {
                try out.append(w.a(), .{
                    .uri = file_uri,
                    .line = json.int(json.path(e, &.{ "range", "start", "line" })) orelse -1,
                    .start = json.int(json.path(e, &.{ "range", "start", "character" })) orelse -1,
                    .end = json.int(json.path(e, &.{ "range", "end", "character" })) orelse -1,
                    .new_text = json.str(json.get(e, "newText")) orelse "",
                });
            }
        }
        return out.items;
    }

    /// Labels of the completion items
    pub fn completion(w: *Workspace, name: []const u8, p: Pos) ![]const []const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/completion", try w.posParams(name, p));
        var out: std.ArrayList([]const u8) = .empty;
        for (json.items(v)) |item| try out.append(w.a(), json.str(json.get(item, "label")) orelse "");
        return out.items;
    }

    /// A completion item and the text its additional edits insert (the
    /// first one's), with the 0-based line it goes before
    pub const Item = struct { label: []const u8, detail: []const u8, added: ?[]const u8 = null, added_line: i64 = -1 };

    pub fn completionItems(w: *Workspace, name: []const u8, p: Pos) ![]const Item {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/completion", try w.posParams(name, p));
        var out: std.ArrayList(Item) = .empty;
        for (json.items(v)) |item| {
            var it: Item = .{ .label = json.str(json.get(item, "label")) orelse "", .detail = json.str(json.get(item, "detail")) orelse "" };
            const edits = json.items(json.get(item, "additionalTextEdits") orelse .null);
            if (edits.len > 0) {
                it.added = json.str(json.get(edits[0], "newText"));
                it.added_line = json.int(json.path(edits[0], &.{ "range", "start", "line" })) orelse -1;
            }
            try out.append(w.a(), it);
        }
        return out.items;
    }

    /// A code action: its title, the text of its first edit and the 0-based
    /// line that edit starts on
    pub const Action = struct { title: []const u8, new_text: []const u8, line: i64 };

    pub fn codeActions(w: *Workspace, name: []const u8, line: i64) ![]const Action {
        const v = try w.request("textDocument/codeAction", .{
            .textDocument = .{ .uri = try w.uri(name) },
            .range = .{ .start = .{ .line = line, .character = 0 }, .end = .{ .line = line, .character = 0 } },
        });
        var out: std.ArrayList(Action) = .empty;
        for (json.items(v)) |act| {
            const files = json.get(json.path(act, &.{ "edit", "changes" }) orelse .null, try w.uri(name)) orelse .null;
            const edits = json.items(files);
            try out.append(w.a(), .{
                .title = json.str(json.get(act, "title")) orelse "",
                .new_text = if (edits.len > 0) json.str(json.get(edits[0], "newText")) orelse "" else "",
                .line = if (edits.len > 0) json.int(json.path(edits[0], &.{ "range", "start", "line" })) orelse -1 else -1,
            });
        }
        return out.items;
    }

    /// What prepareRename answers: the range of the name (one line) and the
    /// placeholder
    pub const Prepared = struct { line: i64, start: i64, end: i64, placeholder: []const u8 };

    pub fn prepareRename(w: *Workspace, name: []const u8, p: Pos) !?Prepared {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/prepareRename", try w.posParams(name, p));
        if (v == .null) return null;
        return .{
            .line = json.int(json.path(v, &.{ "range", "start", "line" })) orelse -1,
            .start = json.int(json.path(v, &.{ "range", "start", "character" })) orelse -1,
            .end = json.int(json.path(v, &.{ "range", "end", "character" })) orelse -1,
            .placeholder = json.str(json.get(v, "placeholder")) orelse "",
        };
    }

    /// A selection range: its start and end lines and columns
    pub const Sel = struct { sl: i64, sc: i64, el: i64, ec: i64 };

    /// The selection ranges at a position, innermost first
    pub fn selectionRanges(w: *Workspace, name: []const u8, p: Pos) ![]const Sel {
        const v = try w.request("textDocument/selectionRange", .{
            .textDocument = .{ .uri = try w.uri(name) },
            .positions = &[_]struct { line: i64, character: i64 }{.{ .line = p.line, .character = p.col }},
        });
        var out: std.ArrayList(Sel) = .empty;
        var node: ?Value = if (json.items(v).len > 0) json.items(v)[0] else null;
        while (node) |n| {
            try out.append(w.a(), .{
                .sl = json.int(json.path(n, &.{ "range", "start", "line" })) orelse -1,
                .sc = json.int(json.path(n, &.{ "range", "start", "character" })) orelse -1,
                .el = json.int(json.path(n, &.{ "range", "end", "line" })) orelse -1,
                .ec = json.int(json.path(n, &.{ "range", "end", "character" })) orelse -1,
            });
            node = json.get(n, "parent");
        }
        return out.items;
    }

    /// A document link: the line and columns of its text, and its target
    pub const DocLink = struct { line: i64, start: i64, end: i64, target: []const u8 };

    pub fn documentLinks(w: *Workspace, name: []const u8) ![]const DocLink {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/documentLink", try w.docParams(name));
        var out: std.ArrayList(DocLink) = .empty;
        for (json.items(v)) |l| try out.append(w.a(), .{
            .line = json.int(json.path(l, &.{ "range", "start", "line" })) orelse -1,
            .start = json.int(json.path(l, &.{ "range", "start", "character" })) orelse -1,
            .end = json.int(json.path(l, &.{ "range", "end", "character" })) orelse -1,
            .target = json.str(json.get(l, "target")) orelse "",
        });
        return out.items;
    }

    /// The edits of `textDocument/onTypeFormatting` after typing `ch`:
    /// their start and end columns on the line, and new text
    pub const TypeEdit = struct { start: i64, end: i64, new_text: []const u8 };

    pub fn onTypeFormatting(w: *Workspace, name: []const u8, p: Pos, ch: []const u8) ![]const TypeEdit {
        const v = try w.request("textDocument/onTypeFormatting", .{
            .textDocument = .{ .uri = try w.uri(name) },
            .position = .{ .line = p.line, .character = p.col },
            .ch = ch,
        });
        var out: std.ArrayList(TypeEdit) = .empty;
        for (json.items(v)) |e| try out.append(w.a(), .{
            .start = json.int(json.path(e, &.{ "range", "start", "character" })) orelse -1,
            .end = json.int(json.path(e, &.{ "range", "end", "character" })) orelse -1,
            .new_text = json.str(json.get(e, "newText")) orelse "",
        });
        return out.items;
    }

    /// The call hierarchy item at a position (its JSON), or null
    pub fn prepareCallHierarchy(w: *Workspace, name: []const u8, p: Pos) !?Value {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/prepareCallHierarchy", try w.posParams(name, p));
        const items = json.items(v);
        return if (items.len > 0) items[0] else null;
    }

    /// The type hierarchy item at a position (its JSON), or null
    pub fn prepareTypeHierarchy(w: *Workspace, name: []const u8, p: Pos) !?Value {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/prepareTypeHierarchy", try w.posParams(name, p));
        const items = json.items(v);
        return if (items.len > 0) items[0] else null;
    }

    /// The names of the supertypes (`super`) or subtypes of a type item
    pub fn typeHierarchy(w: *Workspace, item: Value, super: bool) ![]const []const u8 {
        const v = try w.request(if (super) "typeHierarchy/supertypes" else "typeHierarchy/subtypes", .{ .item = item });
        var out: std.ArrayList([]const u8) = .empty;
        for (json.items(v)) |t| try out.append(w.a(), json.str(json.get(t, "name")) orelse "");
        return out.items;
    }

    /// The name of a call hierarchy item
    pub fn itemName(item: Value) []const u8 {
        return json.str(json.get(item, "name")) orelse "";
    }

    /// A call of the hierarchy: the other procedure, and how many call
    /// sites
    pub const Call = struct { name: []const u8, sites: usize };

    /// `callHierarchy/incomingCalls` (`incoming`) or `outgoingCalls`
    pub fn calls(w: *Workspace, item: Value, incoming: bool) ![]const Call {
        const method = if (incoming) "callHierarchy/incomingCalls" else "callHierarchy/outgoingCalls";
        const v = try w.request(method, .{ .item = item });
        var out: std.ArrayList(Call) = .empty;
        for (json.items(v)) |c| {
            const other = json.get(c, if (incoming) "from" else "to") orelse continue;
            try out.append(w.a(), .{ .name = json.str(json.get(other, "name")) orelse "", .sites = json.items(json.get(c, "fromRanges")).len });
        }
        return out.items;
    }

    /// An inlay hint: its 0-based line and column, and label
    pub const Hint = struct { line: i64, col: i64, label: []const u8 };

    pub fn inlayHints(w: *Workspace, name: []const u8) ![]const Hint {
        const v = try w.request("textDocument/inlayHint", .{
            .textDocument = .{ .uri = try w.uri(name) },
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 10000, .character = 0 } },
        });
        var out: std.ArrayList(Hint) = .empty;
        for (json.items(v)) |item| try out.append(w.a(), .{
            .line = json.int(json.path(item, &.{ "position", "line" })) orelse -1,
            .col = json.int(json.path(item, &.{ "position", "character" })) orelse -1,
            .label = json.str(json.get(item, "label")) orelse "",
        });
        return out.items;
    }

    /// The active signature's label (the first one's when none is active),
    /// the active parameter, and how many signatures there are
    pub const Signature = struct { label: []const u8, active: i64, count: usize = 1 };

    pub fn signature(w: *Workspace, name: []const u8, p: Pos) !?Signature {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/signatureHelp", try w.posParams(name, p));
        if (v == .null) return null;
        const sigs = json.items(json.get(v, "signatures"));
        if (sigs.len == 0) return null;
        const which: usize = @intCast(@min(json.int(json.get(v, "activeSignature")) orelse 0, @as(i64, @intCast(sigs.len - 1))));
        return .{
            .label = json.str(json.get(sigs[which], "label")) orelse "",
            .active = json.int(json.get(v, "activeParameter")) orelse -1,
            .count = sigs.len,
        };
    }

    /// Names of the symbols of a document
    pub fn documentSymbols(w: *Workspace, name: []const u8) ![]const []const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/documentSymbol", try w.docParams(name));
        var out: std.ArrayList([]const u8) = .empty;
        for (json.items(v)) |s| try out.append(w.a(), json.str(json.get(s, "name")) orelse "");
        return out.items;
    }

    /// The document symbols of a client with `hierarchical_symbols`, as
    /// paths from the outermost (`mod/proc/var`), parents before children
    pub fn symbolPaths(w: *Workspace, name: []const u8) ![]const []const u8 {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/documentSymbol", try w.docParams(name));
        var out: std.ArrayList([]const u8) = .empty;
        try w.appendSymbolPaths(v, "", &out);
        return out.items;
    }

    fn appendSymbolPaths(w: *Workspace, v: Value, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
        for (json.items(v)) |s| {
            const sym = json.str(json.get(s, "name")) orelse "";
            const p = if (prefix.len == 0) sym else try std.fmt.allocPrint(w.a(), "{s}/{s}", .{ prefix, sym });
            try out.append(w.a(), p);
            if (json.get(s, "children")) |c| try w.appendSymbolPaths(c, p, out);
        }
    }

    /// The folding ranges of a file, as 0-based `start-end` line pairs
    pub fn foldingRanges(w: *Workspace, name: []const u8) ![]const Fold {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/foldingRange", try w.docParams(name));
        var out: std.ArrayList(Fold) = .empty;
        for (json.items(v)) |f| try out.append(w.a(), .{
            .start = json.int(json.get(f, "startLine")) orelse -1,
            .end = json.int(json.get(f, "endLine")) orelse -1,
        });
        return out.items;
    }

    /// The semantic tokens of a file, decoded
    pub fn semanticTokens(w: *Workspace, name: []const u8) ![]const Token {
        const v = try w.server.dispatchPublic(w.a(), "textDocument/semanticTokens/full", try w.docParams(name));
        const data = json.items(json.get(v, "data"));
        var lines = std.mem.splitScalar(u8, w.text(name), '\n');
        var line_texts: std.ArrayList([]const u8) = .empty;
        while (lines.next()) |l| try line_texts.append(w.a(), l);
        var out: std.ArrayList(Token) = .empty;
        var line: i64 = 0;
        var col: i64 = 0;
        var i: usize = 0;
        while (i + 5 <= data.len) : (i += 5) {
            const dl = json.int(data[i]) orelse 0;
            const dc = json.int(data[i + 1]) orelse 0;
            const n: usize = @intCast(json.int(data[i + 2]) orelse 0);
            const t: usize = @intCast(json.int(data[i + 3]) orelse 0);
            if (dl != 0) {
                line += dl;
                col = dc;
            } else col += dc;
            const lt = if (line < line_texts.items.len) line_texts.items[@intCast(line)] else "";
            const s: usize = @min(lt.len, @as(usize, @intCast(col)));
            try out.append(w.a(), .{
                .line = line,
                .text = lt[s..@min(lt.len, s + n)],
                .type = if (t < zfls.semantic.legend.tokenTypes.len) zfls.semantic.legend.tokenTypes[t] else "?",
            });
        }
        return out.items;
    }

    /// Names of the workspace symbols matching `query`
    pub fn workspaceSymbols(w: *Workspace, query: []const u8) ![]const []const u8 {
        const v = try w.request("workspace/symbol", .{ .query = query });
        var out: std.ArrayList([]const u8) = .empty;
        for (json.items(v)) |s| try out.append(w.a(), json.str(json.get(s, "name")) orelse "");
        return out.items;
    }

    // ---- expectations -------------------------------------------------

    /// No diagnostics at all in `name`
    /// No diagnostic in `name`, besides the faded hints about names a
    /// fixture declares and does not use (`unused-name`)
    pub fn expectNoDiagnostics(w: *Workspace, name: []const u8) !void {
        var ds: std.ArrayList(Diagnostic) = .empty;
        for (try w.diagnostics(name)) |d| if (!std.mem.eql(u8, d.code, "unused-name")) try ds.append(w.a(), d);
        if (ds.items.len > 0) return unmet("{s}: expected no diagnostics, got {d}: line {d}: {s}", .{ name, ds.items.len, ds.items[0].line + 1, ds.items[0].message });
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
