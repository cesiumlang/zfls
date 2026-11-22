//! The entities that the Flang oracle compares: from LLVM Flang's scope
//! tree (dump.zig) and from zfls's object tree (`--debug_parser`), each a
//! map from a lowercase path (`module::procedure::name`) to its kind.
//!
//! The paths are made the same way on both sides: a module, a submodule, a
//! main program, a BLOCK DATA and an external procedure are at the top;
//! the entities of a construct (BLOCK, ASSOCIATE, SELECT TYPE, ...) are
//! the enclosing scope's; an interface body is a procedure of the scope
//! of its interface block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dump = @import("dump.zig");
const types = @import("types.zig");

pub const Kind = enum {
    /// a module, a submodule or a main program
    unit,
    block_data,
    procedure,
    /// a named generic interface, or a generic binding
    generic,
    type,
    /// a variable, a named constant, a component, a type parameter, an
    /// associate name
    variable,
    /// zfls: a type-bound procedure, a procedure pointer component, a
    /// procedure declared with a PROCEDURE statement
    method,
    /// Flang: a type-bound procedure
    binding,
    /// Flang: a procedure entity (EXTERNAL, PROCEDURE(), a dummy
    /// procedure, a procedure pointer)
    proc_entity,
    /// Flang: a procedure pointer component
    proc_component,
    /// Flang: a COMMON block
    common,
    /// Flang: a NAMELIST group
    namelist,
};

/// Whether Flang's kind and zfls's name the same thing: zfls has one kind
/// (7) for what is declared with PROCEDURE (a binding, a procedure pointer
/// component or a procedure entity), and keeps a procedure entity of a type
/// declaration or an EXTERNAL statement as a variable
pub fn sameKind(flang: Kind, zfls: Kind) bool {
    if (flang == zfls) return true;
    return switch (flang) {
        .binding, .proc_component => zfls == .method,
        .proc_entity => zfls == .method or zfls == .variable,
        else => false,
    };
}

pub const Entities = std.array_hash_map.String(Kind);

pub const Error = error{UnknownDetails} || Allocator.Error;

/// What `fromFlang` could not read: the symbol's line in the dump
pub const Unknown = struct { line: usize, details: []const u8 };

