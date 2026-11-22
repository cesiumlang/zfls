//! The Debug Console's completions on Windows's Debugger Engine (#744),
//! whose console takes expressions: after `%`, the components of the
//! designator before it (`origin%`, `t%po`); else the frame's variables and
//! the module variables its line sees.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const Node = session.Node;
const Frame = session.Frame;
const memory = @import("memory.zig");
const variables = @import("variables.zig");
const completions = @import("completions.zig");

pub fn complete(s: *Session, a: Allocator, req: Value, args: ?Value, frame: Frame) !void {
    const at = completions.Cursor.of(s, a, args);
    const d = completions.designatorAt(at.before) orelse return s.respond(a, req, .{ .targets = &[_]Value{} });
    const names = if (d.base) |base| try components(s, a, frame, base) else try frameNames(s, a, frame);
    const t = try completions.targets(a, names, d, at) orelse &.{};
    s.respond(a, req, .{ .targets = t });
}

fn components(s: *Session, a: Allocator, frame: Frame, base: []const u8) ![]const []const u8 {
    const v = (memory.evaluate(s, a, frame, base) catch return &.{}) orelse return &.{};
    const shown = try variables.show(s, a, base, v);
    const ref = json.int(json.get(shown, "variablesReference")) orelse 0;
    if (ref <= 0) return &.{};
    return namesOf(s, a, s.nodes.items[@intCast(ref - 1)]);
}

/// The names of a node's children, but an array's elements' and sections'
fn namesOf(s: *Session, a: Allocator, node: Node) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (variables.children(s, a, node) catch return &.{}) |k| {
        const name = json.str(json.get(k, "name")) orelse continue;
        if (name.len > 0 and name[0] != '(') try out.append(a, completions.localName(name));
    }
    return out.items;
}

fn frameNames(s: *Session, a: Allocator, frame: Frame) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, try namesOf(s, a, .{ .locals = frame }));
    for (variables.children(s, a, .{ .modules = frame }) catch &.{}) |m| {
        const ref = json.int(json.get(m, "variablesReference")) orelse continue;
        if (ref > 0) try out.appendSlice(a, try namesOf(s, a, s.nodes.items[@intCast(ref - 1)]));
    }
    return out.items;
}
