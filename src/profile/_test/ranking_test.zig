const std = @import("std");
const ranking = @import("../ranking.zig");

test "exclusive and inclusive ranking, recursion counted once" {
    const a = std.testing.allocator;
    var p: ranking.Profile = .init(a);
    defer p.deinit();
    try p.add(&.{ "parse", "index", "main" });
    try p.add(&.{ "parse", "index", "main" });
    try p.add(&.{ "parse", "parse", "index", "main" });
    try p.add(&.{ "hover", "main" });

    const ex = try p.rank(a, false);
    defer a.free(ex);
    try std.testing.expectEqualStrings("parse", ex[0].name);
    try std.testing.expectEqual(@as(u64, 3), ex[0].count);
    try std.testing.expectEqualStrings("hover", ex[1].name);

    const inc = try p.rank(a, true);
    defer a.free(inc);
    try std.testing.expectEqualStrings("main", inc[0].name);
    try std.testing.expectEqual(@as(u64, 4), inc[0].count);
    try std.testing.expectEqualStrings("index", inc[1].name);
    try std.testing.expectEqual(@as(u64, 3), inc[1].count);
    try std.testing.expectEqual(@as(u64, 3), inc[2].count);
    try std.testing.expectEqualStrings("parse", inc[2].name);
}

test "folded output runs from the root to the leaf" {
    const a = std.testing.allocator;
    var p: ranking.Profile = .init(a);
    defer p.deinit();
    try p.add(&.{ "b", "a" });
    try p.add(&.{ "b", "a" });
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try p.writeFolded(&out.writer);
    try std.testing.expectEqualStrings("a;b 2\n", out.written());
}

test "ranking report lists both tables" {
    const a = std.testing.allocator;
    var p: ranking.Profile = .init(a);
    defer p.deinit();
    try p.add(&.{ "f", "main" });
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try p.writeRanking(a, &out.writer, 10);
    try std.testing.expect(std.mem.find(u8, out.written(), "samples: 1") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "100.00%  f") != null);
}
