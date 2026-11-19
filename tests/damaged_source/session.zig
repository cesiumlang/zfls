//! The server of tests/damaged_source.zig on the corpus, and the checks
//! of its answers: an in-process server (tests/issues/harness.zig) on the
//! files of the test corpus, the requests asked of each damaged version,
//! the ranges and positions checked in their results, and a watchdog
//! that stops a request that hangs.

const std = @import("std");
const zfls = @import("zfls");
const h = @import("../issues/harness.zig");
const json = zfls.json;
const Value = json.Value;
const Allocator = std.mem.Allocator;
const io = std.testing.io;
const gpa = std.testing.allocator;

const Source = struct { name: []const u8, text: []const u8 };

/// The sources damaged, as the workspace holds them
pub const corpus = [_]Source{
    .{ .name = "constructs.f90", .text = @embedFile("../fortran/constructs.f90") },
    .{ .name = "fixed_form.f", .text = @embedFile("../fortran/fixed_form.f") },
    .{ .name = "modules_types.f90", .text = @embedFile("../fortran/modules_types.f90") },
    .{ .name = "preprocessed.F90", .text = @embedFile("../fortran/preprocessed.F90") },
    .{ .name = "submodules.f90", .text = @embedFile("../fortran/submodules.f90") },
    .{ .name = "shapes.f90", .text = @embedFile("../compiler/shapes.f90") },
    .{ .name = "main.f90", .text = @embedFile("../compiler/main.f90") },
    .{ .name = "legacy.f", .text = @embedFile("../compiler/legacy.f") },
    .{ .name = "defines.F90", .text = @embedFile("../compiler/defines.F90") },
    .{ .name = "includes.f90", .text = @embedFile("../compiler/includes.f90") },
    .{ .name = "grid.f90", .text = @embedFile("../dap/grid.f90") },
    .{ .name = "extras.F90", .text = extras },
};

/// Constructs the corpus files above do not have
const extras =
    \\! Interfaces, generics, enums, procedure pointers, OpenMP, macros with
    \\! arguments, FORMAT, NAMELIST and continued strings
    \\#define SQUARE(x) ((x)*(x))
    \\#include "consts.inc"
    \\module extras
    \\  implicit none
    \\  private
    \\  public :: norm, op, cb, apply
    \\  interface norm
    \\    module procedure norm_r, norm_i
    \\  end interface norm
    \\  interface operator(.op.)
    \\    module procedure op
    \\  end interface
    \\  abstract interface
    \\    subroutine cb(i)
    \\      integer, intent(in) :: i
    \\    end subroutine cb
    \\  end interface
    \\  enum, bind(c)
    \\    enumerator :: red = 1, green, blue
    \\  end enum
    \\  procedure(cb), pointer :: hook => null()
    \\contains
    \\  pure real function norm_r(x) result(r)
    \\    real, intent(in) :: x(:)
    \\    r = sqrt(sum(SQUARE(x)))
    \\  end function norm_r
    \\  pure integer function norm_i(x)
    \\    integer, intent(in) :: x(:)
    \\    norm_i = sum(abs(x))
    \\  end function norm_i
    \\  logical function op(a, b)
    \\    integer, intent(in) :: a, b
    \\    op = a == b
    \\  end function op
    \\  subroutine apply(f, n, msg)
    \\    procedure(cb) :: f
    \\    integer, intent(in) :: n
    \\    character(len=*), intent(in) :: msg
    \\    integer :: i, arr(n)
    \\    real :: grid(n, n)
    \\    namelist /cfg/ i, arr
    \\    !$omp parallel do private(i) &
    \\    !$omp& shared(arr)
    \\    do concurrent (i = 1:n)
    \\      arr(i) = i
    \\    end do
    \\    !$omp end parallel do
    \\    forall (i = 1:n) grid(i, i) = 1.0
    \\    select rank (arr)
    \\    rank (1)
    \\      call f(arr(1))
    \\    rank default
    \\      error stop 'rank'
    \\    end select
    \\    critical
    \\      write (*, 100) msg // 'a long &
    \\        &continued string', n
    \\    end critical
    \\100 format (a, i0)
    \\    if (n > 0) call f(n); if (n < 0) return
    \\  end subroutine apply
    \\end module extras
    \\
;

