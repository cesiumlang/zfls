//! The conditions of the engine's breakpoints (#734), as gdb has them: a
//! hit condition is the number of hits ignored (evaluated when set), a
//! condition a Fortran expression (conditions.zig) of the stopped frame,
//! false to go on, and a log message (`k is {k}`) written at the hit,
//! without a stop. A condition that cannot be evaluated stops, and says why.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;
const Val = session.Val;
const memory = @import("memory.zig");
const variables = @import("variables.zig");
const conditions = @import("conditions.zig");

/// A breakpoint's condition, hits ignored and log message (`gpa`'s)
pub const Condition = struct {
    condition: ?[]u8 = null,
    log_message: ?[]u8 = null,
    /// Hits still ignored
    ignore: u64 = 0,

    pub fn deinit(c: *Condition, gpa: Allocator) void {
        if (c.condition) |x| gpa.free(x);
        if (c.log_message) |x| gpa.free(x);
    }
};

/// Keeps the condition, hit condition and log message of a source
/// breakpoint `b` of id `id`: why its hit condition is not a number, or
/// null
pub fn keep(s: *Session, a: Allocator, id: u32, b: Value) !?[]const u8 {
    forget(s, id);
    const cond = nonEmpty(json.str(json.get(b, "condition")));
    const log = nonEmpty(json.str(json.get(b, "logMessage")));
    const hit = nonEmpty(json.str(json.get(b, "hitCondition")));
    if (cond == null and log == null and hit == null) return null;
    var c: Condition = .{};
    if (hit) |h| {
        // as gdb's: evaluated once, out of any frame
        const n = conditions.integer(a, h, .{ .ctx = s, .read = noNames }) catch |e|
            return try a.print("hit condition {s}: {s}", .{ h, whyNot(e) });
        c.ignore = @intCast(@max(n, 0));
    }
    if (cond) |x| c.condition = try s.gpa.dupe(u8, x);
    errdefer c.deinit(s.gpa);
    if (log) |x| c.log_message = try s.gpa.dupe(u8, x);
    try s.conditions.put(s.gpa, id, c);
    return null;
}

pub fn forget(s: *Session, id: u32) void {
    var kv = s.conditions.fetchRemove(id) orelse return;
    kv.value.deinit(s.gpa);
}

/// Whether the hit of breakpoint `id` by `thread` is a stop: not while its
/// hits are ignored, nor when its condition is false, nor at a log
/// message's, which is written
pub fn stops(s: *Session, a: Allocator, id: u32, thread: u32) bool {
    const c = s.conditions.getPtr(id) orelse return true;
    if (c.ignore > 0) {
        c.ignore -= 1;
        return false;
    }
    var at: Reader = .{ .s = s, .frame = .{ .thread = thread, .index = 0 } };
    if (c.condition) |text| {
        const yes = conditions.isTrue(a, text, .{ .ctx = &at, .read = Reader.read }) catch |e| {
            s.output(a, a.print("Error in testing the condition of breakpoint {d} ({s}): {s}\n", .{ id, text, whyNot(e) }) catch return true);
            return true;
        };
        if (!yes) return false;
    }
    const message = c.log_message orelse return true;
    s.output(a, logged(s, a, message, at.frame) catch return false);
    return false;
}

/// A log message with each `{expression}` its value
fn logged(s: *Session, a: Allocator, message: []const u8, frame: Frame) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = message;
    while (std.mem.findScalar(u8, rest, '{')) |open| {
        const close = std.mem.findScalarPos(u8, rest, open, '}') orelse break;
        try out.appendSlice(a, rest[0..open]);
        const expr = rest[open + 1 .. close];
        const shown: []const u8 = if (try memory.evaluate(s, a, frame, expr)) |v|
            json.str(json.get(try variables.show(s, a, expr, v), "value")) orelse "?"
        else
            try a.print("<{s}: {s}>", .{ expr, s.text.not_available });
        try out.appendSlice(a, shown);
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(a, rest);
    try out.append(a, '\n');
    return out.items;
}

fn nonEmpty(x: ?[]const u8) ?[]const u8 {
    const t = std.mem.trim(u8, x orelse return null, " \t");
    return if (t.len > 0) t else null;
}

pub fn whyNot(e: conditions.Error) []const u8 {
    return switch (e) {
        error.Syntax => "not an expression",
        error.UnknownName => "a name not known here",
        error.TypeMismatch => "of the wrong type",
        error.DivisionByZero => "a division by zero",
        error.OutOfMemory => "out of memory",
    };
}

fn noNames(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?conditions.Scalar {
    return null;
}

/// The program's designators of a frame, as scalars
pub const Reader = struct {
    s: *Session,
    frame: Frame,

    pub fn read(ctx: *anyopaque, a: Allocator, designator: []const u8) anyerror!?conditions.Scalar {
        const r: *Reader = @ptrCast(@alignCast(ctx));
        const v = (try memory.evaluate(r.s, a, r.frame, designator)) orelse return null;
        return scalarOf(r.s, a, v);
    }
};

/// A scalar's value of the program; null for an array, a derived type, or
/// unreadable memory
pub fn scalarOf(s: *Session, a: Allocator, v: Val) !?conditions.Scalar {
    if (v.empty or v.rank > v.chosen.len) return null;
    const size: usize = switch (v.t.kind) {
        .integer, .real, .logical => v.t.size,
        .character => @min(v.t.size, 4096),
        else => return null,
    };
    const b = try a.alloc(u8, size);
    if (s.engine.read(v.address, b) != size) return null;
    return switch (v.t.kind) {
        .integer => .{ .integer = switch (size) {
            1 => @as(i8, @bitCast(b[0])),
            2 => std.mem.readInt(i16, b[0..2], .little),
            4 => std.mem.readInt(i32, b[0..4], .little),
            8 => std.mem.readInt(i64, b[0..8], .little),
            else => return null,
        } },
        .real => .{ .real = switch (size) {
            4 => @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little))),
            8 => @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little))),
            else => return null,
        } },
        // Intel's: true when the lowest bit is set
        .logical => .{ .logical = size > 0 and b[0] & 1 == 1 },
        .character => .{ .character = b },
        else => null,
    };
}