const Walk = struct {
    a: Allocator,
    out: *Entities,
    unknown: *?Unknown,
    /// the variables, in the order of the dump
    vars: ?*std.ArrayList(types.Item) = null,
    /// Flang's own kinds of construct scopes are not listed: any scope of
    /// a kind other than these is a construct
    fn isConstruct(kind: []const u8) bool {
        for ([_][]const u8{ "Global", "IntrinsicModules", "Module", "MainProgram", "Subprogram", "BlockData", "DerivedType" }) |k| {
            if (std.mem.eql(u8, kind, k)) return false;
        }
        return true;
    }

    fn join(self: Walk, path: []const u8, name: []const u8) ![]const u8 {
        const low = try std.ascii.allocLowerString(self.a, plainName(name));
        return if (path.len == 0) low else self.a.print("{s}::{s}", .{ path, low });
    }

    fn scope(self: Walk, s: *const dump.Scope, path: []const u8) Error!void {
        for (s.symbols.items) |sym| {
            const kind = try self.classify(s, sym) orelse continue;
            const name = if (sym.name.len == 0 and std.mem.eql(u8, sym.details, "MainProgram")) unnamed_program else sym.name;
            const p = try self.join(path, name);
            try self.out.put(self.a, p, kind);
            if (self.vars) |vars| if (std.mem.eql(u8, sym.details, "ObjectEntity") or std.mem.eql(u8, sym.details, "AssocEntity"))
                try vars.append(self.a, .{ .path = p, .v = try types.varOf(self.a, sym) });
        }
        for (s.children.items) |c| {
            if (std.mem.eql(u8, c.kind, "IntrinsicModules")) continue;
            if (isConstruct(c.kind)) {
                try self.scope(c, path);
                continue;
            }
            const name = c.name orelse if (std.mem.eql(u8, c.kind, "MainProgram")) unnamed_program else return error.UnknownDetails;
            // one Flang made (`.dp.t.c`, an instantiation of a type)
            if (std.mem.startsWith(u8, name, ".")) continue;
            // a module read from a module file, not this file's
            if (s.parent == null) if (s.symbol(name)) |g| if (g.hasFlag("ModFile")) continue;
            const top = std.mem.eql(u8, c.kind, "Module") or std.mem.eql(u8, c.kind, "MainProgram") or std.mem.eql(u8, c.kind, "BlockData");
            const p = if (top) try self.join("", name) else try self.join(path, name);
            // a submodule, inside its ancestor's scope, has no symbol
            if (std.mem.eql(u8, c.kind, "Module") and std.mem.eql(u8, s.kind, "Module")) try self.out.put(self.a, p, .unit);
            if (std.mem.eql(u8, c.kind, "BlockData")) try self.out.put(self.a, p, .block_data);
            try self.scope(c, p);
        }
    }

    /// The kind of a symbol of `s`, or null for one that is not declared
    /// there: a name it has by USE or host association, a name Flang made
    /// (`.c.`, `.dt.`, `.n.`, ...: CompilerCreated), an intrinsic, an undeclared name typed
    /// implicitly (a Cray pointee is declared), a parent component, a construct name, and the external
    /// procedures referenced, which Flang lists in the global scope
    fn classify(self: Walk, s: *const dump.Scope, sym: dump.Symbol) Error!?Kind {
        const d = sym.details;
        if (sym.hasFlag("CompilerCreated")) return null;
        if ((sym.hasFlag("Implicit") and !sym.hasFlag("CrayPointee")) or sym.hasFlag("ParentComp")) return null;
        for ([_][]const u8{ "Use", "UseError", "HostAssoc", "Misc" }) |skip| if (std.mem.eql(u8, d, skip)) return null;
        const global = s.parent == null;
        if (std.mem.eql(u8, d, "ProcEntity")) {
            if (sym.hasAttr("INTRINSIC") or global) return null;
            return if (std.mem.eql(u8, s.kind, "DerivedType")) .proc_component else .proc_entity;
        }
        if (global) {
            if (sym.hasFlag("ModFile")) return null;
            if (std.mem.eql(u8, d, "Module") or std.mem.eql(u8, d, "MainProgram")) return .unit;
            if (std.mem.eql(u8, d, "Subprogram")) {
                // BLOCK DATA is a subprogram there: its scope says what it is
                for (s.children.items) |c| if (c.name) |n| if (std.mem.eql(u8, c.kind, "BlockData") and std.ascii.eqlIgnoreCase(n, sym.name)) return null;
                return .procedure;
            }
        }
        const kinds = [_]struct { []const u8, Kind }{
            .{ "ObjectEntity", .variable },
            .{ "AssocEntity", .variable },
            .{ "TypeParam", .variable },
            .{ "Subprogram", .procedure },
            .{ "ProcBinding", .binding },
            .{ "Generic", .generic },
            .{ "DerivedType", .type },
            .{ "CommonBlockDetails", .common },
            .{ "Namelist", .namelist },
        };
        for (kinds) |k| if (std.mem.eql(u8, d, k[0])) return k[1];
        self.unknown.* = .{ .line = sym.line, .details = d };
        return error.UnknownDetails;
    }
};

/// The name zfls gives a main program without one, which Flang leaves
/// without a name
const unnamed_program = "main";

/// A name as zfls has it: Flang names a DEC STRUCTURE `/name/`, apart from
/// the entities of its scope
fn plainName(name: []const u8) []const u8 {
    if (name.len > 2 and name[0] == '/' and name[name.len - 1] == '/') return name[1 .. name.len - 1];
    return name;
}

