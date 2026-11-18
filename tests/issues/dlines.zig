//! Fixed-form debug lines, D or d in column 1 (#260): comments by default,
//! code with `d_lines` set to `code`.

const std = @import("std");
const h = @import("harness.zig");

const debug_lines = [_]h.File{
    .{ .name = "a.f", .text =
    \\      PROGRAM P
    \\      IMPLICIT NONE
    \\      INTEGER I
    \\      I = 1
    \\D     PRINT *, 'debug', I
    \\d     I = J
    \\      END
    \\
    },
    // free form: a line that starts with d is code
    .{ .name = "b.f90", .text =
    \\program q
    \\  integer :: d
    \\d = 1
    \\end program q
    \\
    },
};

/// The 0-based lines of the references to `I`, from its use on line 4
fn referenceLines(w: *h.Workspace) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (try w.references("a.f", .{ .line = 3, .col = 6 })) |r| try out.append(std.testing.allocator, r.line);
    return out.toOwnedSlice(std.testing.allocator);
}

fn has(lines: []const i64, line: i64) bool {
    return std.mem.findScalar(i64, lines, line) != null;
}

fn expectFreeForm(w: *h.Workspace) !void {
    try w.expectNoDiagnostics("b.f90");
    try w.expectHoverContains("b.f90", w.pos("b.f90", "d = 1", 0, 0), "INTEGER :: d");
}

fn expectComments(w: *h.Workspace) !void {
    // the lines are comments: no names, no diagnostics
    try w.expectNoDiagnostics("a.f");
    try h.expect(try w.hover("a.f", .{ .line = 4, .col = 24 }) == null, "hover on I of a debug line", .{});
    const refs = try referenceLines(w);
    defer std.testing.allocator.free(refs);
    try h.expect(!has(refs, 4) and !has(refs, 5) and has(refs, 3), "references of I on lines {any}", .{refs});
    // a comment token over each, which hides the grammar's colors of code
    var comments: usize = 0;
    for (try w.semanticTokens("a.f")) |t| {
        if ((t.line == 4 or t.line == 5) and std.mem.eql(u8, t.type, "comment") and t.text.len > 0 and t.text[0] != ' ') comments += 1;
    }
    try h.expect(comments == 2, "{d} comment tokens on the debug lines", .{comments});
    try expectFreeForm(w);
}

fn expectCode(w: *h.Workspace) !void {
    try w.expectHoverContains("a.f", .{ .line = 4, .col = 24 }, "INTEGER :: I");
    const refs = try referenceLines(w);
    defer std.testing.allocator.free(refs);
    try h.expect(has(refs, 4) and has(refs, 5), "references of I on lines {any}", .{refs});
    var undeclared = false;
    for (try w.diagnostics("a.f")) |d| undeclared = undeclared or std.mem.find(u8, d.message, "\"J\" is not declared") != null;
    try h.expect(undeclared, "J is not reported as undeclared", .{});
    try expectFreeForm(w);
    // rename reaches them too, and leaves their D
    const edits = try w.rename("a.f", .{ .line = 3, .col = 6 }, "K");
    var on_debug: usize = 0;
    for (edits) |e| {
        if (e.line == 4 or e.line == 5) on_debug += 1;
        try h.expect(e.start > 0, "an edit at column {d}", .{e.start});
    }
    try h.expect(on_debug == 2, "rename changes {d} names on the debug lines", .{on_debug});
}

test "Modern Fortran #253 debug lines are comments by default (#260)" {
    const w = try h.Workspace.init(&debug_lines, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 253, .fixed, expectComments(w));
}

test "Modern Fortran #253 debug lines are code with d_lines set to code (#260)" {
    const w = try h.Workspace.init(&debug_lines, .{ .settings = .{ .d_lines = "code" } });
    defer w.deinit();
    try h.checkIn(.modern_fortran, 253, .fixed, expectCode(w));
}
