//! Upstream issues about the workspace: indexing, configuration and
//! incremental updates.

const std = @import("std");
const h = @import("harness.zig");

test "#565 editing a file that is included by an include file" {
    const w = try h.Workspace.init(&.{
        .{ .name = "prog.f90", .text =
        \\program prog
        \\  implicit none
        \\  include 'mid.f90'
        \\  x = 1
        \\end program prog
        \\
        },
        .{ .name = "mid.f90", .text =
        \\include 'leaf.f90'
        \\
        },
        .{ .name = "leaf.f90", .text =
        \\integer :: x
        \\
        },
    }, .{ .settings = .{ .incremental_sync = true } });
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        // open leaf.f90, change its text and save it
        w.replaceText("leaf.f90", "integer :: x, y\n") catch |e| break :blk h.unmet("the change failed: {s}", .{@errorName(e)});
        for (try w.messages()) |m| {
            if (std.mem.indexOf(u8, m, "failed") != null) break :blk h.unmet("the server reported: {s}", .{m});
        }
        break :blk {};
    };
    try h.check(565, .fixed, outcome);
}

test "#536 a configuration file does not discard the preprocessor definitions given on the command line" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text = "{}\n" },
        .{ .name = "main.F90", .text =
        \\#ifdef HAVE_FOO
        \\module foo_mod
        \\  implicit none
        \\end module foo_mod
        \\#endif
        \\program p
        \\end program p
        \\
        },
    }, .{ .pp_defs = &.{.{ .name = "HAVE_FOO", .value = "1" }} });
    defer w.deinit();
    const syms = try w.workspaceSymbols("foo_mod");
    try h.check(536, .known_failure, h.expect(syms.len > 0, "foo_mod is not found: the config file dropped --pp_defs", .{}));
}
