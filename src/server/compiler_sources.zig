//! The module sources that the compiler check's compiler ships
//! (compilers/shipped.zig): ifx's and ifort's `ifport`, `ifcore`,
//! `kernel32`, ... (#513), whose `.mod` files are binary, and gfortran's
//! `omp_lib` and `openacc` (#544). A module that a
//! USE names and that nothing else defines is read from them as Flang's
//! module files are (modfiles.zig). Each compiler's directory is read once.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const shipped = @import("../compilers/shipped.zig");

const Server = @import("../server.zig").Server;
const compile_args = @import("compile_args.zig");
const compiler_version = @import("compiler_version.zig");

/// The modules of an executable's sources (in the server's arena)
pub const Known = shipped.Modules;

/// The source file of module `name` (lowercase) that the compiler check's
/// compiler of either form ships, if one does
pub fn find(self: *Server, a: Allocator, name: []const u8) !?[]const u8 {
    for ([_]bool{ false, true }) |fixed| {
        const id = compile_args.compilerOf(self, fixed) orelse continue;
        if (id != .ifx and id != .ifort and id != .gfortran) continue;
        const exes = try compile_args.executables(self, a, id, compile_args.compilerPath(self, fixed), null);
        for (exes) |exe| {
            const path = compiler_version.pathOf(self.io, a, exe, self.toolEnv()) orelse continue;
            if ((try modulesOf(self, a, id, path)).get(name)) |f| return f;
            break;
        }
    }
    return null;
}

/// The modules of the sources of the compiler at `exe` (a path)
fn modulesOf(self: *Server, a: Allocator, id: compilers.Id, exe: []const u8) !*const Known {
    if (self.compiler_sources.getPtr(exe)) |k| return k;
    const sa = self.arena.allocator();
    var k: Known = .empty;
    const found = if (id == .gfortran) shipped.gfortranDir(self.io, a, exe, self.toolEnv()) else try shipped.intelDir(self.io, a, exe);
    if (found) |dir| {
        try shipped.scan(self.io, a, sa, dir, &k);
        self.log.info("{s}: {d} modules in the sources of {s}", .{ dir, k.count(), exe });
    }
    try self.compiler_sources.put(sa, try sa.dupe(u8, exe), k);
    return self.compiler_sources.getPtr(exe).?;
}
