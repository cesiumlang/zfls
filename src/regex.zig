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

// The pattern parser and compiler, in regex/
const regex_compile = @import("regex/compile.zig");
const Parser = regex_compile.Parser;
const Compiler = regex_compile.Compiler;

pub const Flags = packed struct {
    ignore_case: bool = false,
};

pub const I: Flags = .{ .ignore_case = true };

pub const CompileError = error{ InvalidPattern, OutOfMemory };

/// Maximum number of capture groups (including group 0).
pub const max_groups = 48;
const max_slots = max_groups * 2;
/// Extra registers used to detect zero-width iterations of `*` loops.
pub const max_loop_regs = 32;

const AssertKind = enum { bol, eol, start, end, word_boundary, not_word_boundary };

pub const Inst = union(enum) {
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

pub const Class = std.bit_set.Static(256);

pub const Node = union(enum) {
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
    /// Bytes a match can start with; null when it can be empty (or the
    /// pattern is too complex to tell)
    prefilter: ?Prefilter,

    /// A cheap test that rejects most inputs before the VM starts
    const Prefilter = struct {
        /// Bytes that can start a match
        first: Class,
        /// The pattern starts with `[ ]*` and no other way to match starts
        /// with a space: skip the spaces, then test `after_spaces`
        skip_spaces: bool,
        after_spaces: Class,
    };

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
        const prefilter = computePrefilter(root, p.classes.items, p.ignore_case);
        return .{
            .arena = arena,
            .progs = c.progs.items,
            .classes = p.classes.items,
            .ngroups = p.ngroups,
            .names = p.names.items,
            .ignore_case = p.ignore_case,
            .nloop_regs = c.nloop,
            .prefilter = prefilter,
        };
    }

    /// The set of bytes a match of `node` can start with, added to `out`.
    /// Returns whether `node` can match without consuming input, or null when
    /// that cannot be told (back references). Zero-width assertions only
    /// constrain a match, so ignoring them keeps the set a superset.
    fn firstBytes(node: *const Node, classes: []const Class, ignore_case: bool, out: *Class) ?bool {
        switch (node.*) {
            .empty, .assert, .look => return true,
            .char => |c| {
                out.set(c);
                if (ignore_case) out.set(std.ascii.toUpper(c));
                return false;
            },
            .any_nonl => {
                var all = Class.full;
                all.unset('\n');
                out.setUnion(all);
                return false;
            },
            .class => |ci| {
                out.setUnion(classes[ci]);
                return false;
            },
            .backref => return null,
            .group => |g| return firstBytes(g.child, classes, ignore_case, out),
            .concat => |items| {
                for (items) |item| {
                    if (!(firstBytes(item, classes, ignore_case, out) orelse return null)) return false;
                }
                return true;
            },
            .alt => |branches| {
                var nullable = false;
                for (branches) |br| {
                    if (firstBytes(br, classes, ignore_case, out) orelse return null) nullable = true;
                }
                return nullable;
            },
            .repeat => |r| {
                const child_nullable = firstBytes(r.child, classes, ignore_case, out) orelse return null;
                return child_nullable or r.min == 0;
            },
        }
    }

    /// Whether `node` is `[ ]*` (greedy, any number of spaces)
    fn isSpaces(node: *const Node, classes: []const Class) bool {
        const r = switch (node.*) {
            .repeat => |r| r,
            else => return false,
        };
        if (r.min != 0 or r.max != null or !r.greedy) return false;
        return switch (r.child.*) {
            .char => |c| c == ' ',
            .class => |ci| classes[ci].count() == 1 and classes[ci].isSet(' '),
            else => false,
        };
    }

    fn computePrefilter(root: *const Node, classes: []const Class, ignore_case: bool) ?Prefilter {
        var first = Class.empty;
        const nullable = firstBytes(root, classes, ignore_case, &first) orelse return null;
        if (nullable) return null;
        var pf: Prefilter = .{ .first = first, .skip_spaces = false, .after_spaces = first };
        switch (root.*) {
            .concat => |items| if (items.len > 1 and isSpaces(items[0], classes)) {
                var rest = Class.empty;
                var rest_nullable = false;
                for (items[1..]) |item| {
                    const n = firstBytes(item, classes, ignore_case, &rest) orelse return pf;
                    if (!n) break;
                } else rest_nullable = true;
                if (!rest_nullable and !rest.isSet(' ')) {
                    pf.skip_spaces = true;
                    pf.after_spaces = rest;
                }
            },
            else => {},
        }
        return pf;
    }

    /// Whether the prefilter rules out a match starting at `pos`
    fn rejects(self: *const Regex, input: []const u8, pos: usize) bool {
        const pf = self.prefilter orelse return false;
        var p = pos;
        if (pf.skip_spaces) {
            while (p < input.len and input[p] == ' ') p += 1;
            return p >= input.len or !pf.after_spaces.isSet(input[p]);
        }
        return p >= input.len or !pf.first.isSet(input[p]);
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
        if (self.rejects(input, pos)) return null;
        return self.matchAtUnfiltered(input, pos);
    }

    /// `matchAt` without the prefilter, for comparing against it in tests
    pub fn matchAtUnfiltered(self: *const Regex, input: []const u8, pos: usize) ?Match {
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
            // only positions where a match can start
            if (self.prefilter) |pf| {
                while (i < input.len and !pf.first.isSet(input[i])) i += 1;
                if (i >= input.len) return null;
            }
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
        // only what this pattern uses: clearing all of them took much of a
        // search, which runs this at every position
        @memset(regs[0..self.nloop_regs], std.math.maxInt(usize));
        if (!is_sub) @memset(slots[0 .. @as(usize, self.ngroups) * 2], null);

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
        if (g >= self.ngroups) return std.math.maxInt(usize);
        return self.slots[g * 2] orelse std.math.maxInt(usize);
    }

    pub fn end(self: Match, g: u16) usize {
        if (g >= self.ngroups) return std.math.maxInt(usize);
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

// --------------------------------------------------------------------------
// Compiler

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
