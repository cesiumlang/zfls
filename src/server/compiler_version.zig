//! The version of the compiler of the compiler check (compile.zig), for
//! the options that differ between its releases: LLVM Flang's, from
//! `flang --version`, asked once for each executable.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const flang = @import("../compilers/flang.zig");
const tools = @import("tools.zig");

const Server = @import("../server.zig").Server;

/// The major version of the compiler that the check runs, the first of
/// `exes` that runs: for LLVM Flang only, else null. Null too when none
/// runs or it does not say (no version-dependent options then).
pub fn of(self: *Server, a: Allocator, id: compilers.Id, exes: []const []const u8) ?u32 {
    if (id != .flang) return null;
    for (exes) |exe| {
        if (self.compiler_versions.get(exe)) |known| {
            if (known.found) return known.version;
            continue;
        }
        const found = ask(self, a, exe);
        const key = self.arena.allocator().dupe(u8, exe) catch return found.version;
        self.compiler_versions.put(self.arena.allocator(), key, found) catch {};
        if (found.found) return found.version;
    }
    return null;
}

/// What `exe --version` said, and whether `exe` was there
pub const Known = struct { found: bool, version: ?u32 };

fn ask(self: *Server, a: Allocator, exe: []const u8) Known {
    // in the workspace, not zfls's own directory: a compiler (or a script
    // standing for one) may write files where it runs
    const r = tools.run(a, self.io, .{
        .argv = &.{ exe, "--version" },
        .cwd = if (self.root_path.len > 0) self.root_path else null,
        .environ_map = self.toolEnv(),
        .timeout = tools.seconds(10),
    }) catch |e| return .{ .found = e != error.FileNotFound, .version = null };
    const version = flang.parseVersion(r.stdout) orelse flang.parseVersion(r.stderr);
    self.log.info("compiler_diagnostics: {s} is LLVM Flang {?d}", .{ exe, version });
    return .{ .found = true, .version = version };
}
