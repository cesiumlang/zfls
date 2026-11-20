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
    // the declarations of every procedure's variables: no summaries
    srv.summaries = false;
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
        if (std.mem.findScalar(u8, v.name, '.') != null or std.mem.startsWith(u8, v.name, "_")) continue;
        var decl: ?Decl = if (where) |w| if (declaration(w.scope, v.name)) |o| declOf(a, o) else null else null;
        // a module's variable seen by a USE statement
        if (decl == null and !v.parameter) if (where) |w| if (useDeclaration(s, a, w.file, w.line, v.name)) |o| {
            decl = declOf(a, o);
        };
        if (decl) |*d| if (v.parameter and d.t.kind == .character and d.t.size == 0) {
            if (flangLength(s, vars, v.name)) |n| {
                d.t.size = n;
            } else if (next_length < lengths.items.len) {
                d.t.size = lengths.items[next_length];
                next_length += 1;
            }
        };
        try out.append(a, .{ .v = v, .decl = decl });
    }
    if (where) |w| try addStatics(s, a, frame, w.scope, &out);
    return out.items;
}

/// The length of a CHARACTER(LEN=*) dummy argument of LLVM Flang's: a
/// hidden local of the frame, `.` and the argument's mangled name and `1`
/// (`._QMgridFworkEs1` of `s`)
fn flangLength(s: *Session, vars: []const dbgeng.Variable, name: []const u8) ?u32 {
    for (vars) |v| {
        if (v.name.len < name.len + 4 or v.name[0] != '.' or v.name[v.name.len - 1] != '1') continue;
        const tail = v.name[v.name.len - 1 - name.len - 1 .. v.name.len - 1];
        if (tail[0] != 'E' or !std.ascii.eqlIgnoreCase(tail[1..], name)) continue;
        var b: [8]u8 = undefined;
        if (s.engine.read(v.address, &b) != 8) return null;
        return @intCast(@min(std.mem.readInt(u64, &b, .little), 1 << 20));
    }
    return null;
}

/// The variables of `scope` that LLVM Flang makes static (a main program's
/// initialized, ALLOCATABLE, TARGET or SAVE ones), which are not the
/// frame's but globals of their own names (CodeView's `S_GDATA32`, `v`):
/// each that is not a module's variable of that name (whose public symbol
/// is `_QM<module>E<name>`), when there is one such
fn addStatics(s: *Session, a: Allocator, frame: Frame, scope: *Obj, out: *std.ArrayList(FrameVariable)) !void {
    const frames = try s.engine.stack(a, frame.thread, frame.index + 1);
    if (frame.index >= frames.len) return;
    const mod_base = s.engine.moduleBase(frames[frame.index].instruction) orelse return;
    for (scope.childList()) |c| {
        if (c.kind != .variable) continue;
        const listed = for (out.items) |fv| {
            if (std.ascii.eqlIgnoreCase(fv.v.name, c.name)) break true;
        } else false;
        if (listed or hasKeyword(c, .parameter) or hasKeyword(c, .external)) continue;
        const name = try std.ascii.allocLowerString(a, c.name);
        const modules = try s.engine.globalsNamed(a, mod_base, try a.print("QM*E{s}", .{name}));
        var found: ?dbgeng.Variable = null;
        var count: usize = 0;
        for (try s.engine.globalsNamed(a, mod_base, name)) |g| {
            if (g.type_index == 0) continue;
            const of_module = for (modules) |m| {
                if (m.address == g.address) break true;
            } else false;
            if (of_module) continue;
            found = g;
            count += 1;
        }
        if (count == 1) try out.append(a, .{ .v = found.?, .decl = declOf(a, c) });
    }
}

