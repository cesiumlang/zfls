//! Document highlights are the document's own places (#781).

const std = @import("std");
const h = @import("harness.zig");

test "a document highlight stays in the document, with the other files' uses left out (#781)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "sub.f90", .text = "subroutine sub()\nend subroutine sub\n" },
        .{ .name = "a.f90", .text = "subroutine a()\n  call sub()\n  call sub()\nend subroutine a\n" },
        .{ .name = "b.f90", .text = "subroutine b()\n  call sub()\nend subroutine b\n" },
    }, .{});
    defer w.deinit();
    const at = w.pos("a.f90", "call sub", 0, 6);
    // references: the definition, its end and the three calls
    try std.testing.expectEqual(@as(usize, 5), (try w.references("a.f90", at)).len);
    const hl = try w.request("textDocument/documentHighlight", try w.posParams("a.f90", at));
    try std.testing.expectEqual(@as(usize, 2), h.json.items(hl).len);
    for (h.json.items(hl)) |item| try std.testing.expect(std.mem.endsWith(u8, h.json.str(h.json.get(item, "uri")).?, "a.f90"));
}