/// Further files of the workspace: what `includes.f90` and `extras.F90`
/// include, and the files that hold a version under a name of the other
/// form or as bytes that are not UTF-8
const consts_inc: Source = .{ .name = "consts.inc", .text = @embedFile("../compiler/include/consts.inc") };
pub const as_fixed = corpus.len + 1;
pub const as_free = corpus.len + 2;
pub const on_disk = corpus.len + 3;
pub const n_files = corpus.len + 4;

pub const file_names = blk: {
    var names: [n_files][]const u8 = undefined;
    for (corpus, 0..) |c, i| names[i] = c.name;
    names[corpus.len] = consts_inc.name;
    names[as_fixed] = "as_fixed.f";
    names[as_free] = "as_free.f90";
    names[on_disk] = "on_disk.f90";
    break :blk names;
};

fn initialText(i: usize) []const u8 {
    return if (i < corpus.len) corpus[i].text else if (i == corpus.len) consts_inc.text else "program p\nend program p\n";
}

const workspace_files = blk: {
    var files: [n_files]h.File = undefined;
    for (&files, 0..) |*f, i| f.* = .{ .name = file_names[i], .text = initialText(i) };
    break :blk files;
};

// --------------------------------------------------------------------------
// Budget

pub const Budget = struct {
    /// every how many lines one is damaged (1: each of them)
    stride: usize,
    /// random positions asked about in each version, besides the damage
    /// and the end of the text
    positions: usize,
    /// versions with random bytes per file and round
    byte_versions: usize,
    /// passes, each with its own seed
    rounds: usize,
    /// every position gets every request, not a rotation of the rarer ones
    all_requests: bool,
};

const quick: Budget = .{ .stride = 20, .positions = 1, .byte_versions = 2, .rounds = 1, .all_requests = false };
const long: Budget = .{ .stride = 1, .positions = 2, .byte_versions = 30, .rounds = 1, .all_requests = true };

var budget_cache: ?Budget = null;

fn budget() Budget {
    if (budget_cache) |b| return b;
    var env = std.testing.environ.createMap(gpa) catch return quick;
    defer env.deinit();
    const b = if (env.get("ZFLS_DAMAGE")) |v| (if (std.mem.eql(u8, v, "long")) long else quick) else quick;
    budget_cache = b;
    return b;
}

// --------------------------------------------------------------------------
// Watchdog

/// A request that takes longer is a hang. Requests take milliseconds; the
/// margin is for slow, shared CI machines running a Debug build.
const hang_s = 30;

const Watchdog = struct {
    /// when the current request started (awake clock, ms); 0: none runs
    var started: std.atomic.Value(i64) = .init(0);
    /// what it is, for the message (only read once it hangs, while the
    /// thread that set it is stuck)
    var method: []const u8 = "";
    var what: []const u8 = "";
    var text: []const u8 = "";
    var running = false;

    fn now() i64 {
        return std.Io.Timestamp.now(io, .awake).toMilliseconds();
    }

    fn ensure() void {
        if (running) return;
        const th = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, watch, .{}) catch return;
        th.detach();
        running = true;
    }

    fn begin(m: []const u8, w: []const u8, t: []const u8) void {
        method = m;
        what = w;
        text = t;
        started.store(now(), .release);
    }

    fn end() void {
        started.store(0, .release);
    }

    fn watch() void {
        while (true) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            const s = started.load(.acquire);
            if (s != 0 and now() - s > hang_s * 1000)
                std.debug.panic("{s} took more than {d} s ({s}) on this text:\n{s}\n", .{ method, hang_s, what, text });
        }
    }
};

// --------------------------------------------------------------------------
// Checking results

/// The lines of `text` as LSP counts them (\n, \r\n and \r end one)
fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    return zfls.parser.splitLines(a, text);
}

/// The length of a line in UTF-16 code units; for text that is not UTF-8
/// (which a client decodes its own way), its length in bytes, a bound
pub fn units(line: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(line)) return line.len;
    var n: usize = 0;
    for (line) |c| {
        if (c & 0xC0 != 0x80) n += 1;
        if (c >= 0xF0) n += 1;
    }
    return n;
}

const Bad = error{BadResult};

