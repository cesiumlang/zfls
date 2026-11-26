//! Part of the argument checks (argcheck.zig): the specific procedure of a
//! generic interface that a call references, told by the type, kind and
//! rank of its arguments (fortls #6, hansec #135). A call is consistent
//! with a specific when each of its arguments fits the dummy argument it is
//! passed to; an argument whose type cannot be told fits every dummy.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const KW = @import("../constants.zig").KW;
const argcheck = @import("../argcheck.zig");
const typing = @import("typing.zig");

const Fit = enum { no, unknown, yes };

/// The procedure of a specific (of a type-bound procedure, the procedure it
/// binds) and the dummy arguments a call gives it, the passed object left out
const Dummies = struct { proc: *Obj, names: []const []const u8, objs: []const ?*Obj };

fn dummiesOf(a: Allocator, member: *Obj) !?Dummies {
    const proc, const drop = switch (member.kind) {
        .subroutine, .function => .{ member, null },
        .method => .{ member.linkObj() orelse return null, member.varDataConst().drop_arg },
        else => return null,
    };
    if (!proc.kind.isSubroutine()) return null;
    const pd = proc.procDataConst();
    var names: std.ArrayList([]const u8) = .empty;
    var objs: std.ArrayList(?*Obj) = .empty;
    for (try typing.splitArgs(a, proc.argList()), 0..) |n, i| {
        if (i == drop) continue;
        const name = std.mem.trim(u8, n, " ");
        // alternate returns
        if (name.len == 0 or name[0] == '*') return null;
        try names.append(a, name);
        try objs.append(a, if (i < pd.arg_objs.items.len) pd.arg_objs.items[i] else null);
    }
    return .{ .proc = proc, .names = names.items, .objs = objs.items };
}

/// How a call with arguments `args` fits specific `member`: `no` when an
/// argument is known not to fit its dummy argument (or has no dummy), `yes`
/// when each is known to fit
fn callFit(c: *argcheck.Checker, d: Dummies, args: []const []const u8, scope: ?*Obj, line_no: usize) !Fit {
    const elemental = d.proc.hasKeyword(KW.elemental);
    var fit: Fit = .yes;
    var positional: usize = 0;
    for (args) |raw| {
        const arg = std.mem.trim(u8, raw, " \t");
        var actual = arg;
        const idx = if (typing.keywordOf(arg)) |kw| blk: {
            actual = std.mem.trim(u8, arg[std.mem.findScalar(u8, arg, '=').? + 1 ..], " \t");
            break :blk for (d.names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(n, kw)) break i;
            } else return .no;
        } else blk: {
            positional += 1;
            break :blk positional - 1;
        };
        if (idx >= d.names.len) return .no;
        const dummy = d.objs[idx] orelse {
            fit = .unknown;
            continue;
        };
        // an argument being written fits
        if (actual.len == 0) {
            fit = .unknown;
            continue;
        }
        switch (try c.compare(dummy, actual, elemental, .generic, scope, line_no)) {
            .fits => {},
            .unknown => fit = .unknown,
            else => return .no,
        }
    }
    return fit;
}

/// Of `candidates`, the specifics of a generic interface that take a call
/// with arguments `args` by their number and keywords, the one the call
/// references by the type, kind and rank of its arguments, in `scope`
/// (1-based `line_no`): the only one that fits; else the only nonelemental
/// one each argument is known to fit; else the only elemental one so; null
/// when that cannot be told
pub fn resolve(a: Allocator, env: objects.Env, ast: *Ast, scope: ?*Obj, line_no: usize, candidates: []const *Obj, args: []const []const u8) !?*Obj {
    var c = argcheck.checker(a, env, ast);
    var fitting: ?*Obj = null;
    var n_fitting: usize = 0;
    var n_nonelemental: usize = 0;
    var sure: [2]?*Obj = .{ null, null };
    var n_sure: [2]usize = .{ 0, 0 };
    for (candidates) |member| {
        const d = (try dummiesOf(a, member)) orelse {
            n_fitting += 1;
            n_nonelemental += 1;
            continue;
        };
        const fit = try callFit(&c, d, args, scope, line_no);
        if (fit == .no) continue;
        n_fitting += 1;
        fitting = member;
        const elemental: usize = @intFromBool(d.proc.hasKeyword(KW.elemental));
        if (elemental == 0) n_nonelemental += 1;
        if (fit == .yes) {
            sure[elemental] = member;
            n_sure[elemental] += 1;
        }
    }
    // a reference consistent with a nonelemental specific is to that one
    if (n_sure[0] == 1) return sure[0];
    if (n_nonelemental == 0 and n_sure[1] == 1) return sure[1];
    if (n_fitting == 1) return fitting;
    return null;
}
