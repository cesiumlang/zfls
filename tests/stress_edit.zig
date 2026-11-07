//! Long randomized editing sessions against zfls (`zig build test-stress`).
//!
//! Drives one zfls process through thousands of seeded random edits on a
//! temporary copy of a Fortran workspace, with saves, close/reopen and
//! requests mixed in, the way an editor would. It fails on:
//!
//! - a crash, hang (request timeout) or unclean exit, including the Debug
//!   build's allocator reports (leaks, double frees) on stderr;
//! - a request without a response, or with an error response;
//! - stale state: at the end, every edited file's symbols and diagnostics
//!   must equal those of a fresh zfls started on the final text (not checked
//!   with --preprocessor, whose `#define`s legitimately depend on history).
//!
//! Run a Debug build (the default `zig build`) so safety checks are on. A
//! failure keeps a reproduction directory (initial files, the exact message
//! stream sent) and prints its path.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");
const Client = lsp.Client;

const fortran_exts = [_][]const u8{ ".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp", ".F", ".F90", ".h", ".inc" };
/// What a Debug build writes to stderr about memory errors
const allocator_reports = [_][]const u8{ "panic", "leaked", "double free", "invalid free", "segmentation fault", "error(safeallocator)" };
/// Non-ASCII text to splice in: multi-byte UTF-8, and surrogate pairs in
/// UTF-16 (the emoji), to exercise position conversion
const unicode_bits = [_][]const u8{ "é", "∑", "😀", "日本", "ß" };
const typed_bits = [_][]const u8{ "(", ")", ",", " ", "%", "&", "::", "=", "'", "!" };
/// Error responses that mirror an exception Python fortls raises
const expected_errors = [_][]const u8{
    // references/highlight on an intrinsic: fortls's AttributeError on the
    // intrinsic object's missing FQSN
    "IntrinsicHasNoFQSN",
};

const Args = struct {
    zfls: []const u8 = "zig-out/bin/zfls",
    source: []const u8 = "../fortls/test/test_source",
    seeds: u64 = 3,
    first_seed: u64 = 1,
    steps: usize = 2000,
    incremental: bool = true,
    preprocessor: bool = false,
    zfls_args: []const []const u8 = &.{},
};

const usage =
    \\usage: stress_edit [--zfls EXE] [--source DIR | --fortls CHECKOUT]
    \\       [--seeds N (3)] [--first-seed N (1)] [--steps N (2000)]
    \\       [--no-incremental] [--preprocessor] [--zfls-arg ARG]...
    \\
    \\--source is the workspace to copy (default: fortls's test_source, else
    \\tests/fortran); --fortls takes a fortls checkout's test/test_source.
    \\--no-incremental sends whole texts rather than range edits.
    \\--preprocessor also edits files with preprocessor directives, and checks
    \\crashes and errors only, not stale state.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var args: Args = .{};
    var zfls_args: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--no-incremental")) {
            args.incremental = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--incremental")) {
            args.incremental = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--preprocessor")) {
            args.preprocessor = true;
            continue;
        }
        if (i + 1 >= argv.len) {
            std.debug.print("{s}", .{usage});
            return 2;
        }
        i += 1;
        const v = argv[i];
        if (std.mem.eql(u8, arg, "--zfls")) {
            args.zfls = v;
        } else if (std.mem.eql(u8, arg, "--source")) {
            args.source = v;
        } else if (std.mem.eql(u8, arg, "--fortls")) {
            args.source = try std.Io.Dir.path.join(a, &.{ v, "test", "test_source" });
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            args.seeds = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--first-seed")) {
            args.first_seed = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--steps")) {
            args.steps = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--zfls-arg")) {
            try zfls_args.append(a, v);
        } else {
            std.debug.print("unknown option {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    args.zfls_args = zfls_args.items;
    const cwd = Io.Dir.cwd();
    const source = if (cwd.openDir(io, args.source, .{})) |d| blk: {
        d.close(io);
        break :blk args.source;
    } else |_| "tests/fortran";
    const src = try cwd.realPathFileAlloc(io, source, a);
    args.zfls = try cwd.realPathFileAlloc(io, args.zfls, a);
    std.debug.print("workspace: {s}; zfls: {s}; {s} sync\n", .{ src, args.zfls, if (args.incremental) "incremental" else "full" });

    var failed: u64 = 0;
    var seed = args.first_seed;
    while (seed < args.first_seed + args.seeds) : (seed += 1) {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        if (try runSeed(io, init.gpa, arena.allocator(), init.environ_map, args, seed, src)) failed += 1;
    }
    std.debug.print("{d}/{d} sessions passed\n", .{ args.seeds - failed, args.seeds });
    return if (failed > 0) 1 else 0;
}

fn serverArgv(a: Allocator, args: Args) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    // a test run leaves nothing in zfls's cache directory
    try argv.appendSlice(a, &.{ args.zfls, "--disable_index_cache" });
    if (args.incremental) try argv.append(a, "--incremental_sync");
    try argv.appendSlice(a, args.zfls_args);
    return argv.items;
}

