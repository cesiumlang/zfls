//! What the compiler oracles share for zfls's own diagnostics (#735): a
//! fixture its compiler accepts must get no error or warning from zfls
//! (`--debug_diagnostics`); each oracle's known differences, each with its
//! reason, list the ones that stay.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util = @import("oracle_util.zig");

/// A diagnostic zfls gives on code a compiler accepts, and why the compiler
/// is not the reference there: the fixture's file name and a part of the
/// message
pub const Known = struct { file: []const u8, text: []const u8, why: []const u8 };

pub const known = [_]Known{
    .{ .file = "test_variable.f90", .text = "masks variable in parent scope", .why = "zfls's lint of a name that hides one of the scope around it; compilers accept it" },
};

/// The errors and warnings (`ERROR  "text"`, without their line) zfls
/// reports on `abs` that are not in `known`, found by running `zfls` with
/// `args` (a fixture's own `oracle-zfls-args:` among them)
pub fn report(io: Io, a: Allocator, zfls: []const u8, abs: []const u8, args: []const []const u8) ![]const []const u8 {
    var cmd: std.ArrayList([]const u8) = .empty;
    try cmd.appendSlice(a, &.{ zfls, "--debug_diagnostics", "--debug_filepath", abs });
    try cmd.appendSlice(a, args);
    const r = try util.run(io, a, cmd.items, null, null);
    const base = std.Io.Dir.path.basename(abs);
    var out: std.ArrayList([]const u8) = .empty;
    for (try parse(a, r.stdout)) |d| {
        for (known) |k| {
            if (std.mem.eql(u8, k.file, base) and std.mem.find(u8, d, k.text) != null) break;
        } else try out.append(a, d);
    }
    return out.items;
}

/// The errors and warnings of `--debug_diagnostics` output `out`
pub fn parse(a: Allocator, out: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const rest = line[colon + 1 ..];
        if (!std.mem.startsWith(u8, rest, "ERROR ") and !std.mem.startsWith(u8, rest, "WARNING ")) continue;
        try list.append(a, try a.dupe(u8, rest));
    }
    return list.items;
}

test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out =
        \\Reported Diagnostics:
        \\     +2:WARNING  "Name "x" is not declared (IMPLICIT NONE)"
        \\     +7:INFO  "Module "m" not found in project"
        \\    +10:ERROR  "bad"
        \\
    ;
    const got = try parse(arena.allocator(), out);
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqualStrings("ERROR  \"bad\"", got[1]);
}
