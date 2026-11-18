//! Names that USE statements make visible: through modules that use others
//! in turn, and what those modules pass on.

const std = @import("std");
const h = @import("harness.zig");

const facade = [_]h.File{.{ .name = "a.f90", .text =
    \\module base
    \\  implicit none
    \\  integer :: shared_var, hidden_var
    \\contains
    \\  subroutine hidden_sub()
    \\  end subroutine
    \\end module
    \\module middle
    \\  use base
    \\  implicit none
    \\  private
    \\  public :: shared_var
    \\end module
    \\module hidden
    \\  use base
    \\  implicit none
    \\  private
    \\end module
    \\program main
    \\  use middle
    \\  implicit none
    \\  integer :: mine
    \\  shared_var = 1
    \\  hidden_var = 2
    \\  call hidden_sub()
    \\  mine = hid
    \\contains
    \\  subroutine inner()
    \\    integer :: hidden_var
    \\    hidden_var = 0
    \\  end subroutine
    \\end program
    \\subroutine other()
    \\  use hidden
    \\  implicit none
    \\  shared_var = 3
    \\end subroutine
    \\
}};

fn undeclared(w: *h.Workspace, file: []const u8, name: []const u8, line: i64) !bool {
    const want = try std.testing.allocator.print("Name \"{s}\" is not declared", .{name});
    defer std.testing.allocator.free(want);
    for (try w.diagnostics(file)) |d| {
        if (d.line == line and std.mem.startsWith(u8, d.message, want)) return true;
    }
    return false;
}

test "a module whose default is PRIVATE passes on only the used names it makes PUBLIC (#235)" {
    const w = try h.Workspace.init(&facade, .{});
    defer w.deinit();
    // through `middle`, `shared_var` and nothing else of `base`
    try w.expectHoverContains("a.f90", w.pos("a.f90", "shared_var = 1", 0, 0), "INTEGER :: shared_var");
    try std.testing.expect(try w.hover("a.f90", w.pos("a.f90", "hidden_var = 2", 0, 0)) == null);
    try std.testing.expect(try w.hover("a.f90", w.pos("a.f90", "hidden_sub()", 1, 0)) == null);
    try std.testing.expect(try undeclared(w, "a.f90", "hidden_var", 23));
    try std.testing.expect(!try undeclared(w, "a.f90", "shared_var", 22));
    // `hidden` passes on nothing
    try std.testing.expect(try w.hover("a.f90", w.pos("a.f90", "shared_var = 3", 0, 0)) == null);
    try std.testing.expect(try undeclared(w, "a.f90", "shared_var", 35));
    // a local declaration masks nothing of `base`
    for (try w.diagnostics("a.f90")) |d| try std.testing.expect(std.mem.find(u8, d.message, "masks") == null);
}

test "completion offers no used name that a PRIVATE module keeps (#235)" {
    const w = try h.Workspace.init(&facade, .{});
    defer w.deinit();
    for (try w.completionItems("a.f90", w.pos("a.f90", "= hid", 0, 5))) |item| {
        // offered with a USE of `base` added is another thing
        if (item.added != null) continue;
        try std.testing.expect(!std.mem.startsWith(u8, item.label, "hidden_"));
    }
}

test "a PRIVATE statement hides one used name; USE ONLY does not reach a hidden one (#235)" {
    const w = try h.Workspace.init(&.{.{ .name = "b.f90", .text =
        \\module base
        \\  implicit none
        \\  integer :: shared_var, hidden_var
        \\end module
        \\module middle
        \\  use base
        \\  implicit none
        \\  private :: hidden_var
        \\end module
        \\module closed
        \\  use base
        \\  implicit none
        \\  private
        \\end module
        \\program main
        \\  use middle
        \\  implicit none
        \\  shared_var = 1
        \\  hidden_var = 2
        \\end program
        \\subroutine s()
        \\  use closed, only: hidden_var
        \\  implicit none
        \\  hidden_var = 3
        \\end subroutine
        \\subroutine t()
        \\  use closed, only: hid
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("b.f90", w.pos("b.f90", "shared_var = 1", 0, 0), "INTEGER :: shared_var");
    try std.testing.expect(try w.hover("b.f90", w.pos("b.f90", "hidden_var = 2", 0, 0)) == null);
    try std.testing.expect(try w.hover("b.f90", w.pos("b.f90", "hidden_var = 3", 0, 0)) == null);
    for (try w.completion("b.f90", w.pos("b.f90", "only: hid", 0, 9))) |label| {
        try std.testing.expect(!std.mem.startsWith(u8, label, "hidden_"));
    }
}
