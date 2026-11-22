//! LLVM Flang's symbol dump (`flang -fc1 -fdebug-dump-symbols`), read into
//! its tree of scopes: the one place that knows its format, which is
//! Flang's internal one and may change. A line this does not know fails
//! the read, with the line, so that the format is adapted here.
//!
//! A scope is a line `<Kind> scope: [<name>] size=...`, its symbols and
//! the scopes inside it are the lines indented two spaces more. A symbol is
//! `<name>[, <ATTR>]... [(<Flag>, ...)] [size=N offset=N]: <Details> ...`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Symbol = struct {
    /// as Flang prints it: lowercase, but the main program's in upper case
    name: []const u8,
    /// `PUBLIC`, `PARAMETER`, `INTRINSIC`, `EXTERNAL`, ...
    attrs: []const []const u8,
    /// `Function`, `Subroutine`, `Implicit`, `CompilerCreated`, ...
    flags: []const []const u8,
    /// the kind of its details: `ObjectEntity`, `Subprogram`, `Use`, ...
    details: []const u8,
    /// the rest of the line after the details' kind
    rest: []const u8,
    /// 1-based line of the dump
    line: usize,

    pub fn hasAttr(self: Symbol, attr: []const u8) bool {
        for (self.attrs) |x| if (std.mem.eql(u8, x, attr)) return true;
        return false;
    }

    pub fn hasFlag(self: Symbol, flag: []const u8) bool {
        for (self.flags) |x| if (std.mem.eql(u8, x, flag)) return true;
        return false;
    }
};

pub const Scope = struct {
    /// `Global`, `IntrinsicModules`, `Module`, `MainProgram`, `Subprogram`,
    /// `BlockData`, `DerivedType`, `BlockConstruct`, `OtherConstruct`, ...
    kind: []const u8,
    name: ?[]const u8,
    parent: ?*Scope,
    symbols: std.ArrayList(Symbol) = .empty,
    children: std.ArrayList(*Scope) = .empty,
    line: usize,

    /// The symbol of this scope named `name`
    pub fn symbol(self: *const Scope, name: []const u8) ?Symbol {
        for (self.symbols.items) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
        return null;
    }
};

/// What a line of the dump is, other than a scope or a symbol: lists of a
/// scope that name its symbols again
const notes = [_][]const u8{ "Equivalence Sets:", "Cray Pointers:" };

pub const Result = union(enum) {
    global: *Scope,
    /// a line not read: its number (1-based) and text
    bad: struct { line: usize, text: []const u8, why: []const u8 },
};

pub fn parse(a: Allocator, text: []const u8) Allocator.Error!Result {
    var global: ?*Scope = null;
    // the open scopes, by depth
    var stack: std.ArrayList(*Scope) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent % 2 != 0) return bad(n, line, "odd indentation");
        const depth = indent / 2;
        const body = line[indent..];
        if (scopeHeader(body)) |h| {
            if (depth == 0) {
                if (global != null or !std.mem.eql(u8, h.kind, "Global")) return bad(n, line, "a scope at depth 0 other than the one global scope");
            } else if (depth > stack.items.len) return bad(n, line, "a scope deeper than the scope it is in");
            stack.shrinkRetainingCapacity(depth);
            const s = try a.create(Scope);
            s.* = .{ .kind = h.kind, .name = h.name, .parent = if (depth > 0) stack.items[depth - 1] else null, .line = n };
            if (s.parent) |p| try p.children.append(a, s) else global = s;
            try stack.append(a, s);
            continue;
        }
        if (depth == 0 or depth > stack.items.len) return bad(n, line, "a line outside any scope");
        stack.shrinkRetainingCapacity(depth);
        const scope = stack.items[depth - 1];
        for (notes) |note| {
            if (std.mem.startsWith(u8, body, note)) break;
        } else {
            const sym = try symbolLine(a, body, n) orelse return bad(n, line, "neither a scope nor a symbol");
            try scope.symbols.append(a, sym);
        }
    }
    return if (global) |g| .{ .global = g } else bad(n, "", "no global scope");
}

fn bad(n: usize, text: []const u8, why: []const u8) Result {
    return .{ .bad = .{ .line = n, .text = text, .why = why } };
}

/// `<Kind> scope: [<name>] ...`: its kind and name
fn scopeHeader(body: []const u8) ?struct { kind: []const u8, name: ?[]const u8 } {
    const sp = std.mem.findScalar(u8, body, ' ') orelse return null;
    const kind = body[0..sp];
    for (kind) |c| if (!std.ascii.isAlphabetic(c)) return null;
    const key = " scope:";
    if (!std.mem.startsWith(u8, body[sp..], key)) return null;
    var words = std.mem.tokenizeScalar(u8, body[sp + key.len ..], ' ');
    const first = words.next() orelse return .{ .kind = kind, .name = null };
    // `size=0`, `sourceRange=12`: no name
    return .{ .kind = kind, .name = if (std.mem.findScalar(u8, first, '=') != null) null else first };
}

