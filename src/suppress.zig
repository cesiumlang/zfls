//! Comments that hide diagnostics:
//!
//! - `! zfls: disable=code, code` hides those codes on its own line,
//!   `! zfls: disable` every code
//! - `! zfls: disable-next-line[=codes]` the same on the next line
//! - `! zfls: disable-file[=codes]` the same in the whole file
//!
//! Codes are the names of `C.DiagCode` (`masks-parent`); unknown names are
//! ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const C = @import("constants.zig");
const FortranFile = @import("parser.zig").FortranFile;

/// What a comment hides: every code, or those in `codes`
const Rule = struct {
    all: bool = false,
    codes: std.EnumSet(C.DiagCode) = .empty,

    fn merge(self: *Rule, other: Rule) void {
        self.all = self.all or other.all;
        self.codes.setUnion(other.codes);
    }

    fn hides(self: Rule, code: C.DiagCode) bool {
        return self.all or self.codes.contains(code);
    }
};

pub const Suppressions = struct {
    file: Rule = .{},
    /// by 0-based line
    lines: std.AutoHashMapUnmanaged(usize, Rule) = .empty,

    /// Whether a diagnostic of `code` starting on 0-based `line` is hidden
    pub fn hides(self: *const Suppressions, code: C.DiagCode, line: usize) bool {
        if (self.file.hides(code)) return true;
        const r = self.lines.get(line) orelse return false;
        return r.hides(code);
    }

    fn add(self: *Suppressions, a: Allocator, line: usize, rule: Rule) !void {
        const gop = try self.lines.getOrPut(a, line);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.merge(rule);
    }
};

const Scope = enum { line, next_line, file };

/// The suppression comments of a file
pub fn of(a: Allocator, file: *const FortranFile) !Suppressions {
    var out: Suppressions = .{};
    for (0..file.nLines()) |ln| {
        const raw = file.getLine(ln, false) orelse continue;
        // cheap test first: most lines have no such comment
        if (std.ascii.findIgnoreCase(raw, "zfls:") == null) continue;
        const comment = try commentOf(a, file.fixed, raw) orelse continue;
        const at = std.ascii.findIgnoreCase(comment, "zfls:") orelse continue;
        const parsed = parse(comment[at + "zfls:".len ..]) orelse continue;
        switch (parsed.scope) {
            .line => try out.add(a, ln, parsed.rule),
            .next_line => try out.add(a, ln + 1, parsed.rule),
            .file => out.file.merge(parsed.rule),
        }
    }
    return out;
}

/// The comment of a line, without its `!`
fn commentOf(a: Allocator, fixed: bool, raw: []const u8) !?[]const u8 {
    if (helpers.isComment(fixed, raw)) return raw;
    const code = try helpers.stripStrings(a, raw, true);
    const i = std.mem.indexOfScalar(u8, code, '!') orelse return null;
    return raw[i + 1 ..];
}

/// ` disable-next-line = a, b` after `zfls:`
fn parse(text: []const u8) ?struct { scope: Scope, rule: Rule } {
    var rest = std.mem.trimStart(u8, text, " \t");
    var n: usize = 0;
    while (n < rest.len and (std.ascii.isAlphabetic(rest[n]) or rest[n] == '-')) n += 1;
    const word = rest[0..n];
    const scope: Scope = if (std.ascii.eqlIgnoreCase(word, "disable"))
        .line
    else if (std.ascii.eqlIgnoreCase(word, "disable-next-line"))
        .next_line
    else if (std.ascii.eqlIgnoreCase(word, "disable-file"))
        .file
    else
        return null;
    rest = std.mem.trimStart(u8, rest[n..], " \t");
    if (rest.len == 0 or rest[0] != '=') return .{ .scope = scope, .rule = .{ .all = true } };
    var rule: Rule = .{};
    var it = std.mem.tokenizeAny(u8, rest[1..], ", \t");
    while (it.next()) |name| {
        if (C.DiagCode.fromName(name)) |c| rule.codes.insert(c);
    }
    return .{ .scope = scope, .rule = rule };
}

test "suppression comments" {
    const r = parse(" disable-next-line = masks-parent, nonsense").?;
    try std.testing.expectEqual(Scope.next_line, r.scope);
    try std.testing.expect(r.rule.hides(.masks_parent));
    try std.testing.expect(!r.rule.hides(.declared_twice));
    const all = parse("disable").?;
    try std.testing.expect(all.rule.hides(.declared_twice));
    try std.testing.expect(parse(" enable") == null);
}
