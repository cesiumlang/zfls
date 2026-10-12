//! Backtracking regular expression engine implementing the subset of Python's
//! `re` syntax and semantics used by fortls.
//!
//! Supported syntax: literals, `.`, character classes (with ranges, negation
//! and the `\w \W \s \S \d \D` shorthands), greedy and lazy quantifiers
//! (`* + ? {m} {m,} {m,n}`), capturing, non-capturing and named groups,
//! alternation, the anchors `^ $ \A \Z \b \B`, lookahead and lookbehind
//! (`(?= (?! (?<= (?<!`), numeric backreferences and the inline `(?i)` flag.
//!
//! Matching is performed on bytes. Non-ASCII bytes are treated as word
//! characters, approximating Python's Unicode-aware `\w` for UTF-8 input.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Flags = packed struct {
    ignore_case: bool = false,
};

pub const I: Flags = .{ .ignore_case = true };

pub const CompileError = error{ InvalidPattern, OutOfMemory };

/// Maximum number of capture groups (including group 0).
pub const max_groups = 48;
const max_slots = max_groups * 2;
/// Extra registers used to detect zero-width iterations of `*` loops.
const max_loop_regs = 32;

const AssertKind = enum { bol, eol, start, end, word_boundary, not_word_boundary };

const Inst = union(enum) {
    char: u8,
    any_nonl,
    class: u16,
    split: [2]u32,
    jmp: u32,
    save: u16,
    assert: AssertKind,
    look: struct { prog: u16, negate: bool, behind: bool },
    backref: u16,
    loop_mark: u16,
    loop_check: u16,
    match,
};

const Class = std.bit_set.Static(256);