/// The entities that a file declares, from Flang's dump of it: those of
/// its global scope, but not of the modules that Flang read from module
/// files nor of its intrinsic modules; and its variables, in `vars`
pub fn fromFlang(a: Allocator, global: *const dump.Scope, unknown: *?Unknown, vars: ?*std.ArrayList(types.Item)) Error!Entities {
    var out: Entities = .empty;
    try (Walk{ .a = a, .out = &out, .unknown = unknown, .vars = vars }).scope(global, "");
    return out;
}

/// The entities of module `name` as Flang read it from its module file:
/// its scope at the top or among the intrinsic modules; and its variables,
/// in `vars`
pub fn fromFlangModule(a: Allocator, global: *const dump.Scope, name: []const u8, unknown: *?Unknown, vars: ?*std.ArrayList(types.Item)) Error!?Entities {
    const m = findModule(global, name) orelse return null;
    var out: Entities = .empty;
    const w: Walk = .{ .a = a, .out = &out, .unknown = unknown, .vars = vars };
    const path = try std.ascii.allocLowerString(a, name);
    try out.put(a, path, .unit);
    try w.scope(m, path);
    return out;
}

fn findModule(s: *const dump.Scope, name: []const u8) ?*const dump.Scope {
    for (s.children.items) |c| {
        if (std.mem.eql(u8, c.kind, "Module")) if (c.name) |n| if (std.ascii.eqlIgnoreCase(n, name)) return c;
        if (std.mem.eql(u8, c.kind, "IntrinsicModules")) if (findModule(c, name)) |m| return m;
    }
    return null;
}

/// zfls's object kinds (`constants.TypeId`)
fn zflsKind(code: i64, top: bool) ?Kind {
    return switch (code) {
        // -1: a MODULE PROCEDURE body in a submodule
        -1, 2, 3 => .procedure,
        1, 8 => .unit,
        4 => .type,
        5 => .generic,
        6 => .variable,
        7 => .method,
        // a BLOCK DATA is a BLOCK at the top
        9 => if (top) .block_data else null,
        else => null,
    };
}

/// A variable's declaration in zfls (the first line of its hover), by its
/// path
pub const Declared = struct { path: []const u8, decl: []const u8 };

/// The entities of zfls's object tree (`--debug_parser` output), null when
/// it printed none; and the declarations of its variables, in `decls`
pub fn fromZfls(a: Allocator, out: []const u8, decls: ?*std.ArrayList(Declared)) Allocator.Error!?Entities {
    const start = std.mem.find(u8, out, "Object Tree") orelse return null;
    var tree = out[start + "Object Tree".len ..];
    if (std.mem.find(u8, tree, "Exportable Objects")) |end| tree = tree[0..end];
    // `group`: a COMMON block or NAMELIST group, which the tree marks
    const Row = struct { kind: i64, fqsn: []const u8, group: ?Kind = null };
    var rows: std.ArrayList(Row) = .empty;
    // the paths that are interfaces, and those that are something else:
    // a generic and its specific of the same name are both (#469)
    var paths: Paths = .{};
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.find(u8, line, ": ") orelse continue;
        const kind = std.fmt.parseInt(i64, line[0..colon], 10) catch continue;
        var fqsn = try std.ascii.allocLowerString(a, line[colon + 2 ..]);
        var group: ?Kind = null;
        if (std.mem.endsWith(u8, fqsn, " common")) {
            // `m::/blk/`: Flang's `m::blk`, and `m::` of blank common
            fqsn = fqsn[0 .. fqsn.len - " common".len];
            const last = lastPart(fqsn);
            if (last.len >= 2 and last[0] == '/' and last[last.len - 1] == '/') {
                fqsn = try std.mem.concat(a, u8, &.{ fqsn[0 .. fqsn.len - last.len], last[1 .. last.len - 1] });
            }
            group = .common;
        } else if (std.mem.endsWith(u8, fqsn, " namelist")) {
            fqsn = fqsn[0 .. fqsn.len - " namelist".len];
            group = .namelist;
        }
        if (fqsn.len == 0) continue;
        try rows.append(a, .{ .kind = kind, .fqsn = fqsn, .group = group });
        if (kind == 5) try paths.interfaces.put(a, fqsn, {}) else try paths.others.put(a, fqsn, kind);
    }
    var res: Entities = .empty;
    for (rows.items) |r| {
        const top = std.mem.find(u8, r.fqsn, "::") == null;
        // a construct, and an interface block without a name (abstract,
        // OPERATOR, ASSIGNMENT), are no entities
        if (!top and r.kind >= 9 and r.kind <= 15) continue;
        if (r.kind == 5 and std.mem.startsWith(u8, lastPart(r.fqsn), "#")) continue;
        const kind = r.group orelse zflsKind(r.kind, top) orelse continue;
        // one name of two entities, which is one symbol of Flang's: a
        // generic and a specific of its name are the generic, a type and a
        // generic of its name (its structure constructor) the type
        const gop = try res.getOrPut(a, try paths.flatten(a, r.fqsn));
        if (!gop.found_existing or rank(kind) > rank(gop.value_ptr.*)) gop.value_ptr.* = kind;
    }
    const list = decls orelse return res;
    const d = std.mem.find(u8, out, "\nDeclarations") orelse return res;
    var lines = std.mem.splitScalar(u8, out[d..], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const sep = std.mem.find(u8, line, ": ") orelse continue;
        try list.append(a, .{ .path = try paths.flatten(a, try std.ascii.allocLowerString(a, line[0..sep])), .decl = line[sep + 2 ..] });
    }
    return res;
}

