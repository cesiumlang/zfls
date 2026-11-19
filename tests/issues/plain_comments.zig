//! `hover_plain_comments` (#263): plain `!` comments as the documentation
//! of a declaration that has no `!>`, `!<` or `!!` documentation.

const std = @import("std");
const h = @import("harness.zig");

const source = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\   implicit none
    \\contains
    \\   !> Doxygen comment
    \\   subroutine dox()
    \\   end subroutine
    \\
    \\   ! Plain comment above plain,
    \\   ! second line
    \\   subroutine plain()
    \\      real :: b ! the matrix to transpose
    \\      real :: c !< doc of c
    \\      b = 1; c = b
    \\   end subroutine
    \\
    \\   ! plain, but !> and !! win
    \\   !> the doxygen text
    \\   subroutine both(x)
    \\      !! and this too
    \\      integer, intent(in) :: x ! the argument
    \\   end subroutine
    \\
    \\   ! a section title, then a blank line
    \\
    \\   subroutine sep()
    \\   end subroutine
    \\
    \\   !------------------------------
    \\   !$omp declare simd(ruled)
    \\   subroutine ruled()
    \\      ! under the header
    \\      ! of ruled
    \\      integer :: k
    \\      k = 1 ! not a declaration
    \\   end subroutine
    \\end module
    \\program p
    \\   use m
    \\   call both(1)
    \\end program
    \\
}};

fn hoverOf(w: *h.Workspace, needle: []const u8, plus: usize) ![]const u8 {
    return (try w.hover("m.f90", w.pos("m.f90", needle, 0, plus))) orelse error.NoHover;
}

fn position(p: h.Pos) struct { line: i64, character: i64 } {
    return .{ .line = p.line, .character = p.col };
}

fn expectHover(w: *h.Workspace, needle: []const u8, plus: usize, want: []const u8) !void {
    try std.testing.expectEqualStrings(want, try hoverOf(w, needle, plus));
}

test "with hover_plain_comments, a plain comment block above or after a declaration documents it (#263)" {
    const w = try h.Workspace.init(&source, .{ .settings = .{ .hover_plain_comments = true } });
    defer w.deinit();
    try expectHover(w, "subroutine dox", 11, "```fortran90\nSUBROUTINE dox()\n```\n-----\nDoxygen comment");
    try expectHover(w, "subroutine plain", 11, "```fortran90\nSUBROUTINE plain()\n```\n-----\nPlain comment above plain,\nsecond line\n");
    try expectHover(w, "real :: b", 8, "```fortran90\nREAL :: b\n```\n-----\nthe matrix to transpose");
    try expectHover(w, "real :: c", 8, "```fortran90\nREAL :: c\n```\n-----\ndoc of c");
    // !> and !! win over plain comments
    const both = try hoverOf(w, "subroutine both", 11);
    try std.testing.expect(std.mem.find(u8, both, "and this too") != null);
    try std.testing.expect(std.mem.find(u8, both, "win") == null);
    // a blank line, a ruler and a directive are no documentation
    try expectHover(w, "subroutine sep", 11, "```fortran90\nSUBROUTINE sep()\n```");
    // a block right under a procedure's header documents the procedure
    try expectHover(w, "subroutine ruled", 11, "```fortran90\nSUBROUTINE ruled()\n```\n-----\nunder the header\nof ruled\n");
    try expectHover(w, "integer :: k", 11, "```fortran90\nINTEGER :: k\n```");
}

test "without hover_plain_comments, plain comments are no documentation (#263)" {
    const w = try h.Workspace.init(&source, .{});
    defer w.deinit();
    try expectHover(w, "subroutine plain", 11, "```fortran90\nSUBROUTINE plain()\n```");
    try expectHover(w, "real :: b", 8, "```fortran90\nREAL :: b\n```");
    try expectHover(w, "real :: c", 8, "```fortran90\nREAL :: c\n```\n-----\ndoc of c");
}

test "plain comments document in completion and signature help as in hover (#263)" {
    const w = try h.Workspace.init(&source, .{ .settings = .{ .hover_plain_comments = true, .use_signature_help = true } });
    defer w.deinit();
    const a = std.testing.allocator;
    const comp = try w.zflsRequest("textDocument/completion", .{
        .textDocument = .{ .uri = try w.uri("m.f90") },
        .position = position(w.pos("m.f90", "b = 1", 0, 1)),
    });
    const comp_text = try h.json.stringify(a, comp);
    defer a.free(comp_text);
    try std.testing.expect(std.mem.find(u8, comp_text, "the matrix to transpose") != null);
    const sig = try w.zflsRequest("textDocument/signatureHelp", .{
        .textDocument = .{ .uri = try w.uri("m.f90") },
        .position = position(w.pos("m.f90", "call both(1", 0, 10)),
    });
    const sig_text = try h.json.stringify(a, sig);
    defer a.free(sig_text);
    try std.testing.expect(std.mem.find(u8, sig_text, "the argument") != null);
}

test "fixed form: C and * comment lines above a subroutine document it (#263)" {
    const files = [_]h.File{.{ .name = "f.f", .text =
        \\C     Scales a vector
        \\*     by a constant
        \\      SUBROUTINE SSCAL(N, A)
        \\      INTEGER N
        \\      REAL A
        \\      END
        \\
    }};
    const w = try h.Workspace.init(&files, .{ .settings = .{ .hover_plain_comments = true } });
    defer w.deinit();
    const got = (try w.hover("f.f", w.pos("f.f", "SSCAL", 0, 1))) orelse return error.NoHover;
    try std.testing.expect(std.mem.endsWith(u8, got, "\n-----\nScales a vector\nby a constant\n"));
}

test "turning hover_plain_comments on from the editor parses the files again (#263)" {
    const w = try h.Workspace.init(&source, .{});
    defer w.deinit();
    try expectHover(w, "real :: b", 8, "```fortran90\nREAL :: b\n```");
    try w.changeConfiguration("{\"hover_plain_comments\": true}");
    try expectHover(w, "real :: b", 8, "```fortran90\nREAL :: b\n```\n-----\nthe matrix to transpose");
}