const Node = union(enum) {
    empty,
    char: u8,
    any_nonl,
    class: u16,
    assert: AssertKind,
    group: struct { index: ?u16, child: *Node },
    concat: []*Node,
    alt: []*Node,
    repeat: struct { child: *Node, min: u32, max: ?u32, greedy: bool },
    look: struct { child: *Node, negate: bool, behind: bool },
    backref: u16,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    progs: []const []const Inst,
    classes: []const Class,
    /// Number of groups including group 0
    ngroups: u16,
    names: []const Name,
    ignore_case: bool,
    nloop_regs: u16,

    pub const Name = struct { name: []const u8, index: u16 };

    pub fn compile(gpa: Allocator, pattern: []const u8, flags: Flags) CompileError!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var p: Parser = .{
            .a = a,
            .src = pattern,
            .ignore_case = flags.ignore_case,
        };
        // inline flags at the very start, e.g. (?i)
        while (std.mem.startsWith(u8, p.src[p.pos..], "(?i)")) {
            p.ignore_case = true;
            p.pos += 4;
        }
        const root = try p.parseAlt();
        if (p.pos != p.src.len) return error.InvalidPattern;

        var c: Compiler = .{ .a = a, .ignore_case = p.ignore_case };
        // Program 0 is the main program
        try c.progs.append(a, &.{});
        var main: std.ArrayList(Inst) = .empty;
        try main.append(a, .{ .save = 0 });
        try c.emit(&main, root);
        try main.append(a, .{ .save = 1 });
        try main.append(a, .match);
        c.progs.items[0] = try main.toOwnedSlice(a);

        if (p.ngroups > max_groups) return error.InvalidPattern;
        return .{
            .arena = arena,
            .progs = c.progs.items,
            .classes = p.classes.items,
            .ngroups = p.ngroups,
            .names = p.names.items,
            .ignore_case = p.ignore_case,
            .nloop_regs = c.nloop,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    pub fn groupIndex(self: *const Regex, name: []const u8) ?u16 {
        for (self.names) |n| if (std.mem.eql(u8, n.name, name)) return n.index;
        return null;
    }

    /// Anchored match at `pos` (Python `pattern.match(s, pos)`)
    pub fn matchAt(self: *const Regex, input: []const u8, pos: usize) ?Match {
        var m: Match = .{ .input = input, .ngroups = self.ngroups };
        if (self.run(0, input, pos, &m.slots, null, false)) return m;
        return null;
    }

    /// Anchored match at start of input (Python `pattern.match(s)`)
    pub fn match(self: *const Regex, input: []const u8) ?Match {
        return self.matchAt(input, 0);
    }

    /// Python `pattern.fullmatch(s)`
    pub fn fullmatch(self: *const Regex, input: []const u8) ?Match {
        var m: Match = .{ .input = input, .ngroups = self.ngroups };
        if (self.run(0, input, 0, &m.slots, input.len, false)) return m;
        return null;
    }

    /// Python `pattern.search(s, pos)`
    pub fn searchAt(self: *const Regex, input: []const u8, pos: usize) ?Match {
        var i = pos;
        while (i <= input.len) : (i += 1) {
            if (self.matchAt(input, i)) |m| return m;
        }
        return null;
    }

    pub fn search(self: *const Regex, input: []const u8) ?Match {
        return self.searchAt(input, 0);
    }

    pub fn iterator(self: *const Regex, input: []const u8) Iterator {
        return .{ .re = self, .input = input };
    }

    /// Python `pattern.sub(repl, s)` where `repl` is a template string
    /// supporting `\1`, `\g<1>`, `\g<name>` and the usual escapes.
    pub fn sub(self: *const Regex, a: Allocator, template: []const u8, input: []const u8) ![]u8 {
        const res = try self.subn(a, template, input);
        return res.out;
    }

    pub const SubResult = struct { out: []u8, count: usize };

    pub fn subn(self: *const Regex, a: Allocator, template: []const u8, input: []const u8) !SubResult {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var it = self.iterator(input);
        var last: usize = 0;
        var count: usize = 0;
        while (it.next()) |m| {
            try out.appendSlice(a, input[last..m.start(0)]);
            try m.expand(a, &out, template, self);
            last = m.end(0);
            count += 1;
        }
        try out.appendSlice(a, input[last..]);
        return .{ .out = try out.toOwnedSlice(a), .count = count };
    }

    /// Python `pattern.sub(func, s)` with a callback that appends the
    /// replacement for each match to `out`.
    pub fn subFn(
        self: *const Regex,
        a: Allocator,
        input: []const u8,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), Allocator, *std.ArrayList(u8), Match) Allocator.Error!void,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var it = self.iterator(input);
        var last: usize = 0;
        while (it.next()) |m| {
            try out.appendSlice(a, input[last..m.start(0)]);
            try func(ctx, a, &out, m);
            last = m.end(0);
        }
        try out.appendSlice(a, input[last..]);
        return out.toOwnedSlice(a);
    }

    /// Python `pattern.split(s)` (capture groups are not included)
    pub fn split(self: *const Regex, a: Allocator, input: []const u8) ![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(a);
        var it = self.iterator(input);
        var last: usize = 0;
        while (it.next()) |m| {
            try parts.append(a, input[last..m.start(0)]);
            last = m.end(0);
        }
        try parts.append(a, input[last..]);
        return parts.toOwnedSlice(a);
    }

    /// Python `pattern.findall(s)`: group 1 if the pattern has exactly one
    /// group, otherwise the full match.
    pub fn findall(self: *const Regex, a: Allocator, input: []const u8) ![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(a);
        var it = self.iterator(input);
        const g: u16 = if (self.ngroups == 2) 1 else 0;
        while (it.next()) |m| try parts.append(a, m.group(g) orelse "");
        return parts.toOwnedSlice(a);
    }

    // ----------------------------------------------------------------------
    // Backtracking VM

    const Frame = union(enum) {
        branch: struct { pc: u32, pos: usize },
        restore: struct { slot: u16, val: ?usize },
        restore_reg: struct { reg: u16, val: usize },
    };

    fn run(
        self: *const Regex,
        prog_index: usize,
        input: []const u8,
        start_pos: usize,
        slots: *[max_slots]?usize,
        required_end: ?usize,
        is_sub: bool,
    ) bool {
        const prog = self.progs[prog_index];
        var regs: [max_loop_regs]usize = undefined;
        @memset(&regs, std.math.maxInt(usize));
        if (!is_sub) @memset(slots, null);

        var stack_buf: [256]Frame = undefined;
        var stack: std.ArrayList(Frame) = .initBuffer(&stack_buf);
        var heap_stack: std.ArrayList(Frame) = .empty;
        defer heap_stack.deinit(std.heap.page_allocator);
        var using_heap = false;

        var pc: u32 = 0;
        var pos: usize = start_pos;

        while (true) {
            const ok: bool = blk: switch (prog[pc]) {
                .char => |c| {
                    if (pos < input.len and self.eqChar(input[pos], c)) {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .any_nonl => {
                    if (pos < input.len and input[pos] != '\n') {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .class => |ci| {
                    if (pos < input.len and self.classes[ci].isSet(input[pos])) {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .split => |targets| {
                    const fr: Frame = .{ .branch = .{ .pc = targets[1], .pos = pos } };
                    push(&stack, &heap_stack, &using_heap, fr);
                    pc = targets[0];
                    break :blk true;
                },
                .jmp => |t| {
                    pc = t;
                    break :blk true;
                },
                .save => |s| {
                    push(&stack, &heap_stack, &using_heap, .{ .restore = .{ .slot = s, .val = slots[s] } });
                    slots[s] = pos;
                    pc += 1;
                    break :blk true;
                },
                .assert => |k| {
                    if (checkAssert(k, input, pos)) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .look => |l| {
                    const matched = self.runLook(l.prog, input, pos, l.behind, slots);
                    if (matched != l.negate) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .backref => |g| {
                    const s = slots[g * 2];
                    const e = slots[g * 2 + 1];
                    if (s == null or e == null) break :blk false;
                    const ref = input[s.?..e.?];
                    if (pos + ref.len > input.len) break :blk false;
                    for (ref, 0..) |rc, k| {
                        if (!self.eqChar(input[pos + k], rc)) break :blk false;
                    }
                    pos += ref.len;
                    pc += 1;
                    break :blk true;
                },
                .loop_mark => |r| {
                    push(&stack, &heap_stack, &using_heap, .{ .restore_reg = .{ .reg = r, .val = regs[r] } });
                    regs[r] = pos;
                    pc += 1;
                    break :blk true;
                },
                .loop_check => |r| {
                    // Fail iterations that did not consume input
                    if (regs[r] == pos) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .match => {
                    if (required_end) |re| {
                        if (pos != re) break :blk false;
                    }
                    if (!is_sub) {
                        slots[1] = pos;
                    }
                    return true;
                },
            };
            if (ok) continue;
            // backtrack
            while (true) {
                const fr = pop(&stack, &heap_stack, &using_heap) orelse return false;
                switch (fr) {
                    .branch => |b| {
                        pc = b.pc;
                        pos = b.pos;
                        break;
                    },
                    .restore => |r| slots[r.slot] = r.val,
                    .restore_reg => |r| regs[r.reg] = r.val,
                }
            }
        }
    }

    fn push(stack: *std.ArrayList(Frame), heap: *std.ArrayList(Frame), using_heap: *bool, fr: Frame) void {
        if (!using_heap.*) {
            if (stack.items.len < stack.capacity) {
                stack.appendAssumeCapacity(fr);
                return;
            }
            heap.appendSlice(std.heap.page_allocator, stack.items) catch @panic("regex: out of memory");
            using_heap.* = true;
        }
        heap.append(std.heap.page_allocator, fr) catch @panic("regex: out of memory");
    }

    fn pop(stack: *std.ArrayList(Frame), heap: *std.ArrayList(Frame), using_heap: *bool) ?Frame {
        if (using_heap.*) return heap.pop();
        return stack.pop();
    }

    fn runLook(self: *const Regex, prog: u16, input: []const u8, pos: usize, behind: bool, slots: *[max_slots]?usize) bool {
        var tmp: [max_slots]?usize = slots.*;
        if (!behind) return self.run(prog, input, pos, &tmp, null, true);
        var j: usize = pos + 1;
        while (j > 0) {
            j -= 1;
            tmp = slots.*;
            if (self.run(prog, input, j, &tmp, pos, true)) return true;
        }
        return false;
    }

    inline fn eqChar(self: *const Regex, a: u8, b: u8) bool {
        if (self.ignore_case) return std.ascii.toLower(a) == b;
        return a == b;
    }
};

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn checkAssert(k: AssertKind, input: []const u8, pos: usize) bool {
    return switch (k) {
        .bol, .start => pos == 0,
        .eol => pos == input.len or (pos == input.len - 1 and input[pos] == '\n'),
        .end => pos == input.len,
        .word_boundary, .not_word_boundary => blk: {
            const before = pos > 0 and isWordChar(input[pos - 1]);
            const after = pos < input.len and isWordChar(input[pos]);
            const wb = before != after;
            break :blk if (k == .word_boundary) wb else !wb;
        },
    };
}

pub const Match = struct {
    input: []const u8,
    ngroups: u16,
    slots: [max_slots]?usize = undefined,

    pub fn start(self: Match, g: u16) usize {
        return self.slots[g * 2] orelse std.math.maxInt(usize);
    }

    pub fn end(self: Match, g: u16) usize {
        return self.slots[g * 2 + 1] orelse std.math.maxInt(usize);
    }

    /// Returns null when the group did not participate in the match
    pub fn group(self: Match, g: u16) ?[]const u8 {
        if (g >= self.ngroups) return null;
        const s = self.slots[g * 2] orelse return null;
        const e = self.slots[g * 2 + 1] orelse return null;
        return self.input[s..e];
    }

    pub fn str(self: Match) []const u8 {
        return self.group(0).?;
    }

    pub fn named(self: Match, re: *const Regex, name: []const u8) ?[]const u8 {
        const idx = re.groupIndex(name) orelse return null;
        return self.group(idx);
    }

    /// Expand a Python replacement template
    pub fn expand(self: Match, a: Allocator, out: *std.ArrayList(u8), template: []const u8, re: *const Regex) !void {
        var i: usize = 0;
        while (i < template.len) : (i += 1) {
            const c = template[i];
            if (c != '\\' or i + 1 >= template.len) {
                try out.append(a, c);
                continue;
            }
            i += 1;
            const e = template[i];
            switch (e) {
                '0'...'9' => {
                    var n: u16 = e - '0';
                    if (i + 1 < template.len and std.ascii.isDigit(template[i + 1])) {
                        n = n * 10 + (template[i + 1] - '0');
                        i += 1;
                    }
                    if (self.group(n)) |g| try out.appendSlice(a, g);
                },
                'g' => {
                    if (i + 1 < template.len and template[i + 1] == '<') {
                        const close = std.mem.indexOfScalarPos(u8, template, i + 2, '>') orelse {
                            try out.appendSlice(a, "\\g");
                            continue;
                        };
                        const name = template[i + 2 .. close];
                        const idx = std.fmt.parseInt(u16, name, 10) catch re.groupIndex(name);
                        if (idx) |gi| if (self.group(gi)) |g| try out.appendSlice(a, g);
                        i = close;
                    } else try out.appendSlice(a, "\\g");
                },
                'n' => try out.append(a, '\n'),
                't' => try out.append(a, '\t'),
                'r' => try out.append(a, '\r'),
                'f' => try out.append(a, 0x0c),
                'v' => try out.append(a, 0x0b),
                'a' => try out.append(a, 0x07),
                'b' => try out.append(a, 0x08),
                '\\' => try out.append(a, '\\'),
                else => {
                    // Unknown escapes of ASCII letters are errors in Python;
                    // keep them verbatim instead.
                    try out.append(a, '\\');
                    try out.append(a, e);
                },
            }
        }
    }
};

/// Iterates over non-overlapping matches with Python's empty-match rules
pub const Iterator = struct {
    re: *const Regex,
    input: []const u8,
    pos: usize = 0,
    /// end of the previous match, if it was empty
    last_empty_at: ?usize = null,
    done: bool = false,

    pub fn next(self: *Iterator) ?Match {
        if (self.done) return null;
        var i = self.pos;
        while (i <= self.input.len) : (i += 1) {
            if (self.re.matchAt(self.input, i)) |m| {
                if (m.end(0) == m.start(0) and self.last_empty_at != null and self.last_empty_at.? == i) {
                    // An empty match is not allowed right where the previous
                    // empty match was; try for a non-empty one first.
                    continue;
                }
                if (m.end(0) == m.start(0)) {
                    self.last_empty_at = m.end(0);
                    self.pos = m.end(0);
                } else {
                    self.last_empty_at = null;
                    self.pos = m.end(0);
                    // Python allows an empty match immediately after a
                    // non-empty match.
                }
                return m;
            }
        }
        self.done = true;
        return null;
    }
};

// --------------------------------------------------------------------------
// Parser

const Parser = struct {
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

    fn parseAlt(p: *Parser) CompileError!*Node {
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

fn escapeChar(e: u8) u8 {
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

fn addShorthand(cls: *Class, e: u8) void {
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

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

// --------------------------------------------------------------------------
// Compiler

const Compiler = struct {
    a: Allocator,
    ignore_case: bool,
    progs: std.ArrayList([]const Inst) = .empty,
    nloop: u16 = 0,

    fn pc(code: *std.ArrayList(Inst)) u32 {
        return @intCast(code.items.len);
    }

    fn emit(c: *Compiler, code: *std.ArrayList(Inst), node: *const Node) CompileError!void {
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

/// Escape regex metacharacters (Python `re.escape`)
pub fn escape(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80)) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

// --------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectMatch(pat: []const u8, flags: Flags, input: []const u8, expected: ?[]const u8) !void {
    var re = try Regex.compile(testing.allocator, pat, flags);
    defer re.deinit();
    const m = re.match(input);
    if (expected) |e| {
        try testing.expect(m != null);
        try testing.expectEqualStrings(e, m.?.str());
    } else {
        try testing.expect(m == null);
    }
}

test "basic matching" {
    try expectMatch("abc", .{}, "abcd", "abc");
    try expectMatch("abc", .{}, "xabc", null);
    try expectMatch("a.c", .{}, "abc", "abc");
    try expectMatch("[ ]*USE", I, "   use foo", "   use");
    try expectMatch("a*", .{}, "aaab", "aaa");
    try expectMatch("a*?b", .{}, "aaab", "aaab");
    try expectMatch("a{2,3}", .{}, "aaaa", "aaa");
    try expectMatch("a{2}", .{}, "aaaa", "aa");
    try expectMatch("x{,2}", .{}, "xxx", "xx");
    try expectMatch("(a|ab)c", .{}, "abc", "abc");
    try expectMatch("[^a-c]+", .{}, "xyzab", "xyz");
    try expectMatch("\\w+", .{}, "foo_1 bar", "foo_1");
    try expectMatch("[\\w\\$]*", .{}, "a$b c", "a$b");
}

test "groups and lookaround" {
    var re = try Regex.compile(testing.allocator, "[ ]*(ABSTRACT)?[ ]*INTERFACE[ ]*(\\w*)", I);
    defer re.deinit();
    const m = re.match("  interface foo").?;
    try testing.expect(m.group(1) == null);
    try testing.expectEqualStrings("foo", m.group(2).?);

    try expectMatch("foo(?!bar)", .{}, "foobar", null);
    try expectMatch("foo(?!bar)", .{}, "foobaz", "foo");
    try expectMatch("(?<=a)b", .{}, "b", null);

    var re2 = try Regex.compile(testing.allocator, "(?<=a)b", .{});
    defer re2.deinit();
    try testing.expect(re2.search("ab") != null);
    try testing.expect(re2.search("cb") == null);

    var re3 = try Regex.compile(testing.allocator, "[ ]*IMPORT(?:[ ]*,[ ]*(?P<spec>ALL|NONE))?", I);
    defer re3.deinit();
    const m3 = re3.match("import, none").?;
    try testing.expectEqualStrings("none", m3.named(&re3, "spec").?);
}

test "word boundary and anchors" {
    var re = try Regex.compile(testing.allocator, "\\bfoo\\b", .{});
    defer re.deinit();
    try testing.expect(re.search("a foo b") != null);
    try testing.expect(re.search("afoo b") == null);
    try expectMatch("CONTAINS[ ]*$", I, "contains  ", "contains  ");
    try expectMatch("CONTAINS[ ]*$", I, "contains x", null);
}

test "sub, split, findall" {
    const a = testing.allocator;
    var re = try Regex.compile(a, "\\n|\\r\\n?", .{});
    defer re.deinit();
    const parts = try re.split(a, "a\nb\r\nc\rd");
    defer a.free(parts);
    try testing.expectEqual(@as(usize, 4), parts.len);
    try testing.expectEqualStrings("d", parts[3]);

    var re2 = try Regex.compile(a, "(\\w+)=(\\w+)", .{});
    defer re2.deinit();
    const out = try re2.sub(a, "\\2=\\1", "a=b, c=d");
    defer a.free(out);
    try testing.expectEqualStrings("b=a, d=c", out);

    var re3 = try Regex.compile(a, "x*", .{});
    defer re3.deinit();
    const out3 = try re3.sub(a, "-", "abxd");
    defer a.free(out3);
    try testing.expectEqualStrings("-a-b--d-", out3);

    var re4 = try Regex.compile(a, "[ ]*(?!<[,\\()][ ]*)\\b(PURE|IMPURE|ELEMENTAL|RECURSIVE)\\b(?![,\\)][ ]*)", I);
    defer re4.deinit();
    const found = try re4.findall(a, "pure elemental function foo(x)");
    defer a.free(found);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("elemental", found[1]);
}

test "nested empty loops terminate" {
    try expectMatch("(a*)*b", .{}, "aab", "aab");
    try expectMatch("(a*)*", .{}, "c", "");
}