/// The kinds of zfls's paths, which make them Flang's
const Paths = struct {
    interfaces: std.StringHashMapUnmanaged(void) = .empty,
    others: std.StringHashMapUnmanaged(i64) = .empty,

    /// `fqsn` without the constructs and interface blocks it is in
    fn flatten(self: *const Paths, a: Allocator, fqsn: []const u8) ![]const u8 {
        var kept: std.ArrayList(u8) = .empty;
        var parts = std.mem.splitSequence(u8, fqsn, "::");
        var prefix_end: usize = 0;
        var first = true;
        while (parts.next()) |p| {
            prefix_end += p.len;
            const prefix = fqsn[0..prefix_end];
            const pk = self.others.get(prefix) orelse 0;
            const last = prefix_end == fqsn.len;
            const drop = !last and !first and ((pk >= 9 and pk <= 15) or (pk == 0 and self.interfaces.contains(prefix)));
            if (!drop) {
                if (kept.items.len > 0) try kept.appendSlice(a, "::");
                try kept.appendSlice(a, p);
            }
            first = false;
            prefix_end += 2;
        }
        return kept.items;
    }
};

/// Of the kinds of zfls's entities of one name, the one Flang's symbol has
fn rank(k: Kind) u8 {
    return switch (k) {
        .type => 2,
        .generic => 1,
        else => 0,
    };
}

fn lastPart(s: []const u8) []const u8 {
    const i = std.mem.findLast(u8, s, "::") orelse return s;
    return s[i + 2 ..];
}

