//! The engine's `setVariable` and `setExpression` (#745): the value, a
//! Fortran expression of the frame (conditions.zig: `42`, `k + 1`,
//! `.true.`, `'abc'`), written in the variable's type over its bytes:
//! INTEGER and REAL of their kinds, LOGICAL, CHARACTER blank-padded.
//! Arrays, derived types and COMPLEX are not set.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;
const Node = session.Node;
const Val = session.Val;
const memory = @import("memory.zig");
const variables = @import("variables.zig");
const conditions = @import("conditions.zig");
const engine_conditions = @import("engine_conditions.zig");

/// `setVariable`: the child `name` of a variable reference
pub fn setVariable(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const ref = json.int(json.get(args, "variablesReference")) orelse 0;
    const name = json.str(json.get(args, "name")) orelse "";
    if (ref <= 0 or ref > s.nodes.items.len) return s.fail(a, req, s.text.not_available);
    const node = s.nodes.items[@intCast(ref - 1)];
    const frame: Frame = switch (node) {
        .locals, .modules => |f| f,
        .module => |m| m.frame,
        .value => |v| v.frame,
    };
    const expr = for (try variables.children(s, a, node)) |k| {
        if (std.mem.eql(u8, json.str(json.get(k, "name")) orelse "", name)) break json.str(json.get(k, "evaluateName"));
    } else null;
    try set(s, a, req, frame, expr orelse return s.fail(a, req, s.text.not_available), json.str(json.get(args, "value")) orelse "");
}

/// `setExpression`: a designator of the frame
pub fn setExpression(s: *Session, a: Allocator, req: Value, args: ?Value, frame: Frame) !void {
    const expr = json.str(json.get(args, "expression")) orelse return s.fail(a, req, "no expression");
    try set(s, a, req, frame, expr, json.str(json.get(args, "value")) orelse "");
}

fn set(s: *Session, a: Allocator, req: Value, frame: Frame, expr: []const u8, text: []const u8) !void {
    const v = (try memory.evaluate(s, a, frame, expr)) orelse return s.fail(a, req, s.text.not_available);
    var reader: engine_conditions.Reader = .{ .s = s, .frame = frame };
    const value = conditions.evaluate(a, text, .{ .ctx = &reader, .read = engine_conditions.Reader.read }) catch |e|
        return s.fail(a, req, try a.print("{s}: {s}", .{ text, engine_conditions.whyNot(e) }));
    const bytes = encode(a, v, value) catch |e| return s.fail(a, req, switch (e) {
        error.NotSet => try a.print("{s} is not set by a value (an array, a derived type, COMPLEX)", .{expr}),
        error.OutOfRange => try a.print("{s} does not fit {s}", .{ text, expr }),
        error.WrongType => try a.print("{s} is not of {s}'s type", .{ text, expr }),
        error.OutOfMemory => return error.OutOfMemory,
    });
    if (!s.engine.write(v.address, bytes)) return s.fail(a, req, try a.print("{s}: the program's memory was not written", .{expr}));
    const shown = try variables.show(s, a, expr, v);
    s.respond(a, req, .{
        .value = json.str(json.get(shown, "value")) orelse "",
        .type = json.str(json.get(shown, "type")),
        .variablesReference = json.int(json.get(shown, "variablesReference")) orelse 0,
    });
}

pub const EncodeError = error{ OutOfMemory, NotSet, OutOfRange, WrongType };

/// `value` as the bytes of `v`'s type (little-endian)
pub fn encode(a: Allocator, v: Val, value: conditions.Scalar) EncodeError![]const u8 {
    if (v.empty or v.rank > v.chosen.len) return error.NotSet;
    const size = v.t.size;
    const out = try a.alloc(u8, switch (v.t.kind) {
        .integer, .real, .logical => size,
        .character => size,
        else => return error.NotSet,
    });
    switch (v.t.kind) {
        .integer => {
            const n: i64 = switch (value) {
                .integer => |n| n,
                .real => |x| if (std.math.isFinite(x) and @trunc(x) == x and @abs(x) < 9.2e18) @intFromFloat(x) else return error.OutOfRange,
                else => return error.WrongType,
            };
            switch (size) {
                1 => out[0] = @bitCast(std.math.cast(i8, n) orelse return error.OutOfRange),
                2 => std.mem.writeInt(i16, out[0..2], std.math.cast(i16, n) orelse return error.OutOfRange, .little),
                4 => std.mem.writeInt(i32, out[0..4], std.math.cast(i32, n) orelse return error.OutOfRange, .little),
                8 => std.mem.writeInt(i64, out[0..8], n, .little),
                else => return error.NotSet,
            }
        },
        .real => {
            const x: f64 = switch (value) {
                .integer => |n| @floatFromInt(n),
                .real => |x| x,
                else => return error.WrongType,
            };
            switch (size) {
                4 => std.mem.writeInt(u32, out[0..4], @bitCast(@as(f32, @floatCast(x))), .little),
                8 => std.mem.writeInt(u64, out[0..8], @bitCast(x), .little),
                else => return error.NotSet,
            }
        },
        // 1 for .TRUE.: Intel's (the lowest bit) and LLVM Flang's
        .logical => {
            if (value != .logical) return error.WrongType;
            @memset(out, 0);
            if (value.logical) out[0] = 1;
        },
        .character => {
            if (value != .character) return error.WrongType;
            @memset(out, ' ');
            const n = @min(out.len, value.character.len);
            @memcpy(out[0..n], value.character[0..n]);
        },
        else => return error.NotSet,
    }
    return out;
}

test encode {
    const a = std.testing.allocator;
    const int4: Val = .{ .address = 0, .t = .{ .kind = .integer, .size = 4 } };
    const b = try encode(a, int4, .{ .integer = -2 });
    defer a.free(b);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xff, 0xff, 0xff }, b);
    try std.testing.expectError(error.OutOfRange, encode(a, .{ .address = 0, .t = .{ .kind = .integer, .size = 1 } }, .{ .integer = 300 }));
    const r = try encode(a, .{ .address = 0, .t = .{ .kind = .real, .size = 8 } }, .{ .integer = 3 });
    defer a.free(r);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(std.mem.readInt(u64, r[0..8], .little))));
    const c = try encode(a, .{ .address = 0, .t = .{ .kind = .character, .size = 5 } }, .{ .character = "ab" });
    defer a.free(c);
    try std.testing.expectEqualStrings("ab   ", c);
    try std.testing.expectError(error.WrongType, encode(a, .{ .address = 0, .t = .{ .kind = .logical, .size = 4 } }, .{ .integer = 1 }));
    try std.testing.expectError(error.NotSet, encode(a, .{ .address = 0, .t = .{ .kind = .derived } }, .{ .integer = 1 }));
}
