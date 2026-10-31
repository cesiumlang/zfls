//! Compiling a pattern: the parser of the pattern syntax into a tree of
//! nodes, and the compiler of that tree into the instructions the matcher
//! runs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const regex = @import("../regex.zig");
const Regex = regex.Regex;
const CompileError = regex.CompileError;
const max_loop_regs = regex.max_loop_regs;
const Inst = regex.Inst;
const Class = regex.Class;
const Node = regex.Node;
const isWordChar = regex.isWordChar;

pub const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    ignore_case: bool,
    ngroups: u16 = 1,
    classes: std.ArrayList(Class) = .empty,
    names: std.ArrayList(Regex.Name) = .empty,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn newNode(p: *Parser, n: Node) !*Node {
        const ptr = try p.a.create(Node);
        ptr.* = n;
        return ptr;
    }

    pub fn parseAlt(p: *Parser) CompileError!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(p.a, try p.parseConcat());
        while (p.peek() == '|') {
            p.pos += 1;
            try branches.append(p.a, try p.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return p.newNode(.{ .alt = branches.items });
    }

    fn parseConcat(p: *Parser) CompileError!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try p.parseAtom();
            atom = try p.parseQuantifiers(atom);
            try items.append(p.a, atom);
        }
        if (items.items.len == 0) return p.newNode(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.newNode(.{ .concat = items.items });
    }

    fn parseQuantifiers(p: *Parser, atom_in: *Node) CompileError!*Node {
        var atom = atom_in;
        while (p.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => p.pos += 1,
                '+' => {
                    min = 1;
                    p.pos += 1;
                },
                '?' => {
                    max = 1;
                    p.pos += 1;
                },
                '{' => {
                    const q = p.tryParseBraces() orelse return atom;
                    min = q[0].?;
                    max = q[1];
                },
                else => return atom,
            }
            var greedy = true;
            if (p.peek() == '?') {
                greedy = false;
                p.pos += 1;
            } else if (p.peek() == '+') {
                // possessive (Python 3.11); treat as greedy
                p.pos += 1;
            }
            atom = try p.newNode(.{ .repeat = .{ .child = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    fn tryParseBraces(p: *Parser) ?[2]?u32 {
        // p.src[p.pos] == '{'
        const close = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse return null;
        const body = p.src[p.pos + 1 .. close];
        if (body.len == 0) return null;
        for (body) |ch| if (!std.ascii.isDigit(ch) and ch != ',') return null;
        var res: [2]?u32 = .{ 0, null };
        if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
            const lo = body[0..comma];
            const hi = body[comma + 1 ..];
            if (std.mem.indexOfScalar(u8, hi, ',') != null) return null;
            res[0] = if (lo.len == 0) 0 else std.fmt.parseInt(u32, lo, 10) catch return null;
            res[1] = if (hi.len == 0) null else std.fmt.parseInt(u32, hi, 10) catch return null;
        } else {
            const n = std.fmt.parseInt(u32, body, 10) catch return null;
            res = .{ n, n };
        }
        p.pos = close + 1;
        return res;
    }

    fn charNode(p: *Parser, c: u8) !*Node {
        if (p.ignore_case and std.ascii.isAlphabetic(c)) {
            return p.newNode(.{ .char = std.ascii.toLower(c) });
        }
        return p.newNode(.{ .char = c });
    }

    fn classNode(p: *Parser, cls: Class) !*Node {
        try p.classes.append(p.a, cls);
        return p.newNode(.{ .class = @intCast(p.classes.items.len - 1) });
    }

    fn parseAtom(p: *Parser) CompileError!*Node {
        const c = p.src[p.pos];
        p.pos += 1;
        switch (c) {
            '.' => return p.newNode(.any_nonl),
            '^' => return p.newNode(.{ .assert = .bol }),
            '$' => return p.newNode(.{ .assert = .eol }),
            '[' => return p.parseClass(),
            '(' => return p.parseGroup(),
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return error.InvalidPattern,
            else => return p.charNode(c),
        }
    }

    fn parseGroup(p: *Parser) CompileError!*Node {
        if (p.peek() == '?') {
            p.pos += 1;
            const k = p.peek() orelse return error.InvalidPattern;
            switch (k) {
                ':' => {
                    p.pos += 1;
                    const child = try p.parseAlt();
                    try p.expect(')');
                    return p.newNode(.{ .group = .{ .index = null, .child = child } });
                },
                '=', '!' => {
                    p.pos += 1;
                    const child = try p.parseAlt();
                    try p.expect(')');
                    return p.newNode(.{ .look = .{ .child = child, .negate = k == '!', .behind = false } });
                },
                '<' => {
                    p.pos += 1;
                    const k2 = p.peek() orelse return error.InvalidPattern;
                    if (k2 == '=' or k2 == '!') {
                        p.pos += 1;
                        const child = try p.parseAlt();
                        try p.expect(')');
                        return p.newNode(.{ .look = .{ .child = child, .negate = k2 == '!', .behind = true } });
                    }
                    // (?<name>...) is also accepted by newer Pythons
                    return p.parseNamedGroup('>');
                },
                'P' => {
                    p.pos += 1;
                    if (p.peek() != '<') return error.InvalidPattern;
                    p.pos += 1;
                    return p.parseNamedGroup('>');
                },
                'i' => {
                    // scoped inline flag (?i:...) or (?i)
                    p.pos += 1;
                    p.ignore_case = true;
                    if (p.peek() == ')') {
                        p.pos += 1;
                        return p.newNode(.empty);
                    }
                    try p.expect(':');
                    const child = try p.parseAlt();
                    try p.expect(')');
                    return p.newNode(.{ .group = .{ .index = null, .child = child } });
                },
                else => return error.InvalidPattern,
            }
        }
        const idx = p.ngroups;
        p.ngroups += 1;
        const child = try p.parseAlt();
        try p.expect(')');
        return p.newNode(.{ .group = .{ .index = idx, .child = child } });
    }

    fn parseNamedGroup(p: *Parser, term: u8) CompileError!*Node {
        const close = std.mem.indexOfScalarPos(u8, p.src, p.pos, term) orelse return error.InvalidPattern;
        const name = p.src[p.pos..close];
        p.pos = close + 1;
        const idx = p.ngroups;
        p.ngroups += 1;
        try p.names.append(p.a, .{ .name = name, .index = idx });
        const child = try p.parseAlt();
        try p.expect(')');
        return p.newNode(.{ .group = .{ .index = idx, .child = child } });
    }

    fn expect(p: *Parser, c: u8) !void {
        if (p.peek() != c) return error.InvalidPattern;
        p.pos += 1;
    }

    fn parseEscape(p: *Parser) CompileError!*Node {
        const e = p.peek() orelse return error.InvalidPattern;
        p.pos += 1;
        switch (e) {
            'w', 'W', 's', 'S', 'd', 'D' => {
                var cls = Class.empty;
                addShorthand(&cls, e);
                return p.classNode(cls);
            },
            'b' => return p.newNode(.{ .assert = .word_boundary }),
            'B' => return p.newNode(.{ .assert = .not_word_boundary }),
            'A' => return p.newNode(.{ .assert = .start }),
            'Z' => return p.newNode(.{ .assert = .end }),
            '1'...'9' => {
                var n: u16 = e - '0';
                if (p.peek()) |d| if (std.ascii.isDigit(d)) {
                    n = n * 10 + (d - '0');
                    p.pos += 1;
                };
                return p.newNode(.{ .backref = n });
            },
            else => return p.charNode(escapeChar(e)),
        }
    }

    fn parseClass(p: *Parser) CompileError!*Node {
        var cls = Class.empty;
        var negate = false;
        if (p.peek() == '^') {
            negate = true;
            p.pos += 1;
        }
        var first = true;
        while (true) {
            const c = p.peek() orelse return error.InvalidPattern;
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            p.pos += 1;
            var lo: u8 = c;
            if (c == '\\') {
                const e = p.peek() orelse return error.InvalidPattern;
                p.pos += 1;
                switch (e) {
                    'w', 'W', 's', 'S', 'd', 'D' => {
                        addShorthand(&cls, e);
                        continue;
                    },
                    else => lo = escapeChar(e),
                }
            }
            // range?
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.pos += 1;
                var hi = p.src[p.pos];
                p.pos += 1;
                if (hi == '\\') {
                    hi = escapeChar(p.peek() orelse return error.InvalidPattern);
                    p.pos += 1;
                }
                if (hi < lo) return error.InvalidPattern;
                var ch: usize = lo;
                while (ch <= hi) : (ch += 1) cls.set(ch);
            } else {
                cls.set(lo);
            }
        }
        if (p.ignore_case) {
            var ch: usize = 0;
            while (ch < 256) : (ch += 1) {
                if (cls.isSet(ch)) {
                    const b: u8 = @intCast(ch);
                    cls.set(std.ascii.toLower(b));
                    cls.set(std.ascii.toUpper(b));
                }
            }
        }
        if (negate) cls.toggleAll();
        return p.classNode(cls);
    }
};

pub fn escapeChar(e: u8) u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 0x0c,
        'v' => 0x0b,
        'a' => 0x07,
        '0' => 0,
        else => e,
    };
}