fn symbolLine(a: Allocator, body: []const u8, n: usize) Allocator.Error!?Symbol {
    const colon = std.mem.find(u8, body, ": ") orelse (if (std.mem.endsWith(u8, body, ":")) body.len - 1 else return null);
    const head = body[0..colon];
    const after = std.mem.trimStart(u8, body[@min(colon + 2, body.len)..], " ");
    var end: usize = 0;
    while (end < head.len and head[end] != ',' and head[end] != ' ') end += 1;
    // a main program without a name has none (`: MainProgram`)
    if (end == 0 and head.len > 0) return null;
    const name = head[0..end];
    var rest = head[end..];
    // the attributes, up to the flags or the size
    var attrs: std.ArrayList([]const u8) = .empty;
    while (std.mem.startsWith(u8, rest, ", ")) {
        rest = rest[2..];
        var e: usize = 0;
        while (e < rest.len and rest[e] != ',' and rest[e] != ' ') e += 1;
        // `INTENT(IN)`, `BIND(C)`
        if (e < rest.len and rest[e] == ' ' and std.mem.findScalar(u8, rest[0..e], '(') != null and std.mem.findScalar(u8, rest[0..e], ')') == null) return null;
        try attrs.append(a, rest[0..e]);
        rest = rest[e..];
    }
    var flags: std.ArrayList([]const u8) = .empty;
    if (std.mem.startsWith(u8, rest, " (")) {
        const close = std.mem.findScalar(u8, rest, ')') orelse return null;
        var fit = std.mem.tokenizeAny(u8, rest[2..close], ", ");
        while (fit.next()) |f| try flags.append(a, f);
        rest = rest[close + 1 ..];
    }
    // `size=4 offset=0`: nothing else may be left
    var words = std.mem.tokenizeScalar(u8, rest, ' ');
    while (words.next()) |w| if (!std.mem.startsWith(u8, w, "size=") and !std.mem.startsWith(u8, w, "offset=")) return null;
    var d: usize = 0;
    while (d < after.len and std.ascii.isAlphabetic(after[d])) d += 1;
    if (d == 0) return null;
    return .{
        .name = name,
        .attrs = attrs.items,
        .flags = flags.items,
        .details = after[0..d],
        // not the `:` of a deferred shape at its end (`shape: :`)
        .rest = std.mem.trimEnd(u8, std.mem.trimStart(u8, after[d..], " :"), " "),
        .line = n,
    };
}

test "a dump read into its scopes and symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a,
        \\Global scope: size=0 alignment=1 sourceRange=0 bytes
        \\  P: MainProgram
        \\  tkr: Module
        \\  IntrinsicModules scope: size=0 alignment=1 sourceRange=0 bytes
        \\    __fortran_builtins, INTRINSIC (ModFile): Module
        \\  Module scope: tkr size=0 alignment=1 sourceRange=186 bytes
        \\    .c.t, SAVE, TARGET (CompilerCreated, ReadOnly): ObjectEntity type: TYPE(component)
        \\    n_sides, PARAMETER, PUBLIC size=12 offset=4: ObjectEntity type: INTEGER(4)
        \\    assignment(=), PUBLIC (Subroutine): Generic Assignment procs: assign_it
        \\    blk size=8 offset=0: CommonBlockDetails alignment=4: c1 c2
        \\    Equivalence Sets: (e1,e2)
        \\    DerivedType scope: t sourceRange=171 bytes
        \\      shape (ParentComp) size=16 offset=0: ObjectEntity type: TYPE(shape)
        \\    Subprogram scope: s size=0 alignment=1 sourceRange=76 bytes
        \\      a, INTENT(IN) size=4 offset=0: ObjectEntity dummy type: REAL(4)
        \\      OtherConstruct scope: size=0 alignment=1 sourceRange=37 bytes
        \\        it: AssocEntity type: TYPE(child_t)
        \\  MainProgram scope: P size=48 alignment=8 sourceRange=116 bytes
        \\    s (Subroutine): Use from s in tkr
    );
    const g = r.global;
    try std.testing.expectEqualStrings("Global", g.kind);
    try std.testing.expectEqual(2, g.symbols.items.len);
    try std.testing.expectEqual(3, g.children.items.len);
    const m = g.children.items[1];
    try std.testing.expectEqualStrings("tkr", m.name.?);
    try std.testing.expectEqual(4, m.symbols.items.len);
    const c = m.symbols.items[0];
    try std.testing.expectEqualStrings(".c.t", c.name);
    try std.testing.expect(c.hasAttr("TARGET") and c.hasFlag("CompilerCreated"));
    try std.testing.expectEqualStrings("ObjectEntity", c.details);
    try std.testing.expectEqualStrings("assignment(=)", m.symbols.items[2].name);
    try std.testing.expectEqualStrings("Generic", m.symbols.items[2].details);
    try std.testing.expectEqualStrings("CommonBlockDetails", m.symbols.items[3].details);
    try std.testing.expect(m.children.items[0].symbols.items[0].hasFlag("ParentComp"));
    const s = m.children.items[1];
    try std.testing.expect(s.symbols.items[0].hasAttr("INTENT(IN)"));
    try std.testing.expectEqual(null, s.children.items[0].name);
    try std.testing.expectEqualStrings("AssocEntity", s.children.items[0].symbols.items[0].details);
    try std.testing.expectEqualStrings("Use", g.children.items[2].symbols.items[0].details);
}

test "a line it does not know fails the read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "Global scope: size=0\n  Module scope: m size=0\n    something new here\n");
    try std.testing.expectEqual(3, r.bad.line);
    try std.testing.expect((try parse(arena.allocator(), "  x: ObjectEntity\n")) == .bad);
}

test "a main program without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "Global scope: size=0\n  : MainProgram\n  MainProgram scope:  size=4 alignment=4\n    n size=4 offset=0: ObjectEntity type: INTEGER(4)\n");
    try std.testing.expectEqualStrings("", r.global.symbols.items[0].name);
    try std.testing.expectEqual(null, r.global.children.items[0].name);
}
