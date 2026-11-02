//! Linters zfls runs besides the compiler (compile.zig): fortitude, which
//! reads a file's text on stdin, and Codee (`codee checks`, a commercial
//! tool), which reads the file as saved. They run on a thread of their own
//! when a file is opened and saved, fortitude also while it is edited
//! (`fortitude_on_change`), and their findings are published with zfls's
//! diagnostics (compile.publishFrom). fortitude's fixes are quick fixes,
//! and the source action `source.fixAll.fortitude` applies the safe ones.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const compilers = @import("../compilers.zig");
const compile = @import("compile.zig");

const Value = json.Value;
const srv = @import("../server.zig");
const Server = srv.Server;

const fortitude_timeout_s = 30;
const codee_timeout_s = 120;
/// How to install fortitude, for the message when it is missing
const fortitude_install = "pip install fortitude-lint";

const Tool = enum { fortitude, codee };

const Job = struct {
    arena: std.heap.ArenaAllocator,
    tool: Tool,
    uri: []const u8,
    path: []const u8,
    /// The text, on fortitude's stdin
    text: []const u8 = "",
    argv: []const []const u8,
    cwd: []const u8,
    /// Not run before this time (the awake clock)
    not_before: i96 = 0,
};

/// The thread that runs the linters, and its queue of jobs
pub const Worker = struct {
    server: *Server,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(*Job) = .empty,
    stopping: bool = false,
    thread: ?std.Thread = null,
    /// fortitude's last output for each URI (its JSON), for the fixes of
    /// its problems; keys and values owned by `server.gpa`, under `mutex`
    outputs: std.StringHashMapUnmanaged([]u8) = .empty,
    /// A missing linter is reported once
    reported_missing: [2]bool = .{ false, false },

    fn run(w: *Worker) void {
        const io = w.server.io;
        while (true) {
            w.mutex.lockUncancelable(io);
            // the first job whose time has come, else a wait for one
            const job = while (true) {
                if (w.stopping) {
                    w.mutex.unlock(io);
                    return;
                }
                const now = Io.Clock.awake.now(io).nanoseconds;
                var wake: ?i96 = null;
                const due = for (w.queue.items, 0..) |j, i| {
                    if (j.not_before <= now) break i;
                    wake = if (wake) |t| @min(t, j.not_before) else j.not_before;
                } else null;
                if (due) |i| break w.queue.orderedRemove(i);
                if (wake) |t| {
                    w.cond.waitTimeout(io, &w.mutex, .{ .deadline = .{ .raw = .{ .nanoseconds = t }, .clock = .awake } }) catch {};
                } else w.cond.waitUncancelable(io, &w.mutex);
            };
            w.mutex.unlock(io);
            runJob(w, job) catch |e| w.server.log.err("{s} on {s}: {s}", .{ @tagName(job.tool), job.path, @errorName(e) });
            freeJob(w.server.gpa, job);
        }
    }
};

fn freeJob(gpa: Allocator, job: *Job) void {
    job.arena.deinit();
    gpa.destroy(job);
}

/// Stops the linters' thread, after the run it is in (server shutdown)
pub fn stop(self: *Server) void {
    const w = self.linters orelse return;
    const io = self.io;
    w.mutex.lockUncancelable(io);
    w.stopping = true;
    for (w.queue.items) |job| freeJob(self.gpa, job);
    w.queue.clearRetainingCapacity();
    w.cond.signal(io);
    w.mutex.unlock(io);
    if (w.thread) |t| t.join();
    w.queue.deinit(self.gpa);
    var it = w.outputs.iterator();
    while (it.next()) |e| {
        self.gpa.free(e.key_ptr.*);
        self.gpa.free(e.value_ptr.*);
    }
    w.outputs.deinit(self.gpa);
    self.gpa.destroy(w);
    self.linters = null;
}

