//! What the server's hot paths cost in allocations and bytes asked for, on
//! fixed corpora (#902): initialization, and on the largest file the
//! document's symbols, semantic tokens, diagnostics, hover, definition,
//! references and completion at sampled places, and incremental edits. The
//! counts are compared with tests/bench/baseline.json: a count that grows
//! by more than `tolerance` fails, so that a quadratic or per-term blowup
//! shows in `zig build test` (and `zig build bench`) without the
//! wall-clock flakiness of timings. A count that falls below the baseline
//! is a note: record the new one.
//!
//! `zig build bench-baseline` writes the file again (ZFLS_BASELINE=record).
//! A corpus that is not there (the M_intrinsics submodule) is skipped.

const std = @import("std");
const h = @import("harness.zig");
const counting = @import("counting.zig");
const json = h.json;
const Allocator = std.mem.Allocator;
const io = std.testing.io;
const gpa = std.testing.allocator;

const baseline_path = "tests/bench/baseline.json";

/// A count may grow this much over the baseline (the platforms differ by
/// up to a quarter, in paths and in what the system calls allocate)
const tolerance = 1.5;

const Measure = struct { allocs: u64, bytes: u64, peak: u64 };

const Recorder = struct {
    a: Allocator,
    counts: *counting.Counts,
    prev: counting.Counter.Snapshot,
    /// The phase whose top allocation sites are printed (ZFLS_ALLOC_SITES)
    sites_of: ?[]const u8 = null,
    out: std.StringArrayHashMapUnmanaged(Measure) = .empty,

    /// What was counted since the last `phase`, under `corpus/name`
    fn phase(r: *Recorder, corpus: []const u8, name: []const u8) !void {
        const now = r.counts.total();
        const key = try r.a.print("{s}/{s}", .{ corpus, name });
        try r.out.put(r.a, key, .{ .allocs = now.allocs - r.prev.allocs, .bytes = now.bytes - r.prev.bytes, .peak = r.counts.peak() });
        r.prev = now;
        r.counts.live.resetPeak();
        if (r.sites_of) |want| if (std.mem.eql(u8, want, key)) {
            r.counts.sites.?.dump(key, 12);
        } else if (r.counts.sites) |s| s.map.clearRetainingCapacity();
    }
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `count` places of identifiers spread over `text`
fn sample(a: Allocator, text: []const u8, count: usize) ![]h.Pos {
    var words: std.ArrayList(h.Pos) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var ln: i64 = 0;
    while (lines.next()) |line| : (ln += 1) {
        const code = line[0 .. std.mem.findScalar(u8, line, '!') orelse line.len];
        var i: usize = 0;
        while (i < code.len) {
            if (!isWord(code[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < code.len and isWord(code[i])) i += 1;
            if (!std.ascii.isDigit(code[start])) try words.append(a, .{ .line = ln, .col = @intCast(start + 1) });
        }
    }
    var out: std.ArrayList(h.Pos) = .empty;
    const step = @max(1, words.items.len / count);
    var i: usize = 0;
    while (i < words.items.len and out.items.len < count) : (i += step) try out.append(a, words.items[i]);
    return out.items;
}

/// Runs the scenarios of one corpus: `files`, the requests on `big`
fn scenario(r: *Recorder, corpus: []const u8, files: []const h.File, big: []const u8) !void {
    // (the workspace starts the counts from zero)
    r.prev = .{ .allocs = 0, .bytes = 0 };
    const w = try h.Workspace.init(files, .{ .counts = r.counts, .pull_diagnostics = true, .settings = .{ .nthreads = 1 } });
    defer w.deinit();
    try r.phase(corpus, "initialize");
    try w.open(big, "fortran");
    try r.phase(corpus, "open");
    _ = try w.request("textDocument/documentSymbol", try w.docParams(big));
    try r.phase(corpus, "documentSymbol");
    _ = try w.request("textDocument/semanticTokens/full", try w.docParams(big));
    try r.phase(corpus, "semanticTokens");
    _ = try w.request("textDocument/diagnostic", try w.docParams(big));
    try r.phase(corpus, "diagnostics");
    const places = try sample(w.a(), w.text(big), 20);
    const methods = [_][]const u8{ "hover", "definition", "references", "completion" };
    for (methods) |m| {
        const method = try w.a().print("textDocument/{s}", .{m});
        for (places) |p| {
            var params = try w.posParams(big, p);
            if (std.mem.eql(u8, m, "references")) try params.object.put(w.a(), "context", try json.from(w.a(), .{ .includeDeclaration = true }));
            _ = try w.request(method, params);
        }
        try r.phase(corpus, m);
    }
    var text = try w.a().dupe(u8, w.text(big));
    for (0..10) |i| {
        // a blank typed or removed at the end of the first line, the file saved
        const at = std.mem.findScalar(u8, text, '\n') orelse break;
        const edited = try std.mem.concat(w.a(), u8, &.{ text[0..at], if (i % 2 == 0) " " else "", text[at..] });
        try w.replaceText(big, edited);
        text = edited;
    }
    try r.phase(corpus, "edits");
}

fn readFiles(a: Allocator, dir_path: []const u8) !?[]h.File {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var files: std.ArrayList(h.File) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const ext = std.Io.Dir.path.extension(e.name);
        if (!std.ascii.eqlIgnoreCase(ext, ".f90") and !std.ascii.eqlIgnoreCase(ext, ".f")) continue;
        try files.append(a, .{ .name = try a.dupe(u8, e.name), .text = try dir.readFileAlloc(io, e.name, a, .limited(1 << 26)) });
    }
    std.mem.sort(h.File, files.items, {}, struct {
        fn less(_: void, x: h.File, y: h.File) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return files.items;
}

fn largest(files: []const h.File) []const u8 {
    var best = files[0];
    for (files) |f| if (f.text.len > best.text.len) {
        best = f;
    };
    return best.name;
}

/// A module of `n` procedures that call each other: a large generated file
fn synthetic(a: Allocator, n: usize) ![]const h.File {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "module big\n  implicit none\n  integer :: counter = 0\ncontains\n");
    for (0..n) |i| {
        try text.print(a, "  subroutine s{d}(x, y)\n    real, intent(in) :: x\n    real, intent(out) :: y\n    integer :: k\n    y = 0.0\n    do k = 1, 3\n      y = y + x * real(k)\n    end do\n    counter = counter + 1\n", .{i});
        if (i > 0) try text.print(a, "    call s{d}(y, y)\n", .{i - 1});
        try text.print(a, "  end subroutine s{d}\n", .{i});
    }
    try text.appendSlice(a, "end module big\n");
    const files = try a.alloc(h.File, 1);
    files[0] = .{ .name = "big.f90", .text = text.items };
    return files;
}

/// An expression of `n` terms in one statement
fn longExpression(a: Allocator, n: usize) ![]const h.File {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  implicit none\n  integer :: x\n  x = 0");
    for (0..n) |i| try text.print(a, " + {d}", .{i % 10});
    try text.appendSlice(a, "\n  print *, x\nend program p\n");
    const files = try a.alloc(h.File, 1);
    files[0] = .{ .name = "expr.f90", .text = text.items };
    return files;
}

fn run(r: *Recorder) !void {
    const a = r.a;
    if (try readFiles(a, "vendor/M_intrinsics/src")) |files| {
        if (files.len > 0) try scenario(r, "m_intrinsics", files, largest(files));
    }
    if (try readFiles(a, "tests/fortran")) |files| try scenario(r, "tests_fortran", files, largest(files));
    try scenario(r, "synthetic", try synthetic(a, 1500), "big.f90");
    // (ZFLS_LONG_TERMS: another length, to measure, not for the baseline)
    const terms = if (std.testing.environ.getAlloc(a, "ZFLS_LONG_TERMS") catch null) |t| try std.fmt.parseInt(usize, t, 10) else 20000;
    try scenario(r, "long_expression", try longExpression(a, terms), "expr.f90");
}

fn over(now: u64, base: u64) bool {
    // (a little slack for what is too small to count)
    return @as(f64, @floatFromInt(now)) > @as(f64, @floatFromInt(base)) * tolerance + 50;
}

/// The peak depends on when the indexing threads run: more room, and
/// megabytes of slack
fn overPeak(now: u64, base: u64) bool {
    return @as(f64, @floatFromInt(now)) > @as(f64, @floatFromInt(base)) * 1.75 + 2.0e6;
}

test "allocation counts of the hot paths stay within the baseline (#902)" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const want = std.testing.environ.getAlloc(a, "ZFLS_ALLOC_SITES") catch null;
    var sites: counting.Sites = .{ .a = a };
    var counts: counting.Counts = .{ .server = .init(gpa), .request = .init(gpa), .sites = if (want != null) &sites else null };
    var r: Recorder = .{ .a = a, .counts = &counts, .prev = .{ .allocs = 0, .bytes = 0 }, .sites_of = want };
    try run(&r);

    if (std.testing.environ.contains(a, "ZFLS_BASELINE") catch false) {
        var out: json.ObjectMap = .empty;
        for (r.out.keys(), r.out.values()) |k, v| try out.put(a, k, try json.from(a, .{ .allocs = v.allocs, .bytes = v.bytes, .peak_bytes = v.peak }));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = try json.pretty(a, .{ .object = out }) });
        return;
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, baseline_path, a, .limited(1 << 20)) catch |e| {
        std.debug.print("\n{s}: {s} (zig build bench-baseline writes it)\n", .{ baseline_path, @errorName(e) });
        return e;
    };
    const base = try json.parse(a, text);
    var failed = false;
    for (r.out.keys(), r.out.values()) |k, v| {
        const b = json.get(base, k) orelse {
            std.debug.print("\n{s} is not in the baseline (zig build bench-baseline)\n", .{k});
            failed = true;
            continue;
        };
        const allocs: u64 = @intCast(json.int(json.get(b, "allocs")) orelse 0);
        const bytes: u64 = @intCast(json.int(json.get(b, "bytes")) orelse 0);
        const peak: u64 = @intCast(json.int(json.get(b, "peak_bytes")) orelse 0);
        if (over(v.allocs, allocs) or over(v.bytes, bytes) or overPeak(v.peak, peak)) {
            std.debug.print("\n{s}: {d} allocations, {d} bytes; baseline {d}, {d}\n", .{ k, v.allocs, v.bytes, allocs, bytes });
            std.debug.print("peak {d}, baseline {d}\n", .{ v.peak, peak });
            failed = true;
        } else if (v.allocs * 10 < allocs * 7 or v.bytes * 10 < bytes * 7) {
            std.debug.print("\nnote: {s} costs less now: {d} allocations, {d} bytes; baseline {d}, {d} (zig build bench-baseline)\n", .{ k, v.allocs, v.bytes, allocs, bytes });
        }
    }
    try std.testing.expect(!failed);
}
