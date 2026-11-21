//! The differences between zfls and ifx's listing that the ifx oracle
//! (ifx_oracle.zig) expects, each with its reason; any other fails it.

const std = @import("std");

const Known = struct {
    /// the file's name
    file: []const u8,
    /// the difference as the oracle prints it
    diff: []const u8,
    why: []const u8,
};

const all = [_]Known{
    .{ .file = "modules_types.f90", .diff = "missing in zfls: variable my_pi (Param)", .why = "the local name of a USE (`my_pi => pi`), which ifx lists as an entity of the unit that uses it" },
};

pub fn isKnown(file: []const u8, diff: []const u8) bool {
    for (all) |k| if (std.mem.eql(u8, k.file, file) and std.mem.eql(u8, k.diff, diff)) return true;
    return false;
}
