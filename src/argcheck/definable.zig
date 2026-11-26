//! Part of the argument checks (argcheck.zig): an actual argument for a
//! dummy argument with INTENT(OUT) or INTENT(INOUT) must be a variable that
//! can be defined, not a constant, an expression, a named constant or an
//! INTENT(IN) dummy argument of the caller (#848). gfortran, Flang and ifx
//! all report these, for a procedure with an explicit interface.

const std = @import("std");
const objects = @import("../objects.zig");
const typing = @import("typing.zig");
const KW = @import("../constants.zig").KW;

const Obj = objects.Obj;

/// What an actual argument is that cannot be defined
pub const Reason = enum { constant, named_constant, expression, intent_in };

/// `OUT` or `INOUT` when `dummy` has that intent, else null
pub fn definedIntent(dummy: *const Obj) ?[]const u8 {
    const intent = dummy.keyword_info.intent orelse return null;
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    for (intent) |ch| {
        if (ch == ' ') continue;
        if (n == buf.len) return null;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    if (std.mem.eql(u8, buf[0..n], "out")) return "OUT";
    return if (std.mem.eql(u8, buf[0..n], "inout")) "INOUT" else null;
}

/// Why `actual`, of known type, cannot be defined; null when it can, or
/// when that cannot be told
pub fn reason(actual: typing.Typed) ?Reason {
    if (actual.literal) return .constant;
    if (!actual.designator) return .expression;
    const v = actual.obj orelse return null;
    if (v.kind != .variable) return null;
    if (v.hasKeyword(KW.parameter)) return .named_constant;
    // a pointer's INTENT(IN) fixes its association, not its target
    if (v.hasKeyword(KW.pointer) or v.hasKeyword(KW.target)) return null;
    const intent = v.keyword_info.intent orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, intent, " "), "in")) return null;
    // a dummy argument of the procedure around
    const p = v.parent orelse return null;
    const pd = p.procDataOptConst() orelse return null;
    for (pd.arg_objs.items) |arg| if (arg == v) return .intent_in;
    return null;
}

/// What the message says the actual argument is
pub fn describe(r: Reason) []const u8 {
    return switch (r) {
        .constant => "a constant",
        .named_constant => "a named constant",
        .expression => "an expression",
        .intent_in => "an INTENT(IN) argument",
    };
}