/// The executable of a linter: its `*_path` setting, a file or the
/// directory that holds it (a path relative to the root), else its name,
/// looked for on the PATH
fn executable(self: *Server, a: Allocator, tool: Tool) ![]const u8 {
    const configured = std.mem.trim(u8, switch (tool) {
        .fortitude => self.s.fortitude_path,
        .codee => self.s.codee_path,
    } orelse "", " ");
    if (configured.len == 0) return @tagName(tool);
    const has_dir = std.mem.findAny(u8, configured, "/\\") != null;
    const p = if (has_dir and !std.Io.Dir.path.isAbsolute(configured)) try paths.join(a, &.{ self.root_path, configured }) else configured;
    if (!paths.isDir(self.io, p)) return p;
    const is_windows = @import("builtin").target.os.tag == .windows;
    return paths.join(a, &.{ p, if (is_windows) try a.print("{s}.exe", .{@tagName(tool)}) else @tagName(tool) });
}

/// fortitude's arguments for the text of `file` on stdin, `extra` first
fn fortitudeArgs(a: Allocator, exe: []const u8, extra: []const []const u8, user: []const []const u8, file: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ exe, "check", "--output-format", "json" });
    try argv.appendSlice(a, extra);
    try argv.appendSlice(a, user);
    try argv.appendSlice(a, &.{ "--stdin-filename", file, "-" });
    return argv.items;
}

/// `codee checks` for `file`: `--json`, the user's arguments, then the
/// file, unless they name it as `${file}` (before `--` and a compile
/// command, for instance)
fn codeeArgs(a: Allocator, exe: []const u8, user: []const []const u8, file: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ exe, "checks", "--json" });
    var named = false;
    for (user) |arg| {
        if (std.mem.find(u8, arg, "${file}") != null) named = true;
        try argv.append(a, try std.mem.replaceOwned(u8, a, arg, "${file}", file));
    }
    if (!named) try argv.append(a, file);
    return argv.items;
}

/// Queues the linters' runs of a workspace file, replacing those of the
/// same file that have not started
pub fn check(self: *Server, a: Allocator, uri: []const u8, path: []const u8, trigger: compile.Trigger) !void {
    if (!self.s.fortitude and !self.s.codee) return;
    const file = self.workspace.get(path) orelse return;
    if (self.s.fortitude and (trigger != .change or self.s.fortitude_on_change)) {
        const job = try newJob(self, .fortitude, uri, path);
        errdefer freeJob(self.gpa, job);
        const ja = job.arena.allocator();
        job.text = try compile.editorText(ja, file);
        job.argv = try fortitudeArgs(ja, try ja.dupe(u8, try executable(self, a, .fortitude)), &.{}, try dupeAll(ja, self.s.fortitude_args.slice()), job.path);
        if (trigger == .change) job.not_before = Io.Clock.awake.now(self.io).nanoseconds + @as(i96, @max(0, self.s.fortitude_change_delay)) * std.time.ns_per_ms;
        try enqueue(self, job);
    }
    if (self.s.codee and trigger != .change) {
        const job = try newJob(self, .codee, uri, path);
        errdefer freeJob(self.gpa, job);
        const ja = job.arena.allocator();
        job.argv = try codeeArgs(ja, try ja.dupe(u8, try executable(self, a, .codee)), try dupeAll(ja, self.s.codee_args.slice()), job.path);
        try enqueue(self, job);
    }
}

fn newJob(self: *Server, tool: Tool, uri: []const u8, path: []const u8) !*Job {
    const job = try self.gpa.create(Job);
    job.arena = .init(self.gpa);
    errdefer freeJob(self.gpa, job);
    const ja = job.arena.allocator();
    // their configuration (fpm.toml, fortitude.toml) is found from the root
    job.* = .{ .arena = job.arena, .tool = tool, .uri = try ja.dupe(u8, uri), .path = try ja.dupe(u8, path), .argv = &.{}, .cwd = try ja.dupe(u8, self.root_path) };
    return job;
}

