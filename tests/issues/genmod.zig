//! ifort's and ifx's interface modules (`<name>__genmod.f90`, written with
//! `-warn interfaces` or `-gen-interfaces`) stay out of the workspace's
//! index (#284).

const std = @import("std");
const h = @import("harness.zig");

const genmod_text =
    \\        !COMPILER-GENERATED INTERFACE MODULE: Mon Jan 01 00:00:00 2018
    \\        MODULE FOO__genmod
    \\          INTERFACE
    \\            SUBROUTINE FOO(X)
    \\              INTEGER(KIND=4) :: X
    \\            END SUBROUTINE FOO
    \\          END INTERFACE
    \\        END MODULE FOO__genmod
    \\
;

const files = [_]h.File{
    .{ .name = "foo.f90", .text =
    \\subroutine foo(x)
    \\  implicit none
    \\  integer :: x
    \\  x = 1
    \\end subroutine foo
    \\
    },
    .{ .name = "foo__genmod.f90", .text = genmod_text },
    .{ .name = "main.f90", .text =
    \\program main
    \\  implicit none
    \\  integer :: i
    \\  call foo(i)
    \\end program main
    \\
    },
    .{ .name = "use.f90", .text =
    \\subroutine u()
    \\  use FOO__
    \\end subroutine u
    \\
    },
    // a hand-written file of that name
    .{ .name = "x__genmod.f90", .text =
    \\module x_hand
    \\contains
    \\  subroutine x_sub()
    \\  end subroutine x_sub
    \\end module x_hand
    \\
    },
};

fn expectSymbols(w: *h.Workspace, query: []const u8, want: []const []const u8) !void {
    const got = try w.workspaceSymbolInfos(query);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    for (got) |s| {
        try names.append(std.testing.allocator, s.name);
        try std.testing.expect(std.mem.find(u8, s.uri, "foo__genmod") == null);
    }
    if (names.items.len != want.len) {
        std.debug.print("\nsymbols of '{s}': {any}\n", .{ query, names.items });
        return error.TestExpectedEqual;
    }
    for (names.items, want) |g, x| try std.testing.expectEqualStrings(x, g);
}

test "ifort's interface modules are not indexed (#284)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try expectSymbols(w, "foo", &.{"foo"});
    try expectSymbols(w, "genmod", &.{});
    // a hand-written __genmod.f90 is
    try expectSymbols(w, "x_hand", &.{"x_hand"});
    // nor offered after USE
    for (try w.completion("use.f90", w.pos("use.f90", "FOO__", 0, 5))) |label| {
        try std.testing.expect(std.ascii.findIgnoreCase(label, "genmod") == null);
    }
    // the call goes to the source
    const d = (try w.definition("main.f90", w.pos("main.f90", "foo(i)", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expect(std.mem.endsWith(u8, d.uri, "/foo.f90"));
}

test "an interface module written after start is not indexed (#284)" {
    const w = try h.Workspace.init(files[0..3], .{});
    defer w.deinit();
    try w.changeOnDisk("bar__genmod.f90", genmod_text);
    try expectSymbols(w, "foo", &.{"foo"});
}

test "an interface module opened in the editor is served (#284)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("foo__genmod.f90", "fortran");
    const symbols = try w.documentSymbols("foo__genmod.f90");
    try std.testing.expect(symbols.len > 0);
    for (try w.diagnostics("foo__genmod.f90")) |d| try std.testing.expect(d.severity != 1);
}