test "Flang's entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try dump.parse(a,
        \\Global scope: size=0 alignment=1 sourceRange=0 bytes
        \\  P: MainProgram
        \\  m: Module
        \\  bd: Subprogram ()
        \\  used (ModFile): Module
        \\  ext_ref, EXTERNAL (Subroutine): ProcEntity
        \\  Module scope: m size=0 alignment=1 sourceRange=186 bytes
        \\    .n.t, SAVE, TARGET (CompilerCreated, ReadOnly): ObjectEntity type: CHARACTER(1_8,1)
        \\    s, PUBLIC (Subroutine): Subprogram (REAL(4) a)
        \\    t, PUBLIC: DerivedType components: x
        \\    gen, PUBLIC (Subroutine): Generic Name procs: s
        \\    DerivedType scope: t sourceRange=171 bytes
        \\      fp, NOPASS, POINTER: ProcEntity iface => NULL()
        \\      x: ObjectEntity type: REAL(4)
        \\      b: ProcBinding => s
        \\    Subprogram scope: s size=0 alignment=1 sourceRange=76 bytes
        \\      a: ObjectEntity dummy type: REAL(4)
        \\      s (Subroutine): HostAssoc => s
        \\      sqrt, ELEMENTAL, INTRINSIC, PURE (Function): ProcEntity
        \\      u (Implicit) size=4 offset=4: ObjectEntity type: REAL(4)
        \\      BlockConstruct scope: size=4 alignment=4 sourceRange=70 bytes
        \\        tmp size=4 offset=0: ObjectEntity type: INTEGER(4)
        \\    Module scope: sub size=0 alignment=1 sourceRange=1 bytes
        \\      v: ObjectEntity type: REAL(4)
        \\  Module scope: used size=0 alignment=1 sourceRange=1 bytes
        \\    w: ObjectEntity type: REAL(4)
        \\  BlockData scope: bd size=0 alignment=1 sourceRange=68 bytes
        \\    q size=4 offset=0: ObjectEntity type: INTEGER(4)
        \\  MainProgram scope: P size=48 alignment=8 sourceRange=116 bytes
        \\    s (Subroutine): Use from s in m
    );
    var unknown: ?Unknown = null;
    const e = try fromFlang(a, r.global, &unknown, null);
    const want = [_]struct { []const u8, Kind }{
        .{ "p", .unit },             .{ "m", .unit },          .{ "m::s", .procedure },
        .{ "m::t", .type },          .{ "m::gen", .generic },  .{ "m::t::fp", .proc_component },
        .{ "m::t::x", .variable },   .{ "m::t::b", .binding }, .{ "m::s::a", .variable },
        .{ "m::s::tmp", .variable }, .{ "sub", .unit },        .{ "sub::v", .variable },
        .{ "bd", .block_data },      .{ "bd::q", .variable },
    };
    for (want) |w| try std.testing.expectEqual(w[1], e.get(w[0]) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(want.len, e.count());
    const u = (try fromFlangModule(a, r.global, "used", &unknown, null)).?;
    try std.testing.expectEqual(2, u.count());
    try std.testing.expectEqual(.variable, u.get("used::w").?);
    const bad = try dump.parse(a, "Global scope: size=0\n  Module scope: m size=0\n    x: Novel thing\n");
    try std.testing.expectError(error.UnknownDetails, fromFlang(a, bad.global, &unknown, null));
    try std.testing.expectEqual(3, unknown.?.line);
}

test "zfls's entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var decls: std.ArrayList(Declared) = .empty;
    const z = (try fromZfls(a,
        \\Object Tree
        \\1: m
        \\  5: m::#gen_int1
        \\    3: m::#gen_int1::f
        \\      6: m::#gen_int1::f::x
        \\  5: m::gen
        \\    2: m::gen::b
        \\  2: m::s
        \\    9: m::s::#block1
        \\      6: m::s::#block1::tmp
        \\5: m::same
        \\  2: m::same::same
        \\    6: m::same::same::arg
        \\5: m::spec
        \\2: m::spec
        \\  6: m::spec::d
        \\9: bd
        \\  6: bd::q
        \\Exportable Objects
        \\6: ignored::x
        \\Declarations
        \\m::s::#block1::tmp: INTEGER :: tmp
    , &decls)).?;
    try std.testing.expectEqual(1, decls.items.len);
    try std.testing.expectEqualStrings("m::s::tmp", decls.items[0].path);
    const want = [_]struct { []const u8, Kind }{
        .{ "m", .unit },              .{ "m::f", .procedure },        .{ "m::f::x", .variable },
        .{ "m::gen", .generic },      .{ "m::b", .procedure },        .{ "m::s", .procedure },
        .{ "m::s::tmp", .variable },  .{ "bd", .block_data },         .{ "bd::q", .variable },
        .{ "m::same", .generic },     .{ "m::same::arg", .variable }, .{ "m::spec", .generic },
        .{ "m::spec::d", .variable },
    };
    for (want) |w| try std.testing.expectEqual(w[1], z.get(w[0]) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(want.len, z.count());
}