fn dupeAll(a: Allocator, xs: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

fn enqueue(self: *Server, job: *Job) !void {
    const w = self.linters orelse blk: {
        const w = try self.gpa.create(Worker);
        w.* = .{ .server = self };
        errdefer self.gpa.destroy(w);
        w.thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, Worker.run, .{w});
        self.linters = w;
        break :blk w;
    };
    const io = self.io;
    w.mutex.lockUncancelable(io);
    defer w.mutex.unlock(io);
    var i: usize = 0;
    while (i < w.queue.items.len) {
        const q = w.queue.items[i];
        if (q.tool == job.tool and std.mem.eql(u8, q.path, job.path)) {
            freeJob(self.gpa, w.queue.orderedRemove(i));
        } else i += 1;
    }
    try w.queue.append(self.gpa, job);
    w.cond.signal(io);
}

// --------------------------------------------------------------------------
// Running a program with its input on stdin

pub const Output = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

/// Runs `argv` in `cwd` with `input` on its stdin, to its end or for
/// `timeout_s` seconds
pub fn runWithInput(a: Allocator, io: Io, argv: []const []const u8, cwd: []const u8, input: []const u8, timeout_s: i64) !Output {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);
    // the input first: these programs read it all before they write
    child.stdin.?.writeStreamingAll(io, input) catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } };
    while (reader.fill(64, timeout)) |_| {} else |e| switch (e) {
        error.EndOfStream => {},
        else => |err| return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1) };
}

// --------------------------------------------------------------------------
// On the linters' thread

fn runJob(w: *Worker, job: *Job) !void {
    const self = w.server;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const timeout: i64 = switch (job.tool) {
        .fortitude => fortitude_timeout_s,
        .codee => codee_timeout_s,
    };
    self.log.debug("{s}: {s} (in {s})", .{ @tagName(job.tool), try std.mem.join(a, " ", job.argv), job.cwd });
    const out = runWithInput(a, self.io, job.argv, job.cwd, job.text, timeout) catch |e| switch (e) {
        error.FileNotFound => {
            const i = @backingInt(job.tool);
            if (!w.reported_missing[i]) {
                w.reported_missing[i] = true;
                self.postMessage(a, switch (job.tool) {
                    .fortitude => try a.print("fortitude: {s} was not found; install it with `{s}`, or set fortitude_path to it", .{ job.argv[0], fortitude_install }),
                    .codee => try a.print("codee: {s} was not found; set codee_path to it", .{job.argv[0]}),
                }, 2);
            }
            return;
        },
        else => return e,
    };
    switch (job.tool) {
        .fortitude => {
            const problems = parseFortitude(a, out.stdout) orelse {
                self.log.warn("fortitude failed on {s}: {s}", .{ job.path, std.mem.trim(u8, out.stderr, " \r\n") });
                return;
            };
            {
                // kept for the fixes
                w.mutex.lockUncancelable(self.io);
                defer w.mutex.unlock(self.io);
                const copy = try self.gpa.dupe(u8, out.stdout);
                const gop = try w.outputs.getOrPut(self.gpa, job.uri);
                if (gop.found_existing) self.gpa.free(gop.value_ptr.*) else gop.key_ptr.* = try self.gpa.dupe(u8, job.uri);
                gop.value_ptr.* = copy;
            }
            const lines = try compile.splitLines(a, job.text);
            var diags: std.ArrayList(lsp.Diagnostic) = .empty;
            for (problems) |p| try diags.append(a, try fortitudeDiagnostic(a, p, lines));
            try compile.publishFrom(self, a, .fortitude, job.uri, diags.items);
        },
        .codee => {
            const checks = parseCodee(a, out.stdout) orelse {
                self.log.warn("codee: no report for {s}: {s}", .{ job.path, std.mem.trim(u8, if (out.stderr.len > 0) out.stderr else out.stdout, " \r\n") });
                return;
            };
            const text = Io.Dir.cwd().readFileAlloc(self.io, job.path, a, .limited(64 * 1024 * 1024)) catch "";
            const lines = try compile.splitLines(a, text);
            const here = try compile.comparable(a, job.cwd, job.path);
            var diags: std.ArrayList(lsp.Diagnostic) = .empty;
            for (checks) |c| {
                if (!std.mem.eql(u8, try compile.comparable(a, job.cwd, c.file), here)) continue;
                try diags.append(a, .{
                    .range = compile.rangeAt(lines, c.line, c.column, null, null),
                    .message = c.message,
                    .severity = c.severity.lsp(),
                    .code = c.code,
                    .codeDescription = if (c.url) |u| .{ .href = u } else null,
                    .source = "codee",
                });
            }
            try compile.publishFrom(self, a, .codee, job.uri, diags.items);
        },
    }
}

