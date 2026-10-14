//! The version zfls reports. Debug builds report build.zig.zon's version
//! with `-dev`. Release builds report it with `-rc` while a
//! `zfls.prerelease` file sits next to the executable, which the build
//! always installs there, and as it is without one: release archives leave
//! the file out, so the binary CI tested is published unchanged.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Name of the file whose presence next to a release build's executable
/// marks a release candidate.
pub const sentinel_name = "zfls.prerelease";

/// The version to report, set by `main` from `get`.
pub var reported: []const u8 = @import("build_options").version;

/// `base` as this build of zfls reports it.
pub fn get(io: Io, comptime base: []const u8) []const u8 {
    if (builtin.mode == .debug) return base ++ "-dev";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &buf) catch return base;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ buf[0..n], std.fs.path.sep, sentinel_name }) catch return base;
    Io.Dir.accessAbsolute(io, path, .{}) catch return base;
    return base ++ "-rc";
}
