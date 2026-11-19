//! The extensions of Fortran sources indexed by default (#250): every one
//! zfls reads as Fortran, from one table (src/suffixes.zig).

const std = @import("std");
const h = @import("harness.zig");

test "modules of .f23 and .ftn files are found (#250)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f23", .text =
        \\module m23
        \\  implicit none
        \\  integer :: v23 = 1
        \\end module m23
        \\
        },
        .{ .name = "mt.ftn", .text =
        \\      module mtn
        \\      implicit none
        \\      integer :: vtn = 1
        \\      end module mtn
        \\
        },
        .{ .name = "a.f90", .text =
        \\program p
        \\  use m23
        \\  use mtn
        \\  implicit none
        \\  print *, v23, vtn
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try w.open("a.f90", "fortran");
    const diags = try w.diagnostics("a.f90");
    for (diags) |d| std.debug.print("\n{d}: {s}\n", .{ d.line, d.message });
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "workspace symbols of every Fortran extension (#250)" {
    const exts = [_][]const u8{ "f23", "pf", "fypp", "ftn", "f05", "f90" };
    var files: [exts.len]h.File = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (exts, &files) |ext, *f| {
        // fixed form for .ftn
        const indent = if (std.mem.eql(u8, ext, "ftn")) "      " else "";
        f.* = .{ .name = try a.print("a.{s}", .{ext}), .text = try a.print("{s}subroutine zz_a_{s}()\n{s}end subroutine zz_a_{s}\n", .{ indent, ext, indent, ext }) };
    }
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const got = try w.workspaceSymbols("zz_");
    for (exts) |ext| {
        const name = try a.print("zz_a_{s}", .{ext});
        for (got) |g| {
            if (std.mem.eql(u8, g, name)) break;
        } else {
            std.debug.print("\n{s} not in {any}\n", .{ name, got });
            return error.TestExpectedEqual;
        }
    }
}