fn readText(io: Io, a: Allocator, path: []const u8) ![]const u8 {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20));
    return zfls.json.validUtf8(a, raw);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn usesPreprocessor(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t\r\x0b\x0c"), "#")) return true;
    }
    return false;
}

/// The Fortran files under `root` (absolute paths, sorted); without
/// `preprocessor`, those with no directives (every parse adds its
/// `#define`s to one table that later parses see, as in fortls, so a
/// session's history changes what a fresh start would preprocess)
fn sourceFiles(io: Io, a: Allocator, root: []const u8, preprocessor: bool) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const ext = std.Io.Dir.path.extension(e.basename);
        for (fortran_exts) |x| {
            if (std.mem.eql(u8, ext, x)) break;
        } else continue;
        const path = try std.Io.Dir.path.join(a, &.{ root, e.path });
        if (!preprocessor and usesPreprocessor(try readText(io, a, path))) continue;
        try out.append(a, path);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// The lines of `files` that are not blank
fn corpusLines(io: Io, a: Allocator, files: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |p| {
        var lines = std.mem.splitScalar(u8, try readText(io, a, p), '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\x0b\x0c").len > 0) try out.append(a, line);
        }
    }
    return out.items;
}

// Positions: LSP characters are UTF-16 code units

fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

/// The byte index of UTF-16 offset `units` in `line`
fn utf16ToByte(line: []const u8, units: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (n >= units) return i;
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return line.len;
}