// --------------------------------------------------------------------------
// fortitude

const Position = struct { line: usize, character: usize };
const Span = struct { start: Position, end: Position };
const Edit = struct { span: Span, content: []const u8 };

const Fix = struct {
    message: []const u8,
    /// `safe`, `unsafe` or `display-only`
    applicability: []const u8,
    edits: []const Edit,
};

const Problem = struct {
    /// The rule's code, `C001`
    code: []const u8,
    message: []const u8,
    url: ?[]const u8 = null,
    span: Span,
    fix: ?Fix = null,
};

/// A 1-based `{row, column}` of fortitude's, 0-based
fn position(v: ?Value) ?Position {
    const loc = v orelse return null;
    const row = json.int(json.get(loc, "row")) orelse return null;
    const col = json.int(json.get(loc, "column")) orelse return null;
    return .{ .line = @intCast(@max(0, row - 1)), .character = @intCast(@max(0, col - 1)) };
}

fn span(start: ?Value, end: ?Value) ?Span {
    const s = position(start) orelse return null;
    return .{ .start = s, .end = position(end) orelse s };
}

/// The problems of fortitude's JSON output; null when it is no JSON array
/// (fortitude failed, and said why on stderr)
fn parseFortitude(a: Allocator, stdout: []const u8) ?[]const Problem {
    const raw = json.parse(a, stdout) catch return null;
    if (raw != .array) return null;
    var out: std.ArrayList(Problem) = .empty;
    for (raw.array.items) |item| {
        const s = span(json.get(item, "location"), json.get(item, "end_location")) orelse continue;
        const message = json.str(json.get(item, "message")) orelse continue;
        var p: Problem = .{ .code = json.str(json.get(item, "code")) orelse "", .message = message, .span = s };
        // fortitude's links have a doubled slash (`.io//en/`)
        if (json.str(json.get(item, "url"))) |u| p.url = undoubleSlashes(a, u) catch u;
        if (json.get(item, "fix")) |f| if (f == .object) {
            var edits: std.ArrayList(Edit) = .empty;
            for (json.items(json.get(f, "edits"))) |e| {
                const es = span(json.get(e, "location"), json.get(e, "end_location")) orelse continue;
                edits.append(a, .{ .span = es, .content = json.str(json.get(e, "content")) orelse continue }) catch return null;
            }
            if (edits.items.len > 0) p.fix = .{
                .message = json.str(json.get(f, "message")) orelse (a.print("Fix {s}", .{p.code}) catch return null),
                .applicability = json.str(json.get(f, "applicability")) orelse "unsafe",
                .edits = edits.items,
            };
        };
        out.append(a, p) catch return null;
    }
    return out.items;
}

/// `url` with each `//` after the scheme made `/`
fn undoubleSlashes(a: Allocator, url: []const u8) ![]const u8 {
    const scheme = (std.mem.find(u8, url, "://") orelse return url) + 3;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, url[0..scheme]);
    for (url[scheme..]) |c| {
        if (c == '/' and out.items.len > scheme and out.items[out.items.len - 1] == '/') continue;
        try out.append(a, c);
    }
    return out.items;
}

/// A character offset of fortitude's in `line`, in UTF-16 code units
fn utf16Of(line: []const u8, chars: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    var units: usize = 0;
    while (i < line.len and n < chars) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return units + (chars - n);
}

