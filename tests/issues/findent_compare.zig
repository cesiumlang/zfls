//! zfls's own formatter beside findent (#986): the corpus indented by both,
//! 3 blanks a level, and the lines they indent differently counted and
//! shown, for the choice of the default formatter. A measure, not a check:
//! it fails only when findent cannot be run (where CI installs it).

const std = @import("std");
const h = @import("harness.zig");
const tools = @import("tools.zig");
const formatted = @import("harness_format.zig").formatted;

const io = std.testing.io;

test "zfls's indentation beside findent's, over the corpus (#986)" {
    try tools.need("findent");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fortran", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var lines_total: usize = 0;
    var differ_total: usize = 0;
    var report: std.ArrayList(u8) = .empty;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !(std.mem.endsWith(u8, e.name, ".f90") or std.mem.endsWith(u8, e.name, ".F90") or std.mem.endsWith(u8, e.name, ".f"))) continue;
        const text = try dir.readFileAlloc(io, e.name, a, .limited(1 << 22));
        const ours = try formattedWith(a, e.name, text, "{\"formatter\": \"zfls\", \"formatter_args\": [\"--indent\", \"3\"]}");
        const theirs = try formattedWith(a, e.name, text, "{\"formatter\": \"findent\", \"formatter_args\": [\"-i3\"]}");
        var o = std.mem.splitScalar(u8, ours, '\n');
        var t = std.mem.splitScalar(u8, theirs, '\n');
        var n: usize = 0;
        var differ: usize = 0;
        while (o.next()) |ol| {
            const tl = t.next() orelse "";
            n += 1;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, ol, " \r"), std.mem.trimEnd(u8, tl, " \r"))) continue;
            differ += 1;
            if (differ <= 5) try report.print(a, "  {s}:{d}\n    zfls:    |{s}\n    findent: |{s}\n", .{ e.name, n, ol, tl });
        }
        try report.print(a, "{s}: {d} of {d} lines indented differently\n", .{ e.name, differ, n });
        lines_total += n;
        differ_total += differ;
    }
    std.debug.print("\nzfls beside findent -i3:\n{s}total: {d} of {d} lines indented differently\n", .{ report.items, differ_total, lines_total });
}

fn formattedWith(a: std.mem.Allocator, name: []const u8, text: []const u8, options: []const u8) ![]const u8 {
    const w = try h.Workspace.init(&.{.{ .name = name, .text = text }}, .{ .init_options = options });
    defer w.deinit();
    return a.dupe(u8, try formatted(w, name));
}