/// `i`, or the start of the character it is in
fn charStart(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and j < s.len and s[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

const Pos = struct { line: usize, character: usize };
const Range = struct { start: Pos, end: Pos };

/// One open document's text, edited the way the client sends it
const Doc = struct {
    path: []const u8,
    uri: []const u8,
    text: std.ArrayList(u8) = .empty,
    version: i64 = 1,

    fn lineCount(d: *const Doc) usize {
        return std.mem.countScalar(u8, d.text.items, '\n') + 1;
    }

    fn line(d: *const Doc, n: usize) []const u8 {
        var it = std.mem.splitScalar(u8, d.text.items, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) if (i == n) return l;
        return "";
    }

    fn offset(d: *const Doc, ln: usize, char: usize) usize {
        const n = @min(ln, d.lineCount() - 1);
        var base: usize = 0;
        var it = std.mem.splitScalar(u8, d.text.items, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) {
            if (i == n) return base + utf16ToByte(l, char);
            base += l.len + 1;
        }
        return d.text.items.len;
    }

    fn apply(d: *Doc, gpa: Allocator, r: Range, new: []const u8) !void {
        const s = d.offset(r.start.line, r.start.character);
        const e = @max(s, d.offset(r.end.line, r.end.character));
        try d.text.replaceRange(gpa, s, e - s, new);
    }

    /// The LSP position of byte `index` of line `ln`
    fn position(d: *const Doc, ln: usize, index: usize) Pos {
        return .{ .line = ln, .character = utf16Len(d.line(ln)[0..index]) };
    }
};

const Op = enum { insert_lines, delete_lines, replace_lines, type, replace_all, save, request };
const op_weights = std.enums.EnumArray(Op, u32).init(.{
    .insert_lines = 20,
    .delete_lines = 15,
    .replace_lines = 10,
    .type = 30,
    .replace_all = 1,
    .save = 6,
    .request = 25,
});

const Session = struct {
    io: Io,
    gpa: Allocator,
    a: Allocator,
    rng: std.Random,
    args: Args,
    work: []const u8,
    corpus: []const []const u8,
    files: []const []const u8,
    /// Sorted by path
    open: std.ArrayList(*Doc) = .empty,
    /// Every file opened, in order: a closed file stays in the workspace
    /// (re-read from disk), even one the config excludes
    ever_opened: std.ArrayList([]const u8) = .empty,
    ops: std.ArrayList([]const u8) = .empty,
    errors: std.ArrayList([]const u8) = .empty,
    expected_errors: usize = 0,
    requests: usize = 0,
    server: *Client,

    fn below(s: *Session, n: usize) usize {
        return s.rng.uintLessThan(usize, n);
    }

    fn chance(s: *Session, p: f64) bool {
        return s.rng.float(f64) < p;
    }

    fn pick(s: *Session, comptime T: type, items: []const T) T {
        return items[s.below(items.len)];
    }

    fn randPos(s: *Session, d: *const Doc) Pos {
        const ln = s.below(d.lineCount());
        const text = d.line(ln);
        return d.position(ln, charStart(text, s.rng.uintAtMost(usize, text.len)));
    }

    fn change(s: *Session, d: *Doc, r: ?Range, new: []const u8) !void {
        if (r) |rng| {
            try d.apply(s.gpa, rng, new);
        } else {
            d.text.clearRetainingCapacity();
            try d.text.appendSlice(s.gpa, new);
        }
        d.version += 1;
        const td = .{ .uri = d.uri, .version = d.version };
        if (s.args.incremental and r != null) {
            try s.server.send("textDocument/didChange", .{ .textDocument = td, .contentChanges = .{.{ .range = r.?, .text = new }} }, null);
        } else {
            try s.server.send("textDocument/didChange", .{ .textDocument = td, .contentChanges = .{.{ .text = d.text.items }} }, null);
        }
    }

    fn snippet(s: *Session) ![]const u8 {
        const n = s.pick(usize, &.{ 1, 1, 1, 2, 3, 5, 8 });
        const start = s.below(s.corpus.len);
        var out: std.ArrayList(u8) = .empty;
        for (s.corpus[start..@min(s.corpus.len, start + n)]) |l| {
            try out.appendSlice(s.a, l);
            try out.append(s.a, '\n');
        }
        if (s.chance(0.1)) {
            const bit = s.pick([]const u8, &unicode_bits);
            try out.print(s.a, "  ! {s} comment {s}\n", .{ bit, bit });
        }
        return out.items;
    }

    fn insertLines(s: *Session, d: *Doc) !void {
        const p: Pos = .{ .line = s.below(d.lineCount()), .character = 0 };
        try s.change(d, .{ .start = p, .end = p }, try s.snippet());
    }

    fn deleteLines(s: *Session, d: *Doc) !void {
        const n = d.lineCount();
        const first = s.below(n);
        const last = @min(n - 1, first + s.pick(usize, &.{ 1, 1, 2, 4, 10 }));
        try s.change(d, .{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last, .character = 0 } }, "");
    }

    fn replaceLines(s: *Session, d: *Doc) !void {
        const n = d.lineCount();
        const first = s.below(n);
        const last = @min(n - 1, first + s.pick(usize, &.{ 1, 2, 3 }));
        try s.change(d, .{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last, .character = 0 } }, try s.snippet());
    }

    /// Small in-line edits, like typing or deleting characters
    fn typeText(s: *Session, d: *Doc) !void {
        const start = s.randPos(d);
        if (s.chance(0.5)) {
            var words: std.ArrayList([]const u8) = .empty;
            const l = s.pick([]const u8, s.corpus);
            var i: usize = 0;
            while (i < l.len) {
                if (!std.ascii.isAlphabetic(l[i]) and l[i] != '_') {
                    i += 1;
                    continue;
                }
                const w = i;
                while (i < l.len and (std.ascii.isAlphanumeric(l[i]) or l[i] == '_')) i += 1;
                try words.append(s.a, l[w..i]);
            }
            if (words.items.len == 0) try words.append(s.a, "x");
            try words.appendSlice(s.a, &typed_bits);
            try words.appendSlice(s.a, &unicode_bits);
            try s.change(d, .{ .start = start, .end = start }, s.pick([]const u8, words.items));
        } else {
            const text = d.line(start.line);
            const i = utf16ToByte(text, start.character);
            const j = @max(i, charStart(text, @min(text.len, i + s.rng.intRangeAtMost(usize, 1, 6))));
            try s.change(d, .{ .start = start, .end = d.position(start.line, j) }, "");
        }
    }

    fn replaceAll(s: *Session, d: *Doc) !void {
        try s.change(d, null, try readText(s.io, s.a, s.pick([]const u8, s.files)));
    }

    fn save(s: *Session, d: *Doc) !void {
        try s.server.sync();
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = d.path, .data = d.text.items });
        try s.server.send("textDocument/didSave", .{ .textDocument = .{ .uri = d.uri } }, null);
    }

    fn closeDoc(s: *Session, d: *Doc) !void {
        try s.server.send("textDocument/didClose", .{ .textDocument = .{ .uri = d.uri } }, null);
        for (s.open.items, 0..) |o, i| if (o == d) {
            _ = s.open.orderedRemove(i);
            break;
        };
        d.text.deinit(s.gpa);
    }

    fn isOpen(s: *Session, path: []const u8) bool {
        for (s.open.items) |d| if (std.mem.eql(u8, d.path, path)) return true;
        return false;
    }

    fn openDoc(s: *Session, path: []const u8) !void {
        try s.server.sync();
        const d = try s.a.create(Doc);
        d.* = .{ .path = path, .uri = try zfls.paths.pathToUri(s.a, path) };
        try d.text.appendSlice(s.gpa, try readText(s.io, s.a, path));
        var at: usize = 0;
        while (at < s.open.items.len and lessThan({}, s.open.items[at].path, path)) at += 1;
        try s.open.insert(s.a, at, d);
        for (s.ever_opened.items) |p| {
            if (std.mem.eql(u8, p, path)) break;
        } else try s.ever_opened.append(s.a, path);
        try s.ops.append(s.a, try s.a.print("open {s}", .{path[s.work.len + 1 ..]}));
        try s.server.send("textDocument/didOpen", .{ .textDocument = .{
            .uri = d.uri,
            .languageId = "fortran",
            .version = 1,
            .text = d.text.items,
        } }, null);
    }

    fn request(s: *Session, d: *Doc) !void {
        const td = .{ .uri = d.uri };
        const at = .{ .textDocument = td, .position = s.randPos(d) };
        s.requests += 1;
        const Request = struct { method: []const u8, msg: Value };
        const r: Request = switch (s.below(10)) {
            0 => .{ .method = "textDocument/hover", .msg = try s.server.request("textDocument/hover", at) },
            1 => .{ .method = "textDocument/completion", .msg = try s.server.request("textDocument/completion", at) },
            2 => .{ .method = "textDocument/definition", .msg = try s.server.request("textDocument/definition", at) },
            3 => .{ .method = "textDocument/references", .msg = try s.server.request("textDocument/references", at) },
            4 => .{ .method = "textDocument/implementation", .msg = try s.server.request("textDocument/implementation", at) },
            5 => .{ .method = "textDocument/signatureHelp", .msg = try s.server.request("textDocument/signatureHelp", at) },
            6 => .{ .method = "textDocument/documentHighlight", .msg = try s.server.request("textDocument/documentHighlight", at) },
            7 => .{ .method = "textDocument/rename", .msg = try s.server.request("textDocument/rename", .{ .textDocument = td, .position = at.position, .newName = "zz_renamed" }) },
            8 => .{ .method = "textDocument/documentSymbol", .msg = try s.server.request("textDocument/documentSymbol", .{ .textDocument = td }) },
            else => .{ .method = "workspace/symbol", .msg = try s.server.request("workspace/symbol", .{ .query = s.pick([]const u8, &.{ "a", "b", "c", "m", "s", "t" }) }) },
        };
        const err = r.msg.object.get("error") orelse return;
        if (err == .object) if (err.object.get("message")) |m| if (m == .string) {
            for (expected_errors) |e| if (std.mem.eql(u8, m.string, e)) {
                s.expected_errors += 1;
                return;
            };
        };
        const where = try std.json.Stringify.valueAlloc(s.a, at, .{});
        const what = try std.json.Stringify.valueAlloc(s.a, err, .{});
        try s.errors.append(s.a, try s.a.print("{s} at {s} -> {s}", .{ r.method, where, what }));
    }

    fn run(s: *Session) !void {
        _ = try s.server.request("initialize", .{
            .rootUri = try zfls.paths.pathToUri(s.a, s.work),
            .rootPath = s.work,
            .capabilities = .{},
        });
        try s.server.send("initialized", .{}, null);
        // up to 4 files, chosen at random
        const first = try s.a.dupe([]const u8, s.files);
        s.rng.shuffle([]const u8, first);
        for (first[0..@min(4, first.len)]) |p| try s.openDoc(p);
        var weights: [op_weights.values.len]u32 = op_weights.values;
        for (0..s.args.steps) |step| {
            if (s.open.items.len == 0 or s.chance(0.01)) {
                var closed: std.ArrayList([]const u8) = .empty;
                for (s.files) |p| if (!s.isOpen(p)) try closed.append(s.a, p);
                if (closed.items.len > 0) {
                    try s.openDoc(s.pick([]const u8, closed.items));
                    continue;
                }
            }
            const d = s.pick(*Doc, s.open.items);
            const name = std.Io.Dir.path.basename(d.path);
            if (s.chance(0.005) and s.open.items.len > 1) {
                try s.ops.append(s.a, try s.a.print("{d}: close {s}", .{ step, name }));
                try s.closeDoc(d);
                continue;
            }
            const op: Op = @fromBackingInt(@intCast(s.rng.weightedIndex(u32, &weights)));
            try s.ops.append(s.a, try s.a.print("{d}: {s} {s}", .{ step, @tagName(op), name }));
            switch (op) {
                .insert_lines => try s.insertLines(d),
                .delete_lines => try s.deleteLines(d),
                .replace_lines => try s.replaceLines(d),
                .type => try s.typeText(d),
                .replace_all => try s.replaceAll(d),
                .save => try s.save(d),
                .request => try s.request(d),
            }
        }
        // make every open document's final text the saved one; the second
        // round republishes diagnostics now that all the others are final
        for (0..2) |_| for (s.open.items) |d| try s.save(d);
        try s.server.sync();
    }
};

