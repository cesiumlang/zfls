//! Part of the argument checks (argcheck.zig): an ALLOCATABLE dummy argument
//! needs an ALLOCATABLE variable as its actual argument (gfortran, Flang
//! and ifx all say so), for a procedure with an explicit interface.

const std = @import("std");
const objects = @import("../objects.zig");
const typing = @import("typing.zig");
const dimensions = @import("../objects/dimensions.zig");
const KW = @import("../constants.zig").KW;

const Obj = objects.Obj;

/// Whether `actual` is no ALLOCATABLE variable though `dummy` is one: a
/// constant, an expression, or a variable without the attribute. A part of
/// an allocatable (`a(1:2)`, `a%b`) is not told.
pub fn mismatch(dummy: *const Obj, actual: typing.Typed) bool {
    if (!dummy.hasKeyword(KW.allocatable)) return false;
    if (!actual.designator) return actual.cat != .unknown;
    if (actual.subscripted) return false;
    const v = actual.obj orelse return false;
    if (v.kind != .variable or v.hasKeyword(KW.allocatable)) return false;
    // an associate name or a component of another kind: not told
    if (dimensions.isAssociateName(v)) return false;
    return true;
}
