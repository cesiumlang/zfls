//! gfortran's module files (#544): for a module that a USE names and that
//! nothing else defines, `<module>.mod` of the module file directories
//! (modfiles.zig) when it is gfortran's (gzip), whose interface zfls writes
//! as Fortran (compilers/gfortran_mod.zig) to its cache, `gfortran-mod/`,
//! and indexes from there as it does Flang's module files. Go to
//! definition then opens that interface.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const gfortran_mod = @import("../compilers/gfortran_mod.zig");

const Server = @import("../server.zig").Server;
const compile = @import("compile.zig");

/// The interface written of gfortran's module file of module `name`
/// (lowercase) in `dirs`, null when none is there
pub fn find(self: *Server, a: Allocator, dirs: []const []const u8, name: []const u8) !?[]const u8 {
    const base = try a.print("{s}.mod", .{name});
    for (dirs) |d| {
        const p = try std.Io.Dir.path.join(a, &.{ d, base });
        if (!isGzipPath(self.io, p)) continue;
        const data = Io.Dir.cwd().readFileAlloc(self.io, p, a, .limited(1 << 28)) catch continue;
        const text = (try gfortran_mod.gunzip(a, data)) orelse continue;
        const src = (try gfortran_mod.source(a, text, name)) orelse continue;
        const dir = try std.Io.Dir.path.join(a, &.{ try compile.cacheDir(self, a, "gfortran-mod"), try a.print("{x:0>16}", .{std.hash.Wyhash.hash(0, p)}) });
        // not before the workspace's root is known, without a cache
        // directory
        if (!std.Io.Dir.path.isAbsolute(dir)) return null;
        Io.Dir.cwd().createDirPath(self.io, dir) catch return null;
        const out = try std.Io.Dir.path.join(a, &.{ dir, try a.print("{s}.f90", .{name}) });
        const old = Io.Dir.cwd().readFileAlloc(self.io, out, a, .limited(1 << 28)) catch null;
        if (old == null or !std.mem.eql(u8, old.?, src)) Io.Dir.cwd().writeFile(self.io, .{ .sub_path = out, .data = src }) catch return null;
        self.log.info("{s}: the interface of gfortran's module file {s}", .{ out, p });
        return out;
    }
    return null;
}

fn isGzipPath(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buf: [2]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return false;
    return gfortran_mod.isGzip(buf[0..n]);
}