const Checker = struct {
    a: Allocator,
    /// the documents' URIs and lines, by workspace file
    uris: []const []const u8,
    lines: []const []const []const u8,
    /// what was wrong, for the message, and the title of the code action
    /// or code lens it is in
    why: []const u8 = "",
    title: []const u8 = "",

    fn linesOf(c: *Checker, uri: []const u8) Bad![]const []const u8 {
        for (c.uris, 0..) |u, i| if (std.mem.eql(u8, u, uri)) return c.lines[i];
        return c.bad("a location in {s}, which is not a file of the workspace", .{uri});
    }

    fn bad(c: *Checker, comptime fmt: []const u8, args: anytype) Bad {
        c.why = c.a.print(fmt, args) catch "out of memory";
        return error.BadResult;
    }

    fn position(c: *Checker, lines: []const []const u8, p: Value) Bad!struct { i64, i64 } {
        const l = json.int(json.get(p, "line")) orelse return c.bad("a position without a line: {f}", .{std.json.fmt(p, .{})});
        const ch = json.int(json.get(p, "character")) orelse return c.bad("a position without a character: {f}", .{std.json.fmt(p, .{})});
        if (l < 0 or ch < 0) return c.bad("a negative position {d}:{d}", .{ l, ch });
        if (l >= lines.len) return c.bad("line {d} of a document of {d} lines", .{ l, lines.len });
        const len = units(lines[@intCast(l)]);
        if (ch > len) return c.bad("character {d} of line {d}, which has {d}", .{ ch, l, len });
        return .{ l, ch };
    }

    fn range(c: *Checker, lines: []const []const u8, r: Value) Bad!void {
        c.rangeIn(lines, r) catch |e| {
            var file: []const u8 = "?";
            for (c.lines, 0..) |ls, i| if (ls.ptr == lines.ptr) {
                file = file_names[i];
            };
            c.why = c.a.print("{s}: {f} in {s} ({s})", .{ c.why, std.json.fmt(r, .{}), file, c.title }) catch c.why;
            return e;
        };
    }

    fn rangeIn(c: *Checker, lines: []const []const u8, r: Value) Bad!void {
        const s = try c.position(lines, json.get(r, "start") orelse return c.bad("a range without a start", .{}));
        const e = try c.position(lines, json.get(r, "end") orelse return c.bad("a range without an end", .{}));
        if (e[0] < s[0] or (e[0] == s[0] and e[1] < s[1]))
            return c.bad("a range that ends ({d}:{d}) before it starts ({d}:{d})", .{ e[0], e[1], s[0], s[1] });
    }

    const range_keys = [_][]const u8{ "range", "selectionRange", "targetRange", "targetSelectionRange", "originSelectionRange", "fullRange", "insert", "replace" };

    /// Every range and position in `v`, in the document `lines` unless an
    /// enclosing object names another one
    fn walk(c: *Checker, v: Value, lines: []const []const u8) Bad!void {
        switch (v) {
            .array => |arr| for (arr.items) |x| try c.walk(x, lines),
            .object => |obj| {
                var here = lines;
                if (json.str(obj.get("title"))) |t| c.title = t;
                if (json.str(obj.get("uri")) orelse json.str(obj.get("targetUri")) orelse json.str(json.path(v, &.{ "textDocument", "uri" }))) |u| here = try c.linesOf(u);
                var it = obj.iterator();
                while (it.next()) |kv| {
                    const key = kv.key_ptr.*;
                    const x = kv.value_ptr.*;
                    if (std.mem.eql(u8, key, "changes") and x == .object) {
                        var ch = x.object.iterator();
                        while (ch.next()) |e| try c.walk(e.value_ptr.*, try c.linesOf(e.key_ptr.*));
                        continue;
                    }
                    for (range_keys) |k| if (std.mem.eql(u8, key, k) and json.get(x, "start") != null) try c.range(here, x);
                    if (std.mem.eql(u8, key, "position") and x == .object) _ = try c.position(here, x);
                    try c.walk(x, here);
                }
            },
            else => {},
        }
    }

    fn folds(c: *Checker, lines: []const []const u8, v: Value) Bad!void {
        for (json.items(v)) |f| {
            const s = json.int(json.get(f, "startLine")) orelse return c.bad("a folding range without a start line", .{});
            const e = json.int(json.get(f, "endLine")) orelse return c.bad("a folding range without an end line", .{});
            if (s < 0 or e < s or e >= lines.len) return c.bad("folding range {d}-{d} in a document of {d} lines", .{ s, e, lines.len });
        }
    }

    fn tokens(c: *Checker, lines: []const []const u8, v: Value) Bad!void {
        const data = json.items(json.get(v, "data"));
        if (data.len % 5 != 0) return c.bad("{d} numbers of semantic tokens", .{data.len});
        var line: i64 = 0;
        var col: i64 = 0;
        var i: usize = 0;
        while (i < data.len) : (i += 5) {
            const dl = json.int(data[i]) orelse -1;
            const dc = json.int(data[i + 1]) orelse -1;
            const len = json.int(data[i + 2]) orelse -1;
            if (dl < 0 or dc < 0 or len < 0) return c.bad("a semantic token with a negative number", .{});
            if (dl > 0) col = 0;
            line += dl;
            col += dc;
            if (line >= lines.len) return c.bad("a semantic token on line {d} of {d}", .{ line, lines.len });
            const n = units(lines[@intCast(line)]);
            if (col + len > n) return c.bad("semantic token {d}:{d} of length {d} on a line of {d}", .{ line, col, len, n });
        }
    }
};

