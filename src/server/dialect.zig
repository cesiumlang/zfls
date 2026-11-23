//! The dialect a file is linted against (dialect.zig).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dialect = @import("../dialect.zig");
const compilers = @import("../compilers.zig");
const compiler_names = @import("../compiler_names.zig");
const compile_args = @import("compile_args.zig");

const Dialect = dialect.Dialect;
const Server = @import("../server.zig").Server;

/// The dialect of a form's files: `lint_dialect` when it names one, else
/// that of the form's compiler (`compiler_diagnostics`, or its executable
/// when only `compiler_path` is set), else neutral
pub fn of(self: *const Server, fixed: bool) Dialect {
    return resolve(self.s.lint_dialect, compile_args.compilerName(self, fixed), compile_args.compilerPath(self, fixed));
}

/// `of` from the settings' values
pub fn resolve(lint: ?[]const u8, compiler: ?[]const u8, path: ?[]const u8) Dialect {
    if (lint) |n| if (Dialect.fromName(n)) |d| return d;
    if (compiler) |n| {
        const id = compilers.Id.fromName(std.mem.trim(u8, n, " ")) orelse return .neutral;
        return fromCompiler(id);
    }
    if (path) |p| if (compiler_names.idOf(p)) |id| return fromCompiler(id);
    return .neutral;
}

/// The dialect of a compiler; those zfls has no rules for are neutral
pub fn fromCompiler(id: compilers.Id) Dialect {
    return switch (id) {
        .gfortran => .gfortran,
        .ifx, .ifort => .ifx,
        .flang => .flang,
        .nagfor, .lfortran, .nvfortran => .neutral,
    };
}

/// Warns about a `lint_dialect` that names no dialect
pub fn checkSetting(self: *Server, a: Allocator) !void {
    const name = self.s.lint_dialect orelse return;
    if (std.mem.trim(u8, name, " ").len == 0 or Dialect.fromName(name) != null) return;
    self.postMessage(a, try a.print("lint_dialect: unknown dialect \"{s}\"; it is one of neutral, gfortran, ifx or flang", .{name}), 2);
}

test "the dialect: lint_dialect, else the compiler, else neutral" {
    const t = std.testing;
    try t.expectEqual(Dialect.neutral, resolve(null, null, null));
    try t.expectEqual(Dialect.gfortran, resolve(null, "gfortran", null));
    try t.expectEqual(Dialect.ifx, resolve(null, "ifort", null));
    try t.expectEqual(Dialect.flang, resolve("flang", "gfortran", null));
    try t.expectEqual(Dialect.neutral, resolve("neutral", "ifx", null));
    // an unknown dialect is no override
    try t.expectEqual(Dialect.ifx, resolve("nosuch", "ifx", null));
    try t.expectEqual(Dialect.neutral, resolve(null, "lfortran", null));
    try t.expectEqual(Dialect.flang, resolve(null, null, "C:\\x\\flang-new-23.exe"));
    try t.expectEqual(Dialect.gfortran, resolve(null, null, "/usr/bin/gfortran-14"));
    try t.expectEqual(Dialect.neutral, resolve(null, null, "/usr/bin/cc"));
}
