//! Keyword arguments (`call move(dx=1.0)`): the names a call of a procedure
//! can give its arguments, for completion inside the call (hansec #133).

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("objects.zig");
const Obj = objects.Obj;
const str = @import("str.zig");

/// A name a call can give an argument
pub const Keyword = struct {
    name: []const u8,
    /// the declaration of the dummy argument or component, when known
    detail: ?[]const u8 = null,
    optional: bool = false,
    /// an argument of an intrinsic procedure (its name is upper case)
    intrinsic: bool = false,
};

/// The keywords of a call of `obj`: the dummy arguments of a procedure
/// (without the passed object of a type-bound procedure), of every
/// procedure of a generic interface, the arguments of an intrinsic
/// procedure, or the components of a type (its structure constructor)
pub fn keywordsOf(a: Allocator, obj: *const Obj) ![]const Keyword {
    var out: std.ArrayList(Keyword) = .empty;
    try collect(a, obj, null, &out, 0);
    return out.items;
}

fn collect(a: Allocator, obj: *const Obj, drop_arg: ?usize, out: *std.ArrayList(Keyword), depth: usize) !void {
    // links that loop while code is being edited
    if (depth > 8) return;
    switch (obj.kind) {
        .subroutine, .function => {
            const names = try str.split(a, obj.argList(), ",");
            for (obj.procDataConst().arg_objs.items, 0..) |arg_opt, i| {
                if (i == drop_arg) continue;
                if (arg_opt) |arg| {
                    const h = try arg.getHover(a, false, null);
                    try add(a, out, .{ .name = arg.name, .detail = h.msg, .optional = arg.isOptional() });
                } else if (i < names.len) {
                    try add(a, out, .{ .name = str.strip(names[i]) });
                }
            }
        },
        .method => if (obj.linkObj()) |l| try collect(a, l, obj.varDataConst().drop_arg, out, depth + 1),
        .interface => for (obj.memList()) |m| try collect(a, m, null, out, depth + 1),
        .intrinsic => for (try str.split(a, obj.argList(), ",")) |arg| {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            try add(a, out, .{
                .name = str.strip(if (eq) |e| arg[0..e] else arg),
                .optional = eq != null,
                .intrinsic = true,
            });
        },
        .type => for (try obj.getChildren(a, false)) |child| {
            if (child.kind != .variable) continue;
            const h = try child.getHover(a, false, null);
            try add(a, out, .{ .name = child.name, .detail = h.msg });
        },
        else => {},
    }
}

fn add(a: Allocator, out: *std.ArrayList(Keyword), k: Keyword) !void {
    if (!isName(k.name)) return;
    for (out.items) |o| if (std.ascii.eqlIgnoreCase(o.name, k.name)) return;
    try out.append(a, k);
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// The keyword an argument of a call gives (`dx` of `dx = 1.0`), or null
pub fn keywordOfArg(arg: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    // `a == b` and `a => b` are values, not keywords
    if (eq + 1 < arg.len and (arg[eq + 1] == '=' or arg[eq + 1] == '>')) return null;
    if (eq > 0 and (arg[eq - 1] == '/' or arg[eq - 1] == '<' or arg[eq - 1] == '>')) return null;
    const name = str.strip(arg[0..eq]);
    return if (isName(name)) name else null;
}

test "keywordOfArg" {
    try std.testing.expectEqualStrings("dx", keywordOfArg(" dx = 1.0").?);
    try std.testing.expect(keywordOfArg("a == b") == null);
    try std.testing.expect(keywordOfArg("a /= b") == null);
    try std.testing.expect(keywordOfArg("a <= b") == null);
    try std.testing.expect(keywordOfArg("x(1) = 2") == null);
    try std.testing.expect(keywordOfArg("x") == null);
}
