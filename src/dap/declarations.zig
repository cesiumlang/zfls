//! The declarations of a program's variables for `zfls dap`: zfls's index
//! of its sources, the scope of a frame's line, and the declarations its
//! variables have there or by a USE statement (their type, kind and rank).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const server_mod = @import("../server.zig");
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const paths = @import("../paths.zig");
const values = @import("values.zig");
const dbgeng = @import("dbgeng.zig");

const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;

pub fn index(s: *Session, a: Allocator, root: []const u8) void {
    const srv = server_mod.Server.create(s.gpa, s.io, .{}, &s.log) catch return;
    _ = srv.dispatchPublic(a, "initialize", json.from(a, .{ .rootPath = root }) catch return) catch {};
    s.server = srv;
}

/// The scope of a frame's line, innermost first, and its file's AST
pub fn scopeOf(s: *Session, a: Allocator, frame: Frame) ?struct { scope: *Obj, file: []const u8, line: u32 } {
    const srv = s.server orelse return null;
    const frames = s.engine.stack(a, frame.thread, frame.index + 1) catch return null;
    if (frame.index >= frames.len) return null;
    const f = frames[frame.index];
    const file = f.file orelse return null;
    const uri = paths.pathToUri(a, file) catch return null;
    const ff = (srv.fileFromUri(a, uri) catch return null) orelse return null;
    const ast = ff.ast orelse return null;
    const scope = ast.getInnerScope(f.line) orelse return null;
    return .{ .scope = scope, .file = file, .line = f.line };
}

const FrameVariable = struct { v: dbgeng.Variable, decl: ?Decl };

/// A frame's variables with their declarations: Intel's own left out (the
/// hidden lengths of CHARACTER(LEN=*) arguments, `_.t6_`, which go, in
/// order, to those arguments; its temporaries)
pub fn frameVariables(s: *Session, a: Allocator, frame: Frame) ![]FrameVariable {
    const vars = try s.engine.variables(a, frame.thread, frame.index);
    const where = scopeOf(s, a, frame);
    var lengths: std.ArrayList(u32) = .empty;
    for (vars) |v| {
        if (!v.parameter or !std.mem.startsWith(u8, v.name, "_.t") or !std.mem.endsWith(u8, v.name, "_")) continue;
        var b: [8]u8 = undefined;
        try lengths.append(a, if (s.engine.read(v.address, &b) == 8) @intCast(@min(std.mem.readInt(u64, &b, .little), 1 << 20)) else 0);
    }
    var next_length: usize = 0;
    var out: std.ArrayList(FrameVariable) = .empty;
    for (vars) |v| {
        if (std.mem.indexOfScalar(u8, v.name, '.') != null or std.mem.startsWith(u8, v.name, "_")) continue;
        var decl: ?Decl = if (where) |w| if (declaration(w.scope, v.name)) |o| declOf(a, o) else null else null;
        // a module's variable seen by a USE statement
        if (decl == null and !v.parameter) if (where) |w| if (useDeclaration(s, a, w.file, w.line, v.name)) |o| {
            decl = declOf(a, o);
        };
        if (decl) |*d| if (v.parameter and d.t.kind == .character and d.t.size == 0 and next_length < lengths.items.len) {
            d.t.size = lengths.items[next_length];
            next_length += 1;
        };
        try out.append(a, .{ .v = v, .decl = decl });
    }
    return out.items;
}

/// The declaration of a module variable that a line sees by its local
/// name (`zfls/moduleVariables`)
fn useDeclaration(s: *Session, a: Allocator, file: []const u8, line: u32, name: []const u8) ?*const Obj {
    const srv = s.server orelse return null;
    const uri = paths.pathToUri(a, file) catch return null;
    const items = srv.dispatchPublic(a, "zfls/moduleVariables", json.from(a, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line - 1, .character = 0 },
    }) catch return null) catch return null;
    const ff = (srv.fileFromUri(a, uri) catch return null) orelse return null;
    const ast = ff.ast orelse return null;
    for (json.items(items)) |it| {
        const local = json.str(json.get(it, "local")) orelse continue;
        if (!std.ascii.eqlIgnoreCase(local, name)) continue;
        const mod = srv.env(a).global(ast, json.str(json.get(it, "module")) orelse continue) orelse continue;
        const real = json.str(json.get(it, "name")) orelse local;
        for (mod.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, real)) return c;
    }
    return null;
}

/// The declaration of `name` seen from `scope`: its scopes' variables
fn declaration(scope: *Obj, name: []const u8) ?*const Obj {
    var sc: ?*Obj = scope;
    while (sc) |o| : (sc = o.parent) {
        for (o.childList()) |c| {
            if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) return c;
        }
    }
    return null;
}

pub const Decl = struct {
    t: values.Type,
    dims: []const values.Dim = &.{},
    allocatable: bool = false,
    pointer: bool = false,
    obj: ?*const Obj = null,
};

/// A declaration's type as written: `REAL(8)`, `TYPE(point)` (zfls keeps
/// the kind or the type's name apart)
pub fn declaredType(a: Allocator, o: *const Obj) []const u8 {
    const v = o.varDataConst();
    const k = v.vkind orelse return v.desc;
    // zfls keeps it as written: `(8)`, `(len=*)`, `*8`
    if (k.len > 0 and (k[0] == '(' or k[0] == '*')) return a.print("{s}{s}", .{ v.desc, k }) catch v.desc;
    return a.print("{s}({s})", .{ v.desc, k }) catch v.desc;
}

pub fn declOf(a: Allocator, o: *const Obj) Decl {
    var d: Decl = .{ .t = values.parseType(declaredType(a, o)), .obj = o };
    for (o.keywords.items) |k| switch (k) {
        .allocatable => d.allocatable = true,
        .pointer => d.pointer = true,
        else => {},
    };
    if (o.keyword_info.dimension) |dims| d.dims = values.parseDims(a, dims) catch &.{};
    return d;
}

/// A derived type's definition, by name, from `scope` or the modules
pub fn typeDefinition(s: *Session, scope: *Obj, name: []const u8) ?*const Obj {
    var sc: ?*Obj = scope;
    while (sc) |o| : (sc = o.parent) {
        for (o.childList()) |c| if (c.kind == .type and std.ascii.eqlIgnoreCase(c.name, name)) return c;
    }
    const srv = s.server orelse return null;
    var it = srv.workspace.iterator();
    while (it.next()) |kv| {
        const ast = kv.value_ptr.*.ast orelse continue;
        for (ast.scope_list.items) |o| if (o.kind == .type and std.ascii.eqlIgnoreCase(o.name, name)) return o;
    }
    return null;
}