fn hasKeyword(o: *const Obj, k: @import("../constants.zig").Kw) bool {
    for (o.keywords.items) |x| if (x == k) return true;
    return false;
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

/// A module of the sources, by its name
pub fn moduleNamed(s: *Session, name: []const u8) ?*const Obj {
    const srv = s.server orelse return null;
    var it = srv.workspace.iterator();
    while (it.next()) |kv| {
        const ast = kv.value_ptr.*.ast orelse continue;
        for (ast.scope_list.items) |o| if (o.kind == .module and std.ascii.eqlIgnoreCase(o.name, name)) return o;
    }
    return null;
}

/// Whether `name` is an intrinsic module of zfls's tables (no module of the
/// sources): its named constants are no program's variables
pub fn isIntrinsicModule(s: *Session, name: []const u8) bool {
    const srv = s.server orelse return false;
    if (moduleNamed(s, name) != null) return false;
    for (srv.intr.mods) |m| if (std.ascii.eqlIgnoreCase(m.name, name)) return true;
    return false;
}

/// The declaration of a module's variable
pub fn moduleDecl(s: *Session, a: Allocator, module: []const u8, name: []const u8) ?Decl {
    const mod = moduleNamed(s, module) orelse return null;
    for (mod.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) return declOf(a, c);
    return null;
}

/// The module variable that a frame's line sees by `name`, its module's
/// and its own name there (a USE may rename it): host and use
/// association (`zfls/moduleVariables`)
pub fn seenModuleVariable(s: *Session, a: Allocator, frame: Frame, name: []const u8) ?struct { module: []const u8, name: []const u8 } {
    const where = scopeOf(s, a, frame) orelse return null;
    const srv = s.server orelse return null;
    const uri = paths.pathToUri(a, where.file) catch return null;
    const items = srv.dispatchPublic(a, "zfls/moduleVariables", json.from(a, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = where.line - 1, .character = 0 },
    }) catch return null) catch return null;
    for (json.items(items)) |it| {
        const real = json.str(json.get(it, "name")) orelse continue;
        const local = json.str(json.get(it, "local")) orelse real;
        if (!std.ascii.eqlIgnoreCase(local, name)) continue;
        return .{ .module = json.str(json.get(it, "module")) orelse continue, .name = real };
    }
    return null;
}

/// The place of a module's variable that its COMMON block holds (`common
/// /blk/ cx, cy` in the module): the offset in the block, by the sizes of
/// the variables before it there, and the block's name; null when it is in
/// none, or a size before it is not known
pub fn commonPlace(a: Allocator, module: *const Obj, name: []const u8) ?struct { block: []const u8, offset: u64 } {
    if (module.data != .scope) return null;
    for (module.scopeDataConst().commons.items) |blk| {
        var offset: u64 = 0;
        var depth: usize = 0;
        var start: usize = 0;
        const members = blk.varDataConst().members;
        for (members, 0..) |ch, i| {
            switch (ch) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                else => {},
            }
            if (!((ch == ',' and depth == 0) or i == members.len - 1)) continue;
            const item = std.mem.trim(u8, members[start..if (ch == ',' and depth == 0) i else i + 1], " ");
            start = i + 1;
            const member = std.mem.trim(u8, item[0 .. std.mem.findScalar(u8, item, '(') orelse item.len], " ");
            if (std.ascii.eqlIgnoreCase(member, name)) return .{ .block = std.mem.trim(u8, blk.name, "/"), .offset = offset };
            const c = for (module.childList()) |c| {
                if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, member)) break c;
            } else return null;
            offset += sizeOf(declOf(a, c)) orelse return null;
        }
    }
    return null;
}

/// The bytes of a variable of intrinsic type, of a known size and shape
fn sizeOf(d: Decl) ?u64 {
    if (d.t.kind == .derived or d.t.kind == .unknown or d.t.size == 0 or d.allocatable or d.pointer) return null;
    var n: u64 = d.t.size;
    if (d.dims.len > 0) {
        if (!values.constantShape(d.dims)) return null;
        for (d.dims) |x| n *= @intCast(@max(0, x.hi.? - x.lo.? + 1));
    }
    return n;
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