pub fn addShorthand(cls: *Class, e: u8) void {
    var ch: usize = 0;
    while (ch < 256) : (ch += 1) {
        const b: u8 = @intCast(ch);
        const in = switch (e) {
            'w' => isWordChar(b),
            'W' => !isWordChar(b),
            's' => isSpace(b),
            'S' => !isSpace(b),
            'd' => std.ascii.isDigit(b),
            'D' => !std.ascii.isDigit(b),
            else => unreachable,
        };
        if (in) cls.set(ch);
    }
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

pub const Compiler = struct {
    a: Allocator,
    ignore_case: bool,
    progs: std.ArrayList([]const Inst) = .empty,
    nloop: u16 = 0,

    fn pc(code: *std.ArrayList(Inst)) u32 {
        return @intCast(code.items.len);
    }

    pub fn emit(c: *Compiler, code: *std.ArrayList(Inst), node: *const Node) CompileError!void {
        switch (node.*) {
            .empty => {},
            .char => |ch| try code.append(c.a, .{ .char = ch }),
            .any_nonl => try code.append(c.a, .any_nonl),
            .class => |ci| try code.append(c.a, .{ .class = ci }),
            .assert => |k| try code.append(c.a, .{ .assert = k }),
            .backref => |g| try code.append(c.a, .{ .backref = g }),
            .group => |g| {
                if (g.index) |idx| try code.append(c.a, .{ .save = idx * 2 });
                try c.emit(code, g.child);
                if (g.index) |idx| try code.append(c.a, .{ .save = idx * 2 + 1 });
            },
            .concat => |items| for (items) |it| try c.emit(code, it),
            .alt => |branches| {
                // split L1, next ; L1: branch ; jmp end ; next: ...
                var jumps: std.ArrayList(u32) = .empty;
                for (branches, 0..) |br, i| {
                    if (i + 1 < branches.len) {
                        const split_at = pc(code);
                        try code.append(c.a, .{ .split = .{ 0, 0 } });
                        try c.emit(code, br);
                        try jumps.append(c.a, pc(code));
                        try code.append(c.a, .{ .jmp = 0 });
                        code.items[split_at] = .{ .split = .{ split_at + 1, pc(code) } };
                    } else {
                        try c.emit(code, br);
                    }
                }
                const end = pc(code);
                for (jumps.items) |j| code.items[j] = .{ .jmp = end };
            },
            .repeat => |r| {
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try c.emit(code, r.child);
                if (r.max) |max| {
                    // optional copies
                    var holes: std.ArrayList(u32) = .empty;
                    var k: u32 = r.min;
                    while (k < max) : (k += 1) {
                        try holes.append(c.a, pc(code));
                        try code.append(c.a, .{ .split = .{ 0, 0 } });
                        try c.emit(code, r.child);
                    }
                    const end = pc(code);
                    for (holes.items) |h| {
                        code.items[h] = if (r.greedy) .{ .split = .{ h + 1, end } } else .{ .split = .{ end, h + 1 } };
                    }
                } else {
                    // L1: split L2, L3 ; L2: mark ; child ; check ; jmp L1 ; L3:
                    if (c.nloop >= max_loop_regs) return error.InvalidPattern;
                    const reg = c.nloop;
                    c.nloop += 1;
                    const l1 = pc(code);
                    try code.append(c.a, .{ .split = .{ 0, 0 } });
                    try code.append(c.a, .{ .loop_mark = reg });
                    try c.emit(code, r.child);
                    try code.append(c.a, .{ .loop_check = reg });
                    try code.append(c.a, .{ .jmp = l1 });
                    const l3 = pc(code);
                    code.items[l1] = if (r.greedy) .{ .split = .{ l1 + 1, l3 } } else .{ .split = .{ l3, l1 + 1 } };
                }
            },
            .look => |l| {
                var sub: std.ArrayList(Inst) = .empty;
                try c.emit(&sub, l.child);
                try sub.append(c.a, .match);
                try c.progs.append(c.a, try sub.toOwnedSlice(c.a));
                try code.append(c.a, .{ .look = .{
                    .prog = @intCast(c.progs.items.len - 1),
                    .negate = l.negate,
                    .behind = l.behind,
                } });
            },
        }
    }
};