fn toRange(s: Span, lines: []const []const u8) lsp.Range {
    const sl = if (s.start.line < lines.len) lines[s.start.line] else "";
    const el = if (s.end.line < lines.len) lines[s.end.line] else "";
    return .{
        .start = .{ .line = s.start.line, .character = utf16Of(sl, s.start.character) },
        .end = .{ .line = s.end.line, .character = utf16Of(el, s.end.character) },
    };
}

fn fortitudeDiagnostic(a: Allocator, p: Problem, lines: []const []const u8) !lsp.Diagnostic {
    _ = a;
    return .{
        .range = toRange(p.span, lines),
        .message = p.message,
        .severity = compilers.Severity.warning.lsp(),
        .code = p.code,
        .codeDescription = if (p.url) |u| .{ .href = u } else null,
        .source = "fortitude",
    };
}

fn wants(only: ?[]const []const u8, kind: []const u8) bool {
    const kinds = only orelse return false;
    for (kinds) |k| if (std.mem.startsWith(u8, k, kind) or std.mem.startsWith(u8, kind, k)) return true;
    return false;
}

/// fortitude's code actions for `range` of `uri`: the fixes of its problems
/// there (quick fixes), and, when asked for, the safe ones of the whole file
/// (`source.fixAll.fortitude`, from `fortitude check --fix-only`)
pub fn addActions(self: *Server, a: Allocator, uri: []const u8, range: lsp.Range, only: ?[]const []const u8, out: *std.ArrayList(lsp.CodeAction)) !void {
    if (!self.s.fortitude) return;
    const w = self.linters orelse return;
    const stdout = blk: {
        w.mutex.lockUncancelable(self.io);
        defer w.mutex.unlock(self.io);
        break :blk try a.dupe(u8, w.outputs.get(uri) orelse return);
    };
    const problems = parseFortitude(a, stdout) orelse return;
    const file = (try self.fileFromUri(a, uri)) orelse return;
    const text = try compile.editorText(a, file);
    const lines = try compile.splitLines(a, text);
    var any_safe = false;
    for (problems) |p| {
        const fix = p.fix orelse continue;
        if (std.mem.eql(u8, fix.applicability, "safe")) any_safe = true;
        if (std.mem.eql(u8, fix.applicability, "display-only")) continue;
        if (only != null and !wants(only, "quickfix")) continue;
        // the problems on the lines asked about
        if (p.span.end.line < range.start.line or p.span.start.line > range.end.line) continue;
        const unsafe = !std.mem.eql(u8, fix.applicability, "safe");
        var edits: std.ArrayList(lsp.TextEdit) = .empty;
        for (fix.edits) |e| try edits.append(a, .{ .range = toRange(e.span, lines), .newText = e.content });
        try out.append(a, .{
            .title = try a.print("{s} (fortitude {s}{s})", .{ fix.message, p.code, if (unsafe) ", unsafe" else "" }),
            .kind = "quickfix",
            .edit = try oneFile(a, uri, edits.items),
            .diagnostics = try a.dupe(lsp.Diagnostic, &.{try fortitudeDiagnostic(a, p, lines)}),
            .isPreferred = !unsafe,
        });
    }
    if (any_safe and wants(only, "source.fixAll.fortitude")) {
        const fixed = try fixAll(self, a, file.path, text) orelse return;
        if (std.mem.eql(u8, fixed, text)) return;
        const last = lines.len -| 1;
        const whole: lsp.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = last, .character = toRange(.{ .start = .{ .line = last, .character = 0 }, .end = .{ .line = last, .character = std.unicode.utf8CountCodepoints(lines[last]) catch lines[last].len } }, lines).end.character } };
        try out.append(a, .{
            .title = "Fix all safe fortitude problems",
            .kind = "source.fixAll.fortitude",
            .edit = try oneFile(a, uri, try a.dupe(lsp.TextEdit, &.{.{ .range = whole, .newText = fixed }})),
            .diagnostics = &.{},
        });
    }
}

fn oneFile(a: Allocator, uri: []const u8, edits: []const lsp.TextEdit) !lsp.WorkspaceEdit {
    const files = try a.alloc(lsp.Changes.File, 1);
    files[0] = .{ .uri = uri, .edits = edits };
    return .{ .changes = .{ .files = files } };
}

