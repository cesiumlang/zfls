//! `doc_math` (#272): the formulas of documentation comments in hover,
//! completion (also when an item is resolved, #369) and signature help.

const std = @import("std");
const h = @import("harness.zig");

const source = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\   implicit none
    \\contains
    \\   !> Kinetic energy \f$ E = \frac{1}{2} m v^2 \f$, or
    \\   !> \f[ E = \int F \, dx \f]
    \\   real function energy(v)
    \\      real, intent(in) :: v !! FORD style: \( v \ge 0 \)
    \\      energy = v
    \\   end function
    \\   subroutine u()
    \\      real :: e
    \\      e = energy(1.0)
    \\   end subroutine
    \\end module
    \\
}};

fn docsOf(w: *h.Workspace) ![]const u8 {
    const got = (try w.hover("m.f90", w.pos("m.f90", "function energy", 0, 9))) orelse return error.NoHover;
    const at = std.mem.find(u8, got, "\n-----\n") orelse return error.NoDocs;
    return got[at + 7 ..];
}

test "doc_math keep: formulas as written (#272)" {
    const w = try h.Workspace.init(&source, .{});
    defer w.deinit();
    const docs = try docsOf(w);
    try std.testing.expect(std.mem.startsWith(u8, docs, "Kinetic energy \\f$ E = \\frac{1}{2} m v^2 \\f$, or\n\\f[ E = \\int F \\, dx \\f]\n"));
    try std.testing.expect(std.mem.find(u8, docs, "`v` FORD style: \\( v \\ge 0 \\)") != null);
}

test "doc_math dollar: $x$ and $$x$$ (#272)" {
    const w = try h.Workspace.init(&source, .{ .settings = .{ .doc_math = "dollar" } });
    defer w.deinit();
    const docs = try docsOf(w);
    try std.testing.expect(std.mem.startsWith(u8, docs, "Kinetic energy $E = \\frac{1}{2} m v^2$, or\n$$E = \\int F \\, dx$$\n"));
    try std.testing.expect(std.mem.find(u8, docs, "`v` FORD style: $v \\ge 0$") != null);
}

test "doc_math plain: in backticks, also in completion and signature help (#272)" {
    const w = try h.Workspace.init(&source, .{ .settings = .{ .doc_math = "plain", .use_signature_help = true } });
    defer w.deinit();
    const docs = try docsOf(w);
    try std.testing.expect(std.mem.startsWith(u8, docs, "Kinetic energy `E = \\frac{1}{2} m v^2`, or\n`E = \\int F \\, dx`\n"));
    try std.testing.expect(std.mem.find(u8, docs, "`v` FORD style: `v \\ge 0`") != null);
    const a = std.testing.allocator;
    const position = w.pos("m.f90", "energy(1.0)", 0, 3);
    const comp = try w.zflsRequest("textDocument/completion", .{
        .textDocument = .{ .uri = try w.uri("m.f90") },
        .position = .{ .line = position.line, .character = position.col },
    });
    const comp_text = try h.json.stringify(a, comp);
    defer a.free(comp_text);
    try std.testing.expect(std.mem.find(u8, comp_text, "`E = \\\\frac{1}{2} m v^2`") != null);
    try std.testing.expect(std.mem.find(u8, comp_text, "\\\\f$") == null);
    const at = w.pos("m.f90", "energy(1.0)", 0, 8);
    const sig = try w.zflsRequest("textDocument/signatureHelp", .{
        .textDocument = .{ .uri = try w.uri("m.f90") },
        .position = .{ .line = at.line, .character = at.col },
    });
    const sig_text = try h.json.stringify(a, sig);
    defer a.free(sig_text);
    try std.testing.expect(std.mem.find(u8, sig_text, "`v \\\\ge 0`") != null);
    try std.testing.expect(std.mem.find(u8, sig_text, "\\\\f$") == null);
}

/// The documentation of `energy`'s completion item at its call, filled in
/// by `completionItem/resolve` (the item itself has none)
fn resolvedDocs(w: *h.Workspace, a: std.mem.Allocator) ![]const u8 {
    const position = w.pos("m.f90", "energy(1.0)", 0, 3);
    const items = h.json.items(try w.server.dispatchPublic(a, "textDocument/completion", try w.positionOf("m.f90", position)));
    const item = for (items) |it| {
        if (std.mem.eql(u8, h.json.str(h.json.get(it, "label")) orelse "", "energy")) break it;
    } else return error.NoItem;
    try std.testing.expect(h.json.get(item, "documentation") == null);
    // as the client sends it back: JSON text
    const resolved = try w.server.dispatchPublic(a, "completionItem/resolve", try h.json.parse(a, try h.json.stringify(a, item)));
    return h.json.str(h.json.path(resolved, &.{ "documentation", "value" })) orelse error.NoDocs;
}

test "doc_math in the documentation of a resolved completion item (#369)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // off: as written
    {
        const w = try h.Workspace.init(&source, .{ .completion_resolve = true });
        defer w.deinit();
        const docs = try resolvedDocs(w, a);
        try std.testing.expect(std.mem.find(u8, docs, "\\f$ E = \\frac{1}{2} m v^2 \\f$") != null);
    }
    // plain and dollar: rewritten
    {
        const w = try h.Workspace.init(&source, .{ .completion_resolve = true, .settings = .{ .doc_math = "plain" } });
        defer w.deinit();
        const docs = try resolvedDocs(w, a);
        try std.testing.expect(std.mem.find(u8, docs, "`E = \\frac{1}{2} m v^2`") != null);
        try std.testing.expect(std.mem.find(u8, docs, "\\f$") == null);
        try std.testing.expect(std.mem.find(u8, docs, "\\f[") == null);
    }
    {
        const w = try h.Workspace.init(&source, .{ .completion_resolve = true, .settings = .{ .doc_math = "dollar" } });
        defer w.deinit();
        const docs = try resolvedDocs(w, a);
        try std.testing.expect(std.mem.find(u8, docs, "$E = \\frac{1}{2} m v^2$") != null);
        try std.testing.expect(std.mem.find(u8, docs, "$$E = \\int F \\, dx$$") != null);
        try std.testing.expect(std.mem.find(u8, docs, "\\f$") == null);
    }
}
