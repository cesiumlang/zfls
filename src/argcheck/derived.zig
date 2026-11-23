//! Part of the argument checks (argcheck.zig): the derived type of an
//! actual argument against that of its dummy argument.

const std = @import("std");
const objects = @import("../objects.zig");
const typing = @import("typing.zig");

const Obj = objects.Obj;

/// Whether variable `v` has the derived type of dummy argument `dummy`
/// (or, for a CLASS dummy argument, a type that extends it)
pub fn sameType(env: objects.Env, dummy: *Obj, v_opt: ?*Obj) !enum { yes, no, unknown } {
    const v = v_opt orelse return .unknown;
    const want = (try dummy.getTypeObj(env)) orelse return .unknown;
    var t = (try v.getTypeObj(env)) orelse return .unknown;
    if (want.kind != .type or t.kind != .type) return .unknown;
    if (t == want) return .yes;
    if (!std.ascii.startsWithIgnoreCase(std.mem.trim(u8, dummy.descOf(), " "), "class")) return .no;
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        // a type that extends one not found
        if (t.data == .scope and t.data.scope.inherit != null and t.typeDataConst().inherit_var == null) return .unknown;
        t = t.typeDataConst().inherit_var orelse return .no;
        if (t == want) return .yes;
    }
    return .unknown;
}

pub const Names = struct { class: bool, want: []const u8, have: []const u8 };

/// The names of the derived types of `actual` when it is another than dummy
/// argument `dummy`'s (a CLASS dummy argument takes the types that extend
/// its own), for a procedure with an explicit interface; null when it is
/// the same or cannot be told. Types of one name (two definitions) count
/// as the same.
pub fn mismatch(env: objects.Env, dummy: *Obj, actual: typing.Typed) !?Names {
    if (actual.cat != .derived or typing.varCategory(dummy) != .derived) return null;
    const v = actual.obj orelse return null;
    if (try sameType(env, dummy, v) != .no) return null;
    const have = (try v.getTypeObj(env)) orelse return null;
    const want = (try dummy.getTypeObj(env)) orelse return null;
    if (std.ascii.eqlIgnoreCase(have.name, want.name)) return null;
    return .{ .class = std.ascii.startsWithIgnoreCase(std.mem.trim(u8, dummy.descOf(), " "), "class"), .want = want.name, .have = have.name };
}
