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
    // ifx marks a Cray pointer PTR, as a POINTER; gfortran (CRAY-POINTER)
    // and Flang (CrayPointer) tell it apart, as zfls does (hover)
    .{ .file = "cray_pointers.f90", .diff = "differs: cray::ptr: POINTER false, ifx PTR", .why = cray_ptr },
    .{ .file = "cray_pointers.f90", .diff = "differs: cray::iptr: POINTER false, ifx PTR", .why = cray_ptr },
    .{ .file = "cray_pointers.f90", .diff = "differs: cray::p3: POINTER false, ifx PTR", .why = cray_ptr },
    .{ .file = "cray_pointers.f90", .diff = "differs: cray_implicit::q: POINTER false, ifx PTR", .why = cray_ptr },
    .{ .file = "cray_pointers.f90", .diff = "differs: cray_implicit::q2: POINTER false, ifx PTR", .why = cray_ptr },
};

const cray_ptr = "ifx lists a Cray pointer with the attribute PTR of a POINTER; it has no POINTER attribute";

pub fn isKnown(file: []const u8, diff: []const u8) bool {
    for (all) |k| if (std.mem.eql(u8, k.file, file) and std.mem.eql(u8, k.diff, diff)) return true;
    return false;
}
