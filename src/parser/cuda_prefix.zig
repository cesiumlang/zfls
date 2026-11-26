//! Part of reading definitions (definitions.zig): the CUDA Fortran prefix
//! `attributes(...)` of a procedure statement, first or after other
//! words of its prefix.

const std = @import("std");
const Allocator = std.mem.Allocator;
const definitions = @import("definitions.zig");
const E = definitions.E;
const getFortranDefinition = definitions.getFortranDefinition;

/// A procedure statement after the CUDA Fortran prefix
/// `attributes(global|device|host|grid_global)`: the rest of the line
pub fn afterCudaAttributes(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.ascii.startsWithIgnoreCase(t, "attributes")) return null;
    var rest = std.mem.trimStart(u8, t["attributes".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return null;
    const close = std.mem.findScalar(u8, rest, ')') orelse return null;
    for (rest[1..close]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ',' or c == ' ')) return null;
    rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    if (rest.len == 0 or !std.ascii.isAlphabetic(rest[0])) return null;
    return rest;
}

/// The words of a procedure's prefix that may come before its CUDA
/// Fortran `attributes(...)`, and the types of a function's result
const prefix_words = [_][]const u8{
    "pure",    "impure", "elemental", "recursive",       "non_recursive", "module",   "simple",
    "integer", "real",   "complex",   "logical",         "character",     "double",   "precision",
    "type",    "class",  "byte",      "doubleprecision", "doublecomplex", "unsigned",
};

/// A procedure statement with the CUDA Fortran prefix `attributes(...)`
/// after other words of its prefix (`pure attributes(device) function`):
/// the line with `attributes(...)` blanked, its columns kept
pub fn withoutCudaAttributes(a: Allocator, line: []const u8) E!?[]const u8 {
    var i: usize = 0;
    var words: usize = 0;
    while (words < 8) : (words += 1) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const start = i;
        while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
        const word = line[start..i];
        if (word.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(word, "attributes")) {
            // not the first word: afterCudaAttributes
            if (words == 0) return null;
            const rest = afterCudaAttributes(line[start..]) orelse return null;
            const out = try a.dupe(u8, line);
            @memset(out[start .. line.len - rest.len], ' ');
            return out;
        }
        for (prefix_words) |w| {
            if (std.ascii.eqlIgnoreCase(word, w)) break;
        } else return null;
        // a kind or length (`integer(c_int)`, `real*8`)
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i < line.len and line[i] == '(') {
            var depth: usize = 0;
            while (i < line.len) : (i += 1) {
                if (line[i] == '(') depth += 1;
                if (line[i] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            } else return null;
            i += 1;
        } else if (i < line.len and line[i] == '*') {
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == ' ')) i += 1;
        }
    }
    return null;
}

test "CUDA Fortran's attributes after other words of the prefix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("pure                    function f(x)", (try withoutCudaAttributes(a, "pure attributes(device) function f(x)")).?);
    try std.testing.expectEqualStrings("  integer(c_int)                    pure function g()", (try withoutCudaAttributes(a, "  integer(c_int) attributes(device) pure function g()")).?);
    try std.testing.expect((try withoutCudaAttributes(a, "real*8 attributes(host, device) function h()")) != null);
    // first: afterCudaAttributes; none
    try std.testing.expect(try withoutCudaAttributes(a, "attributes(device) pure function f(x)") == null);
    try std.testing.expect(try withoutCudaAttributes(a, "x = attributes(1)") == null);
    try std.testing.expect(try withoutCudaAttributes(a, "call attributes(device) x") == null);
    try std.testing.expect(try withoutCudaAttributes(a, "pure function attributes(x)") == null);
    const d = (try getFortranDefinition(a, "pure attributes(device) subroutine s(a)")).?;
    try std.testing.expect(d == .sub);
}