/// Symbols and diagnostics of documents, by path in the workspace
const State = std.array_hash_map.String(Value);

/// The symbols and diagnostics of `uri`, copied to `a` (the server's
/// messages go with it)
fn docState(a: Allocator, server: *Client, uri: []const u8) !Value {
    const sym = try server.request("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } });
    var entry: std.json.ObjectMap = .empty;
    try entry.put(a, "symbols", sym.object.get("result") orelse .null);
    try entry.put(a, "diagnostics", server.diagnosticsOf(uri));
    const text = try std.json.Stringify.valueAlloc(a, Value{ .object = entry }, .{});
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

/// The state of `docs` in a new server on the final text, after `closed`
/// were opened and closed again as in the session
fn freshState(io: Io, gpa: Allocator, a: Allocator, args: Args, tmp: []const u8, work: []const u8, docs: []const []const u8, closed: []const []const u8) !State {
    const s = try Client.start(io, gpa, try serverArgv(a, args), try std.Io.Dir.path.join(a, &.{ tmp, "fresh_stream.bin" }));
    defer s.deinit();
    errdefer s.kill();
    _ = try s.request("initialize", .{ .rootUri = try zfls.paths.pathToUri(a, work), .rootPath = work, .capabilities = .{} });
    try s.send("initialized", .{}, null);
    for ([_][]const []const u8{ closed, docs }) |list| for (list) |p| {
        try s.send("textDocument/didOpen", .{ .textDocument = .{
            .uri = try zfls.paths.pathToUri(a, p),
            .languageId = "fortran",
            .version = 1,
            .text = try readText(io, a, p),
        } }, null);
    };
    for (closed) |p| try s.send("textDocument/didClose", .{ .textDocument = .{ .uri = try zfls.paths.pathToUri(a, p) } }, null);
    // republish each one's diagnostics now that all are open, as the
    // session's final saves do
    for (docs) |p| try s.send("textDocument/didSave", .{ .textDocument = .{ .uri = try zfls.paths.pathToUri(a, p) } }, null);
    try s.sync();
    var out: State = .empty;
    for (docs) |p| try out.put(a, p[work.len + 1 ..], try docState(a, s, try zfls.paths.pathToUri(a, p)));
    _ = try s.close();
    return out;
}

/// Drops what may differ between equally right answers: the "Possible
/// object" hint of a diagnostic names the first of several candidates in
/// workspace order, which edits change
fn normalize(state: *State) void {
    for (state.values()) |*entry| {
        const diags = entry.object.getPtr("diagnostics") orelse continue;
        if (diags.* != .array) continue;
        for (diags.array.items) |*d| {
            if (d.* != .object) continue;
            const related = d.object.getPtr("relatedInformation") orelse continue;
            if (related.* != .array) continue;
            for (related.array.items) |*r| {
                if (r.* != .object) continue;
                const m = r.object.get("message") orelse continue;
                if (m == .string and std.mem.eql(u8, m.string, "Possible object")) _ = r.object.orderedRemove("location");
            }
        }
    }
}

/// Where `x` and `y` first differ, null when they are equal
fn firstDifference(a: Allocator, x: Value, y: Value, path: []const u8) !?[]const u8 {
    if (std.meta.activeTag(x) != std.meta.activeTag(y))
        return try a.print("{s}: {f} != {f}", .{ path, std.json.fmt(x, .{}), std.json.fmt(y, .{}) });
    switch (x) {
        .object => |xo| {
            var keys: std.ArrayList([]const u8) = .empty;
            try keys.appendSlice(a, xo.keys());
            for (y.object.keys()) |k| if (!xo.contains(k)) try keys.append(a, k);
            std.mem.sort([]const u8, keys.items, {}, lessThan);
            for (keys.items) |k| {
                const sub = try a.print("{s}.{s}", .{ path, k });
                const xv = xo.get(k) orelse return try a.print("{s}: missing on one side", .{sub});
                const yv = y.object.get(k) orelse return try a.print("{s}: missing on one side", .{sub});
                if (try firstDifference(a, xv, yv, sub)) |d| return d;
            }
            return null;
        },
        .array => |xa| {
            if (xa.items.len != y.array.items.len)
                return try a.print("{s}: length {d} != {d}", .{ path, xa.items.len, y.array.items.len });
            for (xa.items, y.array.items, 0..) |xv, yv, i| {
                if (try firstDifference(a, xv, yv, try a.print("{s}[{d}]", .{ path, i }))) |d| return d;
            }
            return null;
        },
        else => {
            const xs = try std.json.Stringify.valueAlloc(a, x, .{});
            const ys = try std.json.Stringify.valueAlloc(a, y, .{});
            if (std.mem.eql(u8, xs, ys)) return null;
            return try a.print("{s}: {s} != {s}", .{ path, xs, ys });
        },
    }
}

fn hasAllocatorReport(a: Allocator, stderr: []const u8) !bool {
    const lower = try std.ascii.allocLowerString(a, stderr);
    for (allocator_reports) |r| if (std.mem.find(u8, lower, r) != null) return true;
    return false;
}

/// One session; returns whether it failed
fn runSeed(io: Io, gpa: Allocator, a: Allocator, env: *const std.process.Environ.Map, args: Args, seed: u64, src: []const u8) !bool {
    const tmp = try lsp.tempDir(io, a, env, try a.print("zfls_stress_{d}_", .{seed}));
    const work = try std.Io.Dir.path.join(a, &.{ tmp, "ws" });
    try lsp.copyTree(io, a, src, work);
    try lsp.copyTree(io, a, src, try std.Io.Dir.path.join(a, &.{ tmp, "initial" }));
    var problems: std.ArrayList([]const u8) = .empty;

    var prng: std.Random.DefaultPrng = .init(seed);
    const files = try sourceFiles(io, a, work, args.preprocessor);
    if (files.len == 0) return error.NoFortranFiles;
    var s: Session = .{
        .io = io,
        .gpa = gpa,
        .a = a,
        .rng = prng.random(),
        .args = args,
        .work = work,
        .corpus = try corpusLines(io, a, try sourceFiles(io, a, src, args.preprocessor)),
        .files = files,
        .server = try Client.start(io, gpa, try serverArgv(a, args), try std.Io.Dir.path.join(a, &.{ tmp, "stream.bin" })),
    };
    defer s.server.deinit();
    defer for (s.open.items) |d| d.text.deinit(gpa);
    const started = Io.Clock.awake.now(io);

    var session_state: ?State = null;
    if (sessionState(&s)) |state| {
        session_state = state;
        if (s.server.close()) |term| {
            if (!term.success()) try problems.append(a, try lsp.termText(a, term));
        } else |e| {
            s.server.kill();
            try problems.append(a, try a.print("{s} at exit", .{@errorName(e)}));
        }
    } else |e| {
        s.server.kill();
        try problems.append(a, try a.print("{s}", .{@errorName(e)}));
    }
    const stderr = s.server.stderr.items;
    const reported = try hasAllocatorReport(a, stderr);
    if (reported) try problems.append(a, try a.print("stderr: {s}", .{tail(std.mem.trim(u8, stderr, " \r\n"), 3000)}));
    for (s.errors.items[0..@min(10, s.errors.items.len)]) |e| try problems.append(a, try a.print("error response: {s}", .{e}));
    if (session_state) |*session| if (!args.preprocessor and !reported) {
        var docs: std.ArrayList([]const u8) = .empty;
        for (s.open.items) |d| try docs.append(a, d.path);
        var closed: std.ArrayList([]const u8) = .empty;
        for (s.ever_opened.items) |p| if (!s.isOpen(p)) try closed.append(a, p);
        var fresh = try freshState(io, gpa, a, args, tmp, work, docs.items, closed.items);
        normalize(&fresh);
        normalize(session);
        const names = try a.dupe([]const u8, session.keys());
        std.mem.sort([]const u8, names, {}, lessThan);
        for (names) |name| {
            const other = fresh.get(name) orelse {
                try problems.append(a, try a.print("{s}: no state from the fresh server", .{name}));
                continue;
            };
            if (try firstDifference(a, session.get(name).?, other, name)) |d|
                try problems.append(a, try a.print("stale state vs fresh server: {s}", .{d}));
        }
    };

    const elapsed = @as(f64, @floatFromInt(started.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / 1e9;
    const failed = problems.items.len > 0;
    std.debug.print("seed {d}: {s}  {d} edits/ops, {d} requests ({d} fortls-style errors), {d:.0}s\n", .{
        seed, if (failed) "FAIL" else "ok", s.ops.items.len, s.requests, s.expected_errors, elapsed,
    });
    if (!failed) {
        Io.Dir.cwd().deleteTree(io, tmp) catch {};
        return false;
    }
    var ops: std.ArrayList(u8) = .empty;
    for (s.ops.items) |op| try ops.print(a, "{s}\n", .{op});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ tmp, "ops.txt" }), .data = ops.items });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ tmp, "stderr.txt" }), .data = stderr });
    for (problems.items) |p| std.debug.print("    {s}\n", .{p[0..@min(p.len, 2000)]});
    std.debug.print("    last ops:\n", .{});
    for (s.ops.items[s.ops.items.len -| 5..]) |op| std.debug.print("      {s}\n", .{op});
    std.debug.print("    reproduction: {s} (initial/, stream.bin, ops.txt)\n", .{tmp});
    return true;
}