/// The text with fortitude's safe fixes applied (`--fix-only`, on this
/// thread); null when fortitude failed
fn fixAll(self: *Server, a: Allocator, path: []const u8, text: []const u8) !?[]const u8 {
    const argv = try fortitudeArgs(a, try executable(self, a, .fortitude), &.{"--fix-only"}, self.s.fortitude_args.slice(), path);
    const out = runWithInput(a, self.io, argv, self.root_path, text, fortitude_timeout_s) catch |e| {
        self.log.warn("fortitude --fix-only on {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    if (!out.term.success()) {
        self.log.warn("fortitude --fix-only failed on {s}: {s}", .{ path, std.mem.trim(u8, out.stderr, " \r\n") });
        return null;
    }
    return out.stdout;
}

// --------------------------------------------------------------------------
// Codee

const Check = struct {
    code: []const u8,
    /// As Codee gives it, relative to its working directory or absolute
    file: []const u8,
    /// 1-based
    line: usize,
    column: usize,
    message: []const u8,
    severity: compilers.Severity,
    url: ?[]const u8,
};

/// The severity of a check from its kind: PWD (defects) are errors, PWR
/// (recommendations) warnings, RMK (remarks) hints, as in Codee's own
/// editor integrations
fn codeeSeverity(code: []const u8) compilers.Severity {
    if (std.mem.startsWith(u8, code, "PWD")) return .@"error";
    if (std.mem.startsWith(u8, code, "RMK")) return .hint;
    return .warning;
}

/// The page of a check in Codee's Open Catalog
fn checkUrl(a: Allocator, code: []const u8) !?[]const u8 {
    if (code.len != 6) return null;
    const kind = code[0..3];
    if (!std.mem.eql(u8, kind, "PWD") and !std.mem.eql(u8, kind, "PWR") and !std.mem.eql(u8, kind, "RMK")) return null;
    for (code[3..]) |c| if (!std.ascii.isDigit(c)) return null;
    return try a.print("https://open-catalog.codee.com/Checks/{s}/", .{code});
}

/// The checks of Codee's JSON output (`{"Checks": [{Check, Location
/// "file:line:column", Title, Suggestion}]}`, as Codee documents it for its
/// Neovim integration); null when it is not that. zfls has not been tested
/// with Codee, a commercial tool: this follows its documentation.
fn parseCodee(a: Allocator, output: []const u8) ?[]const Check {
    // anything Codee prints before its report (a banner, a license notice)
    const start = std.mem.findScalar(u8, output, '{') orelse return null;
    const data = json.parse(a, output[start..]) catch return null;
    const checks = json.get(data, "Checks") orelse return null;
    if (checks != .array) return null;
    var out: std.ArrayList(Check) = .empty;
    for (checks.array.items) |c| {
        const loc = json.str(json.get(c, "Location")) orelse continue;
        // FILE:LINE:COLUMN, the file perhaps with a drive letter's colon
        const c2 = std.mem.findScalarLast(u8, loc, ':') orelse continue;
        const c1 = std.mem.findScalarLast(u8, loc[0..c2], ':') orelse continue;
        const line = std.fmt.parseInt(usize, loc[c1 + 1 .. c2], 10) catch continue;
        const column = std.fmt.parseInt(usize, loc[c2 + 1 ..], 10) catch continue;
        const code = json.str(json.get(c, "Check")) orelse "";
        const title = std.mem.trim(u8, json.str(json.get(c, "Title")) orelse "", " \r\n");
        const suggestion = std.mem.trim(u8, json.str(json.get(c, "Suggestion")) orelse "", " \r\n");
        out.append(a, .{
            .code = code,
            .file = loc[0..c1],
            .line = line,
            .column = column,
            .message = if (suggestion.len > 0) (a.print("{s}\n{s}", .{ title, suggestion }) catch return null) else title,
            .severity = codeeSeverity(code),
            .url = checkUrl(a, code) catch return null,
        }) catch return null;
    }
    return out.items;
}

test "fortitude's arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try fortitudeArgs(arena.allocator(), "fortitude", &.{"--fix-only"}, &.{ "--select", "C" }, "/w/a.f90");
    const want = [_][]const u8{ "fortitude", "check", "--output-format", "json", "--fix-only", "--select", "C", "--stdin-filename", "/w/a.f90", "-" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "fortitude's problems and fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out =
        \\[{"code":"C001","name":"implicit-typing","message":"program missing 'implicit none'",
        \\  "url":"https://fortitude.readthedocs.io//en/stable/rules/implicit-typing",
        \\  "location":{"row":1,"column":1},"end_location":{"row":1,"column":10},
        \\  "fix":{"message":"Insert `implicit none`","applicability":"unsafe",
        \\    "edits":[{"content":"  implicit none\n","location":{"row":2,"column":1},"end_location":{"row":2,"column":1}}]}},
        \\ {"code":"S061","message":"no fix","location":{"row":3,"column":2},"end_location":null,"fix":null}]
    ;
    const ps = parseFortitude(a, out).?;
    try std.testing.expectEqual(2, ps.len);
    try std.testing.expectEqualStrings("C001", ps[0].code);
    try std.testing.expectEqualStrings("https://fortitude.readthedocs.io/en/stable/rules/implicit-typing", ps[0].url.?);
    try std.testing.expectEqual(0, ps[0].span.start.line);
    try std.testing.expectEqual(9, ps[0].span.end.character);
    try std.testing.expectEqualStrings("unsafe", ps[0].fix.?.applicability);
    try std.testing.expectEqual(1, ps[0].fix.?.edits[0].span.start.line);
    try std.testing.expectEqual(ps[1].span.start, ps[1].span.end);
    try std.testing.expect(ps[1].fix == null);
    try std.testing.expect(parseFortitude(a, "error: no such file") == null);
}

test "fortitude's columns in UTF-16" {
    try std.testing.expectEqual(4, utf16Of("a😀b", 3));
    try std.testing.expectEqual(2, utf16Of("ab", 2));
    try std.testing.expectEqual(5, utf16Of("ab", 5));
}

test "codee's arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try codeeArgs(a, "codee", &.{"--verbose"}, "/w/a.f90");
    try std.testing.expectEqualStrings("/w/a.f90", plain[plain.len - 1]);
    const named = try codeeArgs(a, "codee", &.{ "${file}", "--", "gfortran", "-c", "${file}" }, "/w/a.f90");
    try std.testing.expectEqual(8, named.len);
    try std.testing.expectEqualStrings("/w/a.f90", named[3]);
    try std.testing.expectEqualStrings("/w/a.f90", named[7]);
}

test "codee's checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out =
        \\Codee 2025.1 (license notice)
        \\{"Checks":[{"Check":"PWR068","Location":"C:/w/a.f90:12:5","Title":"Encapsulate external procedures","Suggestion":"Move it into a module"},
        \\ {"Check":"PWD002","Location":"a.f90:3:1","Title":"Unprotected multithreading reduction"},
        \\ {"Check":"RMK010","Location":"no location"}]}
    ;
    const cs = parseCodee(a, out).?;
    try std.testing.expectEqual(2, cs.len);
    try std.testing.expectEqualStrings("C:/w/a.f90", cs[0].file);
    try std.testing.expectEqual(12, cs[0].line);
    try std.testing.expectEqual(5, cs[0].column);
    try std.testing.expectEqualStrings("Encapsulate external procedures\nMove it into a module", cs[0].message);
    try std.testing.expectEqual(compilers.Severity.warning, cs[0].severity);
    try std.testing.expectEqualStrings("https://open-catalog.codee.com/Checks/PWR068/", cs[0].url.?);
    try std.testing.expectEqual(compilers.Severity.@"error", cs[1].severity);
    try std.testing.expect(parseCodee(a, "not json") == null);
}
