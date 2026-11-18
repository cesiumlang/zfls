//! The documentation of completion items, sent when an item is resolved
//! (`completionItem/resolve`) to a client that resolves it (#217).

const std = @import("std");
const h = @import("harness.zig");
const json = h.json;
const Value = json.Value;

const files = [_]h.File{
    .{ .name = "shapes.f90", .text =
    \\module shapes
    \\  implicit none
    \\contains
    \\  !> The area of a circle
    \\  real function circle_area(radius)
    \\    real, intent(in) :: radius
    \\    circle_area = 3.14159 * radius**2
    \\  end function circle_area
    \\  !> The area of a square
    \\  real function square_area(side)
    \\    real, intent(in) :: side
    \\    square_area = side**2
    \\  end function square_area
    \\end module shapes
    \\
    },
    .{ .name = "main.f90", .text =
    \\program main
    \\  use shapes
    \\  use iso_fortran_env, only: int32
    \\  implicit none
    \\  !> how big
    \\  real :: size_of_it
    \\  integer(int32) :: n
    \\  size_of_it = circle_area(1.0) + square_area(2.0)
    \\  n = int(si
    \\end program main
    \\
    },
};

/// The completion items (JSON) at the `nth` occurrence of `needle`
/// in main.f90, after it
fn items(w: *h.Workspace, a: std.mem.Allocator, needle: []const u8, nth: usize) ![]Value {
    const p = w.pos("main.f90", needle, nth, needle.len);
    return json.items(try w.server.dispatchPublic(a, "textDocument/completion", try w.positionOf("main.f90", p)));
}

fn doc(item: Value) ?[]const u8 {
    return json.str(json.path(item, &.{ "documentation", "value" }));
}

/// The item resolved, sent as a client would: as JSON text
fn resolve(w: *h.Workspace, a: std.mem.Allocator, item: Value) !Value {
    return resolveText(w, a, try json.stringify(a, item));
}

fn resolveText(w: *h.Workspace, a: std.mem.Allocator, item: []const u8) !Value {
    return w.server.dispatchPublic(a, "completionItem/resolve", try json.parse(a, item));
}

/// The places to complete at, with what each completes: procedures of a
/// module, a variable, intrinsic procedures (`si`), a name of an
/// intrinsic module (`only: int`) and statement keywords (`rea`)
const places = [_]struct { needle: []const u8, nth: usize }{
    .{ .needle = "circle", .nth = 0 },
    .{ .needle = "squ", .nth = 0 },
    .{ .needle = "size_of", .nth = 1 },
    .{ .needle = "si", .nth = 2 },
    .{ .needle = "only: int", .nth = 0 },
    .{ .needle = "  rea", .nth = 0 },
};

test "with resolve support, items leave their documentation to completionItem/resolve (#217)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try h.Workspace.init(&files, .{});
    defer full.deinit();
    const lazy = try h.Workspace.init(&files, .{ .completion_resolve = true });
    defer lazy.deinit();
    try std.testing.expectEqual(false, json.path(full.init_result, &.{ "capabilities", "completionProvider", "resolveProvider" }).?.bool);
    try std.testing.expectEqual(true, json.path(lazy.init_result, &.{ "capabilities", "completionProvider", "resolveProvider" }).?.bool);
    var documented: usize = 0;
    for (places) |place| {
        const want = try items(full, a, place.needle, place.nth);
        const got = try items(lazy, a, place.needle, place.nth);
        try std.testing.expect(want.len > 0);
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |wi, gi| {
            const label = json.str(json.get(wi, "label")).?;
            try std.testing.expectEqualStrings(label, json.str(json.get(gi, "label")).?);
            // the same details, no documentation
            try std.testing.expectEqualStrings(json.str(json.get(wi, "detail")).?, json.str(json.get(gi, "detail")).?);
            try std.testing.expect(json.get(wi, "data") == null);
            try std.testing.expect(doc(gi) == null);
            const resolved = try resolve(lazy, a, gi);
            if (doc(wi)) |d| {
                documented += 1;
                const rd = doc(resolved) orelse {
                    std.debug.print("\nno documentation resolved for {s}\n", .{label});
                    return error.TestUnexpectedResult;
                };
                try std.testing.expectEqualStrings(d, rd);
            } else try std.testing.expect(doc(resolved) == null);
        }
    }
    try std.testing.expect(documented >= places.len);
}

test "an item resolves after its file changed (#217)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .completion_resolve = true });
    defer w.deinit();
    const got = try items(w, a, "circle", 0);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expect(doc(got[0]) == null);
    // the item as the client has it (its strings are the server's until sent)
    const sent = try json.stringify(a, got[0]);
    // two lines more above the function
    try w.replaceText("shapes.f90", try std.mem.concat(a, u8, &.{ "! shapes\n! of all kinds\n", w.text("shapes.f90") }));
    const d = doc(try resolveText(w, a, sent)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, d, "The area of a circle") != null);
}

test "an item whose object is gone resolves to itself (#217)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .completion_resolve = true });
    defer w.deinit();
    const got = try items(w, a, "circle", 0);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expect(doc(got[0]) == null);
    // the item as the client has it (its strings are the server's until sent)
    const sent = try json.stringify(a, got[0]);
    try w.replaceText("shapes.f90", "module shapes\nend module shapes\n");
    const resolved = try resolveText(w, a, sent);
    try std.testing.expect(doc(resolved) == null);
    try std.testing.expectEqualStrings("circle_area", json.str(json.get(resolved, "label")).?);
}
