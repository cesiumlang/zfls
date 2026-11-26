//! Data breakpoints on Windows's Debugger Engine (#746): processor
//! breakpoints (the engine's `ba`) on a scalar, an array's element or a
//! small component, of 1, 2, 4 or 8 bytes at an address of their size's
//! alignment. A whole array, a derived type, or a size the processor does
//! not watch has no `dataId`, and the description says why.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;
const memory = @import("memory.zig");
const variables = @import("variables.zig");
const data_ids = @import("data_ids.zig");
const engine_conditions = @import("engine_conditions.zig");

/// `dataBreakpointInfo`: of the child `name` of a variable reference, or
/// of the expression `name` of a frame
pub fn info(s: *Session, a: Allocator, req: Value, args: ?Value, frame_of: Frame) !void {
    const name = json.str(json.get(args, "name")) orelse "";
    var frame = frame_of;
    var expr: []const u8 = name;
    if (json.int(json.get(args, "variablesReference"))) |ref| if (ref > 0) {
        if (ref > s.nodes.items.len) return none(s, a, req, s.text.not_available);
        const node = s.nodes.items[@intCast(ref - 1)];
        frame = switch (node) {
            .locals, .modules => |f| f,
            .module => |m| m.frame,
            .value => |v| v.frame,
        };
        expr = for (try variables.children(s, a, node)) |k| {
            if (std.mem.eql(u8, json.str(json.get(k, "name")) orelse "", name)) break json.str(json.get(k, "evaluateName")) orelse return none(s, a, req, s.text.not_available);
        } else return none(s, a, req, s.text.not_available);
    };
    const v = (try memory.evaluate(s, a, frame, expr)) orelse return none(s, a, req, try a.print("{s}: {s}", .{ expr, s.text.not_available }));
    const array = v.rank > v.chosen.len;
    const size: u64 = switch (v.t.kind) {
        .integer, .real, .logical, .complex, .character => v.t.size,
        else => 0,
    };
    if (v.t.kind == .derived and !array) return none(s, a, req, try a.print("{s} is of a derived type: a data breakpoint watches a scalar, an element or a small component", .{expr}));
    if (try data_ids.refusal(a, expr, array, size)) |w| return none(s, a, req, w);
    if (std.mem.findScalar(u64, &.{ 1, 2, 4, 8 }, size) == null or v.address % size != 0)
        return none(s, a, req, try a.print("{s}: the processor watches 1, 2, 4 or 8 bytes at an address of their size ({d} at 0x{x})", .{ expr, size, v.address }));
    s.respond(a, req, .{ .dataId = try data_ids.format(a, v.address, size, expr), .description = expr, .accessTypes = &[_][]const u8{ "write", "readWrite" }, .canPersist = false });
}

fn none(s: *Session, a: Allocator, req: Value, why: []const u8) void {
    s.respond(a, req, .{ .dataId = @as(?[]const u8, null), .description = why });
}

/// `setDataBreakpoints`: in place of those before
pub fn set(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    for (s.data_breakpoints.items) |id| {
        s.engine.removeBreakpoint(id);
        engine_conditions.forget(s, id);
    }
    s.data_breakpoints.clearRetainingCapacity();
    var out: std.ArrayList(Value) = .empty;
    for (json.items(json.get(args, "breakpoints"))) |b| {
        const d = data_ids.parse(json.str(json.get(b, "dataId")) orelse "") orelse {
            try out.append(a, try json.from(a, .{ .verified = false, .message = "not a data breakpoint of zfls's" }));
            continue;
        };
        const read = std.mem.eql(u8, json.str(json.get(b, "accessType")) orelse "write", "readWrite");
        const id = s.engine.addDataBreakpoint(d.address, d.size, read) catch {
            try out.append(a, try json.from(a, .{ .verified = false, .message = try a.print("{s}: the engine set no processor breakpoint", .{d.expr}) }));
            continue;
        };
        try s.data_breakpoints.append(s.gpa, id);
        if (try engine_conditions.keep(s, a, id, b)) |why| {
            try out.append(a, try json.from(a, .{ .id = id, .verified = false, .message = why }));
        } else try out.append(a, try json.from(a, .{ .id = id, .verified = true, .message = d.expr }));
    }
    s.respond(a, req, .{ .breakpoints = out.items });
}

pub fn isDataBreakpoint(s: *Session, id: u32) bool {
    return std.mem.findScalar(u32, s.data_breakpoints.items, id) != null;
}