// --------------------------------------------------------------------------
// A server on the corpus

pub const Pos = struct { line: i64, character: i64 };

pub const Session = struct {
    w: *h.Workspace,
    /// what one version allocates
    arena: std.heap.ArenaAllocator,
    rng: std.Random,
    b: Budget,
    uris: [n_files][]const u8 = undefined,
    texts: [n_files][]const u8 = undefined,
    /// their lines, and those of the files as they were
    lines: [n_files][]const []const u8 = undefined,
    initial_lines: [n_files][]const []const u8 = undefined,
    /// what lives as long as the session
    keep: std.heap.ArenaAllocator,
    /// the damaged file, its damage and the request being made
    file: usize = 0,
    what: []const u8 = "",
    method: []const u8 = "",
    at: ?Pos = null,
    /// the next of the rarer position requests
    turn: usize = 0,

    pub fn init(seed: u64, prng: *std.Random.DefaultPrng, hierarchical: bool) !Session {
        Watchdog.ensure();
        const w = try h.Workspace.init(&workspace_files, .{
            .settings = .{
                .incremental_sync = true,
                .enable_code_actions = true,
                .use_signature_help = true,
                .variable_hover = true,
                .hover_signature = true,
                .max_line_length = 132,
                .max_comment_line_length = 200,
            },
            .hierarchical_symbols = hierarchical,
        });
        errdefer w.deinit();
        // notifications (diagnostics after each save) are not kept
        w.server.sink = .{};
        prng.* = .init(seed);
        var s: Session = .{ .w = w, .arena = .init(gpa), .keep = .init(gpa), .rng = prng.random(), .b = budget() };
        errdefer s.keep.deinit();
        for (0..n_files) |i| {
            s.uris[i] = try w.uri(file_names[i]);
            s.texts[i] = initialText(i);
            s.initial_lines[i] = try splitLines(s.keep.allocator(), initialText(i));
            s.lines[i] = s.initial_lines[i];
        }
        return s;
    }

    pub fn deinit(s: *Session) void {
        s.arena.deinit();
        s.keep.deinit();
        s.w.deinit();
    }

    fn fail(s: *Session, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("\n{s} of {s}: {s}", .{ s.what, file_names[s.file], s.method });
        if (s.at) |p| std.debug.print(" at {d}:{d}", .{ p.line, p.character });
        std.debug.print(": " ++ fmt ++ "\n--- text ---\n{s}\n--- end ---\n", args ++ .{s.texts[s.file]});
    }

    fn ask(s: *Session, method: []const u8, params: anytype) !Value {
        const a = s.arena.allocator();
        s.method = method;
        Watchdog.begin(method, s.what, s.texts[s.file]);
        defer Watchdog.end();
        const v = s.w.server.dispatchPublic(a, method, try json.from(a, params)) catch |e| {
            s.fail("error {s}", .{@errorName(e)});
            return e;
        };
        // what the client gets must be JSON
        const out = try json.stringify(a, v);
        if (!std.unicode.utf8ValidateSlice(out)) {
            s.fail("the result is not UTF-8", .{});
            return error.BadResult;
        }
        return v;
    }

    /// Check the ranges of a result in the damaged document
    fn check(s: *Session, v: Value, comptime how: enum { walk, folds, tokens }) !void {
        var c: Checker = .{ .a = s.arena.allocator(), .uris = &s.uris, .lines = &s.lines };
        const lines = s.lines[s.file];
        (switch (how) {
            .walk => c.walk(v, lines),
            .folds => c.folds(lines, v),
            .tokens => c.tokens(lines, v),
        }) catch |e| {
            s.fail("{s}", .{c.why});
            return e;
        };
    }

    fn askChecked(s: *Session, method: []const u8, params: anytype) !Value {
        const v = try s.ask(method, params);
        try s.check(v, .walk);
        return v;
    }

    /// Give file `i` the text `text`, as an editor does (didChange, then
    /// didSave after writing it)
    pub fn replace(s: *Session, i: usize, text: []const u8) !void {
        s.file = i;
        s.texts[i] = text;
        s.lines[i] = if (text.ptr == initialText(i).ptr) s.initial_lines[i] else try splitLines(s.arena.allocator(), text);
        s.at = null;
        try s.w.tmp.dir.writeFile(io, .{ .sub_path = file_names[i], .data = text });
        if (i == on_disk) {
            // a file the editor does not have open, changed on disk
            _ = try s.ask("workspace/didChangeWatchedFiles", .{
                .changes = &[_]struct { uri: []const u8, type: i64 }{.{ .uri = s.uris[i], .type = 2 }},
            });
            return;
        }
        _ = try s.ask("textDocument/didChange", .{
            .textDocument = .{ .uri = s.uris[i], .version = @as(i64, 1) },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
        });
        _ = try s.ask("textDocument/didSave", .{ .textDocument = .{ .uri = s.uris[i] } });
    }

    /// Put file `i` back as it was
    pub fn restore(s: *Session, i: usize) !void {
        _ = s.arena.reset(.retain_capacity);
        s.what = "restoring";
        try s.replace(i, initialText(i));
    }

    /// Damage file `i` into `text` and ask about it; `site` is the byte
    /// offset of the damage
    pub fn version(s: *Session, i: usize, what: []const u8, damaged: []const u8, site: usize) !void {
        // the text an editor sends is UTF-8 (the JSON of the message); only
        // a file on disk may hold other bytes
        const a = s.arena.allocator();
        const text = if (i == on_disk) damaged else try json.validUtf8(a, damaged);
        s.what = what;
        try s.replace(i, text);
        const lines = try splitLines(a, text);
        try s.documentRequests(i, lines);
        var positions: std.ArrayList(Pos) = .empty;
        try positions.append(a, posAt(text, @min(site, text.len)));
        try positions.append(a, posAt(text, text.len));
        for (0..s.b.positions) |_| {
            const l = s.rng.uintLessThan(usize, lines.len);
            try positions.append(a, .{ .line = @intCast(l), .character = @intCast(s.rng.uintAtMost(usize, units(lines[l]))) });
        }
        for (positions.items) |p| try s.positionRequests(i, p);
    }

    fn documentRequests(s: *Session, i: usize, lines: []const []const u8) !void {
        const doc = .{ .uri = s.uris[i] };
        const last: Pos = .{ .line = @intCast(lines.len - 1), .character = @intCast(units(lines[lines.len - 1])) };
        const whole = .{ .start = Pos{ .line = 0, .character = 0 }, .end = last };
        const a = s.arena.allocator();
        // diagnostics as published after the save
        s.method = "diagnostics";
        Watchdog.begin("diagnostics", s.what, s.texts[i]);
        const diags = s.w.server.getDiagnostics(a, s.uris[i]) catch |e| {
            Watchdog.end();
            s.fail("error {s}", .{@errorName(e)});
            return e;
        };
        Watchdog.end();
        if (diags) |d| try s.check(d, .walk);
        _ = try s.askChecked("textDocument/documentSymbol", .{ .textDocument = doc });
        try s.check(try s.ask("textDocument/foldingRange", .{ .textDocument = doc }), .folds);
        try s.check(try s.ask("textDocument/semanticTokens/full", .{ .textDocument = doc }), .tokens);
        const l0 = s.rng.uintLessThan(usize, lines.len);
        const l1 = l0 + s.rng.uintLessThan(usize, lines.len - l0);
        try s.check(try s.ask("textDocument/semanticTokens/range", .{ .textDocument = doc, .range = .{
            .start = Pos{ .line = @intCast(l0), .character = 0 },
            .end = Pos{ .line = @intCast(l1), .character = @intCast(units(lines[l1])) },
        } }), .tokens);
        _ = try s.askChecked("textDocument/inlayHint", .{ .textDocument = doc, .range = whole });
        _ = try s.askChecked("textDocument/documentLink", .{ .textDocument = doc });
        const lenses = try s.askChecked("textDocument/codeLens", .{ .textDocument = doc });
        if (json.items(lenses).len > 0) _ = try s.askChecked("codeLens/resolve", json.items(lenses)[0]);
        _ = try s.askChecked("textDocument/codeAction", .{ .textDocument = doc, .range = whole, .context = .{ .triggerKind = @as(i64, 1) } });
        _ = try s.askChecked("textDocument/inlineValue", .{ .textDocument = doc, .range = whole, .context = .{
            .frameId = @as(i64, 1),
            .stoppedLocation = .{ .start = Pos{ .line = @intCast(l0), .character = 0 }, .end = Pos{ .line = @intCast(l0), .character = 0 } },
        } });
        const fixed = zfls.suffixes.formOf(file_names[i]) == .fixed;
        _ = try s.ask("zfls/convertForm", .{ .textDocument = doc, .to = if (fixed) "free" else "fixed" });
        _ = try s.askChecked("workspace/symbol", .{ .query = "a" });
    }

    fn positionRequests(s: *Session, i: usize, p: Pos) !void {
        s.at = p;
        const doc = .{ .uri = s.uris[i] };
        const at = .{ .textDocument = doc, .position = p };
        _ = try s.askChecked("textDocument/hover", at);
        _ = try s.askChecked("textDocument/completion", at);
        _ = try s.askChecked("textDocument/signatureHelp", at);
        _ = try s.askChecked("textDocument/definition", at);
        _ = try s.askChecked("textDocument/references", .{ .textDocument = doc, .position = p, .context = .{ .includeDeclaration = true } });
        _ = try s.askChecked("textDocument/documentHighlight", at);
        _ = try s.askChecked("textDocument/selectionRange", .{ .textDocument = doc, .positions = &[_]Pos{p} });
        _ = try s.askChecked("textDocument/codeAction", .{ .textDocument = doc, .range = .{ .start = Pos{ .line = p.line, .character = 0 }, .end = p }, .context = .{ .triggerKind = @as(i64, 1) } });
        const n_rare = 5;
        const first = if (s.b.all_requests) 0 else s.turn % n_rare;
        const stop = if (s.b.all_requests) n_rare else first + 1;
        s.turn += 1;
        for (first..stop) |r| switch (r) {
            0 => {
                _ = try s.askChecked("textDocument/typeDefinition", at);
                _ = try s.askChecked("textDocument/implementation", at);
                _ = try s.askChecked("textDocument/declaration", at);
            },
            1 => {
                _ = try s.askChecked("textDocument/prepareRename", at);
                _ = try s.askChecked("textDocument/rename", .{ .textDocument = doc, .position = p, .newName = "renamed" });
                _ = try s.askChecked("textDocument/linkedEditingRange", at);
            },
            2 => {
                const items = try s.askChecked("textDocument/prepareCallHierarchy", at);
                if (json.items(items).len > 0) {
                    _ = try s.askChecked("callHierarchy/incomingCalls", .{ .item = json.items(items)[0] });
                    _ = try s.askChecked("callHierarchy/outgoingCalls", .{ .item = json.items(items)[0] });
                }
            },
            3 => {
                const items = try s.askChecked("textDocument/prepareTypeHierarchy", at);
                if (json.items(items).len > 0) {
                    _ = try s.askChecked("typeHierarchy/supertypes", .{ .item = json.items(items)[0] });
                    _ = try s.askChecked("typeHierarchy/subtypes", .{ .item = json.items(items)[0] });
                }
            },
            else => {
                _ = try s.askChecked("textDocument/onTypeFormatting", .{ .textDocument = doc, .position = p, .ch = "#", .options = .{ .tabSize = @as(i64, 2), .insertSpaces = true } });
                _ = try s.askChecked("zfls/moduleVariables", at);
                _ = try s.askChecked("zfls/bindC", at);
            },
        };
        s.at = null;
    }
};

/// The LSP position of byte offset `off` of `text`
pub fn posAt(text: []const u8, off: usize) Pos {
    var line: i64 = 0;
    var bol: usize = 0;
    var i: usize = 0;
    while (i < off) : (i += 1) {
        if (text[i] == '\n' or text[i] == '\r') {
            if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
                if (i + 1 == off) break;
                i += 1;
            }
            line += 1;
            bol = i + 1;
        }
    }
    var end = bol;
    while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
    return .{ .line = line, .character = @intCast(units(text[bol..@min(off, end)])) };
}
