//! Data breakpoints with gdb (#746): gdb's hardware watchpoints on a
//! scalar, an array's element or a small component, at its address
//! (`watch -location`), so that they outlive the frame of the expression
//! that named them. A whole array, or more than the processor watches (8
//! bytes), has no `dataId`, and the description says why.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");
const vars = @import("gdb_variables.zig");
const data_ids = @import("data_ids.zig");

/// `dataBreakpointInfo`: of the child `name` of a variable reference, or
/// of the expression `name` of a frame
pub fn info(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const name = json.str(json.get(args, "name")) orelse "";
    var frame = json.int(json.get(args, "frameId"));
    var expr: []const u8 = name;
    if (json.int(json.get(args, "variablesReference"))) |ref| if (ref != 0) {
        const node = vars.get(s, ref) orelse return none(s, a, req, s.text.not_available);
        frame = node.frame orelse frame;
        expr = for (node.names) |n| {
            if (std.mem.eql(u8, n.shown, name)) break n.evaluate_name orelse return none(s, a, req, s.text.not_available);
        } else return none(s, a, req, s.text.not_available);
    };
    const what = try command(s, a, try a.print("whatis {s}", .{expr}), frame) orelse return none(s, a, req, try a.print("{s}: {s}", .{ expr, s.text.not_available }));
    const size = try number(s, a, try a.print("output sizeof({s})", .{expr}), frame);
    const at = try number(s, a, try a.print("output loc({s})", .{expr}), frame);
    const why = data_ids.refusal(a, expr, data_ids.isArrayType(what), size orelse 0) catch return error.OutOfMemory;
    if (why) |w| return none(s, a, req, w);
    const id = try data_ids.format(a, at orelse return none(s, a, req, try a.print("{s} has no address", .{expr})), size.?, expr);
    s.respond(a, req, .{ .dataId = id, .description = expr, .accessTypes = &[_][]const u8{ "write", "read", "readWrite" }, .canPersist = false });
}

fn none(s: *Session, a: Allocator, req: Value, why: []const u8) void {
    s.respond(a, req, .{ .dataId = @as(?[]const u8, null), .description = why });
}

/// `setDataBreakpoints`: gdb's watchpoints, in place of those before
pub fn set(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    for (s.g.data_breakpoints.items) |n| _ = try command(s, a, try a.print("delete {d}", .{n}), null);
    s.g.data_breakpoints.clearRetainingCapacity();
    var out: std.ArrayList(Value) = .empty;
    for (json.items(json.get(args, "breakpoints"))) |b| {
        const d = data_ids.parse(json.str(json.get(b, "dataId")) orelse "") orelse {
            try out.append(a, try json.from(a, .{ .verified = false, .message = "not a data breakpoint of zfls's" }));
            continue;
        };
        const access = json.str(json.get(b, "accessType")) orelse "write";
        const verb = if (std.mem.eql(u8, access, "read")) "rwatch" else if (std.mem.eql(u8, access, "readWrite")) "awatch" else "watch";
        // C's cast: gdb's Fortran has no pointer to bytes
        var cmd = try a.print("with language c -- {s} -location *(unsigned char (*)[{d}]) 0x{x}", .{ verb, d.size, d.address });
        if (json.str(json.get(b, "condition"))) |c| if (c.len > 0) {
            cmd = try a.print("{s} if {s}", .{ cmd, c });
        };
        const said = (try command(s, a, cmd, null)) orelse "";
        const number_ = watchpointNumber(said) orelse {
            try out.append(a, try json.from(a, .{ .verified = false, .message = std.mem.trim(u8, said, " \r\n") }));
            continue;
        };
        try s.g.data_breakpoints.append(s.gpa, number_);
        if (json.str(json.get(b, "hitCondition"))) |h| if (h.len > 0) {
            _ = try command(s, a, try a.print("ignore {d} {s}", .{ number_, h }), null);
        };
        try out.append(a, try json.from(a, .{ .id = number_, .verified = true, .message = d.expr }));
    }
    s.respond(a, req, .{ .breakpoints = out.items });
}

/// gdb's command's output; null when it failed
fn command(s: *Session, a: Allocator, text: []const u8, frame: ?i64) !?[]const u8 {
    const r = try gdb.request(s, a, "evaluate", try vars.evalArgs(a, text, frame, "repl"));
    if (!gdb.isSuccess(r)) return null;
    return json.str(json.path(r, &.{ "body", "result" })) orelse "";
}

/// A command's number (`4`, `140697695240628`)
fn number(s: *Session, a: Allocator, text: []const u8, frame: ?i64) !?u64 {
    const out = (try command(s, a, text, frame)) orelse return null;
    const t = std.mem.trim(u8, out, " \r\n");
    return std.fmt.parseInt(u64, t, 0) catch null;
}

/// The number of `Hardware watchpoint 7: ...` (`read watchpoint`,
/// `access (read/write) watchpoint`, `Watchpoint`)
pub fn watchpointNumber(said: []const u8) ?i64 {
    const at = std.mem.find(u8, said, "atchpoint ") orelse return null;
    var it = std.mem.tokenizeAny(u8, said[at + "atchpoint ".len ..], ": \r\n");
    return std.fmt.parseInt(i64, it.next() orelse return null, 10) catch null;
}

test watchpointNumber {
    try std.testing.expectEqual(@as(?i64, 2), watchpointNumber("Hardware watchpoint 2: -location *(unsigned char (*)[4]) 0x1400020b1\n"));
    try std.testing.expectEqual(@as(?i64, 5), watchpointNumber("Hardware access (read/write) watchpoint 5: -location x"));
    try std.testing.expectEqual(@as(?i64, null), watchpointNumber("No symbol \"x\" in current context."));
}
