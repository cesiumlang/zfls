//! Intel's ifx and ifort in the compiler check (compilers.zig): what their
//! drivers need beyond the options of the other compilers.

const std = @import("std");
const compilers = @import("../compilers.zig");

/// Before the file, as its language: the driver checks only `.f`, `.for`,
/// `.ftn`, `.fpp`, `.f90` (and `.F`, `.F90`), and takes a file of another
/// suffix (`.f95`, `.f03`, `.f08`, `.f18`, `.f23`, `.f77`, `.pf`) for an
/// object ("command line warning #10161: unrecognized source type ...;
/// object file assumed"), which it does not check. With `/Tf <file>` (`-Tf
/// <file>` on Linux) the file is Fortran source whatever its suffix; `/fpp`
/// still preprocesses it, and `/free` and `/fixed` still hold (ifx 2026.2).
pub fn language(o: compilers.Options) []const []const u8 {
    return if (o.windows) &.{"/Tf"} else &.{"-Tf"};
}

test "the file's language: /Tf or -Tf right before it for ifx and ifort" {
    const win: compilers.Options = .{ .windows = true, .mod_dir = "m" };
    const linux: compilers.Options = .{ .windows = false, .mod_dir = "m" };
    try std.testing.expectEqualStrings("/Tf", compilers.language(.ifx, win)[0]);
    try std.testing.expectEqualStrings("-Tf", compilers.language(.ifx, linux)[0]);
    try std.testing.expectEqualStrings("-Tf", compilers.language(.ifort, linux)[0]);
    try std.testing.expectEqual(@as(usize, 1), compilers.language(.ifort, win).len);
}