fn sessionState(s: *Session) !State {
    try s.run();
    var out: State = .empty;
    for (s.open.items) |d| try out.put(s.a, d.path[s.work.len + 1 ..], try docState(s.a, s.server, d.uri));
    return out;
}

fn tail(s: []const u8, n: usize) []const u8 {
    return s[s.len -| n..];
}

test "utf16" {
    try std.testing.expectEqual(4, utf16Len("a😀b"));
    try std.testing.expectEqual(5, utf16ToByte("a😀b", 3));
    try std.testing.expectEqual(1, utf16ToByte("aé", 1));
    try std.testing.expectEqual(3, utf16ToByte("aé", 9));
    try std.testing.expectEqual(1, charStart("a😀b", 3));
}

test "Doc edits" {
    const gpa = std.testing.allocator;
    var d: Doc = .{ .path = "x", .uri = "x" };
    defer d.text.deinit(gpa);
    try d.text.appendSlice(gpa, "ab\nc😀d\n");
    try d.apply(gpa, .{ .start = .{ .line = 1, .character = 3 }, .end = .{ .line = 1, .character = 4 } }, "e");
    try std.testing.expectEqualStrings("ab\nc😀e\n", d.text.items);
    try d.apply(gpa, .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 1, .character = 0 } }, "");
    try std.testing.expectEqualStrings("c😀e\n", d.text.items);
    try std.testing.expectEqual(3, d.position(0, 5).character);
}

test "firstDifference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try std.json.parseFromSliceLeaky(Value, a, "{\"a\": [1, {\"b\": \"x\"}], \"c\": null}", .{});
    const y = try std.json.parseFromSliceLeaky(Value, a, "{\"a\": [1, {\"b\": \"y\"}], \"c\": null}", .{});
    try std.testing.expectEqual(null, try firstDifference(a, x, x, "f"));
    try std.testing.expectEqualStrings("f.a[1].b: \"x\" != \"y\"", (try firstDifference(a, x, y, "f")).?);
}
