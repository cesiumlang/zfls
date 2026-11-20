//! Unused local variables and USE ONLY names: shown faded, and the quick
//! fixes that remove their declarations.

const std = @import("std");
const h = @import("harness.zig");
const edits = @import("edits.zig");

const unused_names = [_]h.File{
    .{ .name = "consts.f90", .text =
    \\module consts
    \\  implicit none
    \\  integer, parameter :: sp = kind(1.0), dp = kind(1.d0)
    \\  integer :: shared_count
    \\end module consts
    \\
    },
    .{ .name = "u.F90", .text =
    \\module work
    \\  implicit none
    \\  integer :: module_level
    \\contains
    \\  real function area(r) result(res)
    \\    use consts, only: sp, dp
    \\    real(dp), intent(in) :: r
    \\    real :: scratch
    \\    integer :: used_inside, only_in_ifdef
    \\    integer :: n = 2, m
    \\    m = n * 2
    \\    used_inside = 1
    \\#ifdef DEBUG
    \\    only_in_ifdef = 1
    \\#endif
    \\    res = r * r * helper()
    \\  contains
    \\    real function helper()
    \\      helper = real(used_inside)
    \\    end function helper
    \\  end function area
    \\end module work
    \\
    },
};

fn expectUnused(w: *h.Workspace) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    for (try w.diagnostics("u.F90")) |d| {
        if (!std.mem.eql(u8, d.code, "unused-name")) continue;
        try h.expect(d.severity == 4, "severity {d}", .{d.severity});
        try names.append(std.testing.allocator, d.message);
    }
    // sp (USE ONLY) and scratch only: not the argument, the result, a name
    // a contained procedure uses, one in an inactive #ifdef branch, n used
    // in m's declaration, or the module's names
    try h.expect(names.items.len == 2, "unused: {any}", .{names.items});
    try h.expect(std.mem.find(u8, names.items[0], "\"scratch\"") != null or std.mem.find(u8, names.items[1], "\"scratch\"") != null, "{any}", .{names.items});
    try h.expect(std.mem.find(u8, names.items[0], "\"sp\"") != null or std.mem.find(u8, names.items[1], "\"sp\"") != null, "{any}", .{names.items});
    // the quick fix removes a declaration of that name only
    const line = w.pos("u.F90", "real :: scratch", 0, 0).line;
    for (try w.codeActions("u.F90", line)) |act| {
        if (std.mem.eql(u8, act.title, "Remove unused scratch")) {
            try h.expect(act.line == line and act.new_text.len == 0, "removes line {d}", .{act.line});
            return;
        }
    }
    return h.unmet("no quick fix removing scratch", .{});
}

test "unused local variables and USE ONLY names are shown faded, with a quick fix" {
    const w = try h.Workspace.init(&unused_names, .{});
    defer w.deinit();
    try expectUnused(w);
}

const unused_decls =
    \\module m
    \\  implicit none
    \\  integer, parameter :: k1 = 1, k2 = 2
    \\end module m
    \\
    \\subroutine work(x, unused_arg)
    \\  use m, only: k1, k2
    \\  implicit none
    \\  real, intent(inout) :: x
    \\  real, intent(in) :: unused_arg
    \\  real :: alone
    \\  integer :: i, spare, j
    \\  real, dimension(3) :: arr = [1., 2., 3.], w(2) = 0., &
    \\                        tail
    \\  i = 1
    \\  j = 2
    \\  x = x + real(i + j + k1)
    \\  print *, arr
    \\end subroutine work
    \\
;

/// That the quick fix `title` on the line of `needle` makes `unused_decls`
/// into the text with each of `cut` replaced by what follows it
fn expectRemoval(w: *h.Workspace, needle: []const u8, only: ?[]const []const u8, title: []const u8, cut: []const [2][]const u8) !void {
    const a = std.testing.allocator;
    const line = w.pos("w.f90", needle, 0, 0).line;
    const got = (try edits.applyAction(w, "w.f90", line, line, only, title)) orelse return h.unmet("no action \"{s}\"", .{title});
    var want: []const u8 = try a.dupe(u8, unused_decls);
    defer a.free(want);
    for (cut) |c| {
        const next = try std.mem.replaceOwned(u8, a, want, c[0], c[1]);
        a.free(want);
        want = next;
    }
    try h.expect(std.mem.eql(u8, got, want), "{s} gives\n{s}", .{ title, got });
    try edits.expectCompiles(w, &.{.{ .name = "w.f90", .text = got }});
}

fn expectRemovals(w: *h.Workspace) !void {
    try expectRemoval(w, "real :: alone", null, "Remove unused alone", &.{.{ "  real :: alone\n", "" }});
    try expectRemoval(w, "integer :: i, spare", null, "Remove unused spare", &.{.{ "i, spare, j", "i, j" }});
    try expectRemoval(w, "use m, only", null, "Remove unused k2", &.{.{ "only: k1, k2", "only: k1" }});
    // with its dimensions and initialization, across a continuation
    try expectRemoval(w, "arr = [", null, "Remove unused w", &.{.{ "w(2) = 0., &\n                        tail", "tail" }});
    try expectRemoval(w, "  tail", null, "Remove unused tail", &.{.{ "w(2) = 0., &\n                        tail", "w(2) = 0." }});
    // all of them at once
    try expectRemoval(w, "module m", &.{"source"}, "Remove all unused declarations", &.{
        .{ "  real :: alone\n", "" },
        .{ "i, spare, j", "i, j" },
        .{ "only: k1, k2", "only: k1" },
        .{ ", w(2) = 0., &\n                        tail", "" },
    });
    // removing a dummy argument would change the interface
    const arg = w.pos("w.f90", "unused_arg\n", 0, 0).line;
    for (try w.codeActions("w.f90", arg)) |act| {
        if (std.mem.find(u8, act.title, "unused_arg") != null) return h.unmet("offers {s}", .{act.title});
    }
}

test "quick fixes remove unused declarations" {
    const w = try h.Workspace.init(&.{.{ .name = "w.f90", .text = unused_decls }}, .{});
    defer w.deinit();
    expectRemovals(w) catch |e| {
        std.debug.print("\n{s}\n", .{h.lastNote()});
        return e;
    };
}
