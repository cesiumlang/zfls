//! The Debug Console's completions with gdb (#744): after `%`, the
//! components of the designator before it (`origin%`, `p t%po`), by zfls's
//! own variables of its value; a name in an expression (`p ori`), the
//! frame's variables and the module variables its line sees; else gdb's
//! own (its commands).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");
const vars = @import("gdb_variables.zig");
const completions = @import("completions.zig");

pub fn complete(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const frame = json.int(json.get(args, "frameId"));
    const at = completions.Cursor.of(s, a, args);
    if (completions.designatorAt(at.before)) |d| {
        const names = if (d.base) |base|
            try components(s, a, base, frame)
        else if (completions.inExpression(at.before[0..d.start]))
            try frameNames(s, a, frame)
        else
            &.{};
        if (try completions.targets(a, names, d, at)) |t| return s.respond(a, req, .{ .targets = t });
    }
    try gdb.forward(s, a, req, args);
}

/// The components of `base`'s value: its children of names (not an
/// array's elements)
fn components(s: *Session, a: Allocator, base: []const u8, frame: ?i64) ![]const []const u8 {
    const r = try gdb.request(s, a, "evaluate", try vars.evalArgs(a, base, frame, "watch"));
    if (!gdb.isSuccess(r)) return &.{};
    const got: vars.Variable = .{
        .name = base,
        .value = json.str(json.path(r, &.{ "body", "result" })) orelse "",
        .type = json.str(json.path(r, &.{ "body", "type" })),
        .ref = json.int(json.path(r, &.{ "body", "variablesReference" })) orelse 0,
    };
    const v = vars.present(s, a, got, base, base, frame, null, null) catch return &.{};
    return namesOf(s, a, v.ref);
}

/// The names of a reference's children, but an array's elements'
fn namesOf(s: *Session, a: Allocator, ref: i64) ![]const []const u8 {
    if (ref == 0) return &.{};
    const node = vars.get(s, ref) orelse return &.{};
    const kids = vars.children(s, a, ref, node) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (kids) |k| if (k.name.len > 0 and k.name[0] != '(') try out.append(a, completions.localName(k.name));
    return out.items;
}

/// The frame's variables (its arguments and locals) and the module
/// variables its line sees
fn frameNames(s: *Session, a: Allocator, frame: ?i64) ![]const []const u8 {
    const f = frame orelse return &.{};
    const r = try gdb.request(s, a, "scopes", .{ .frameId = f });
    var out: std.ArrayList([]const u8) = .empty;
    for (json.items(json.path(r, &.{ "body", "scopes" }))) |sc| {
        if (json.get(sc, "expensive")) |e| if (e == .bool and e.bool) continue;
        const name = json.str(json.get(sc, "name")) orelse "";
        if (std.mem.eql(u8, name, "Registers")) continue;
        const gref = json.int(json.get(sc, "variablesReference")) orelse continue;
        try out.appendSlice(a, try namesOf(s, a, try vars.add(s, .{ .kind = .{ .gdb = gref }, .frame = f })));
    }
    if (s.g.frames.get(f)) |info| if (info.file) |file| {
        for (try @import("gdb_requests.zig").moduleVariablesAt(s, a, file, info.line)) |mv| try out.append(a, mv.local);
    };
    return out.items;
}
