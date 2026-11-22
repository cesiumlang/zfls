//! The settings of the C side of `BIND(C)` procedures (#741):
//! `disable_bind_c_search` turns the search of the workspace's C files off,
//! and `bind_c_clangd` names a clangd that zfls starts (a stand-in here
//! that logs its arguments; bind_c_clangd.zig asks a real one).

const std = @import("std");
const h = @import("harness.zig");
const tools = @import("tools.zig");

const header = h.File{ .name = "cfuncs.h", .text = "int c_add(int a, int b);\n" };
const csource = h.File{ .name = "cfuncs.c", .text = "#include \"cfuncs.h\"\nint c_add(int a, int b) { return a + b; }\n" };
const iface = h.File{ .name = "iface.f90", .text =
    \\module iface
    \\  use iso_c_binding
    \\  interface
    \\    integer(c_int) function c_add(a, b) bind(C, name="c_add")
    \\      import :: c_int
    \\      integer(c_int), value :: a, b
    \\    end function c_add
    \\  end interface
    \\contains
    \\  subroutine call_it()
    \\    print *, c_add(1, 2)
    \\  end subroutine call_it
    \\end module iface
    \\
};

const clangd = tools.logging("clangd", "started", false);

/// The places go to definition gives for the call of `c_add`
fn definitionsOfCall(comptime options: []const u8) !usize {
    const w = try h.Workspace.init(&.{ header, csource, iface }, .{ .init_options = options });
    defer w.deinit();
    return (try w.definitions("iface.f90", w.pos("iface.f90", "c_add(1", 0, 1))).len;
}

test "disable_bind_c_search: go to definition of a BIND(C) procedure leaves the C files out (#741)" {
    // the interface, the prototype and the definition
    try std.testing.expectEqual(@as(usize, 3), try definitionsOfCall("{}"));
    try std.testing.expectEqual(@as(usize, 1), try definitionsOfCall("{\"disable_bind_c_search\": true}"));
}

/// Whether the stand-in clangd was started once `bind_c_clangd` named it,
/// `disabled` with `disable_bind_c_search`
fn clangdStarted(disabled: bool) !bool {
    const w = try h.Workspace.init(&.{ header, csource, iface, clangd }, .{});
    defer w.deinit();
    try tools.makeExecutable(w, &.{clangd});
    // its absolute path: zfls runs it as given
    const exe = try w.path(clangd.name);
    try w.changeConfiguration(try w.a().print("{{\"bind_c_clangd\": {f}, \"disable_bind_c_search\": {}}}", .{ std.json.fmt(exe, .{}), disabled }));
    return (try tools.waitForRuns(w, "clangd", "--background-index", 1, if (disabled) 3 else 60)).len > 0;
}

test "bind_c_clangd starts that clangd, unless disable_bind_c_search is set (#741)" {
    try std.testing.expect(try clangdStarted(false));
    try std.testing.expect(!try clangdStarted(true));
}
