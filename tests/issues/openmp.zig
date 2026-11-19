//! OpenMP conditional compilation lines (#276): `!$ x = 1` (in fixed form
//! also `c$` and `*$` in column 1) is code when the file is compiled with
//! OpenMP, and zfls reads it as code.

const std = @import("std");
const h = @import("harness.zig");

const free = [_]h.File{.{ .name = "o.f90", .text =
    \\program o
    \\   !$ use omp_lib
    \\   implicit none
    \\   integer :: nthreads
    \\   nthreads = 4
    \\   !$ call omp_set_num_threads(nthreads)
    \\   !$ nthreads = omp_get_max_threads()
    \\   print *, nthreads
    \\end program o
    \\
}};

const fixed = [_]h.File{.{ .name = "o.f", .text =
    \\      program o
    \\      implicit none
    \\      integer n
    \\      n = 4
    \\c$    n = 8
    \\*$    n = 16
    \\      print *, n
    \\      end
    \\
}};

/// The lines (0-based) of the references, in order
fn refLines(w: *h.Workspace, name: []const u8, p: h.Pos) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (try w.references(name, p)) |l| try out.append(std.heap.page_allocator, l.line);
    std.mem.sort(i64, out.items, {}, std.sort.asc(i64));
    return out.items;
}

fn expectLines(got: []const i64, want: []const i64) !void {
    try h.expect(std.mem.eql(i64, got, want), "references in lines {any}, expected {any}", .{ got, want });
}

fn expectFree(w: *h.Workspace) !void {
    const call = w.pos("o.f90", "nthreads)", 0, 0);
    const hover = (try w.hover("o.f90", call)) orelse return h.unmet("no hover on nthreads in a !$ line", .{});
    try h.expect(std.mem.find(u8, hover, "INTEGER :: nthreads") != null, "hover on nthreads: {s}", .{hover});
    if ((try w.hover("o.f90", w.pos("o.f90", "omp_set_num_threads", 0, 0))) == null) return h.unmet("no hover on omp_set_num_threads", .{});
    try expectLines(try refLines(w, "o.f90", w.pos("o.f90", "nthreads", 0, 0)), &.{ 3, 4, 5, 6, 7 });
    // the USE in a !$ line makes the OpenMP library's names known
    if ((try w.hover("o.f90", w.pos("o.f90", "omp_get_max_threads", 0, 0))) == null) return h.unmet("omp_get_max_threads does not resolve", .{});
}

test "Modern Fortran #17 OpenMP conditional compilation lines are code (#276)" {
    const w = try h.Workspace.init(&free, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 17, .fixed, expectFree(w));
}

test "fixed form: c$ and *$ lines are code (#276)" {
    const w = try h.Workspace.init(&fixed, .{});
    defer w.deinit();
    try expectLines(try refLines(w, "o.f", w.pos("o.f", "n = 4", 0, 0)), &.{ 2, 3, 4, 5, 6 });
}

test "rename edits the !$ lines (#276)" {
    const w = try h.Workspace.init(&free, .{});
    defer w.deinit();
    const edits = try w.rename("o.f90", w.pos("o.f90", "nthreads", 0, 0), "nt");
    var lines: std.ArrayList(i64) = .empty;
    for (edits) |e| {
        try std.testing.expectEqualStrings("nt", e.new_text);
        try lines.append(std.heap.page_allocator, e.line);
    }
    std.mem.sort(i64, lines.items, {}, std.sort.asc(i64));
    try std.testing.expectEqualSlices(i64, &.{ 3, 4, 5, 6, 7 }, lines.items);
}

test "a variable used only in !$ lines is used; one declared in a !$ line is declared (#276)" {
    const files = [_]h.File{.{ .name = "u.f90", .text =
        \\subroutine s()
        \\   !$ use omp_lib
        \\   implicit none
        \\   integer :: tid
        \\   !$ integer :: nt
        \\   !$ tid = omp_get_thread_num()
        \\   !$ nt = tid
        \\   !$ print *, nt
        \\end subroutine s
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("u.f90", "fortran");
    // no unused-name hint either
    const ds = try w.diagnostics("u.f90");
    for (ds) |d| std.debug.print("unexpected diagnostic in line {d}: {s}\n", .{ d.line, d.message });
    try std.testing.expectEqual(@as(usize, 0), ds.len);
}

test "OpenMP directives and comments that look like a sentinel stay comments (#276)" {
    const files = [_]h.File{.{ .name = "d.f90", .text =
        \\program d
        \\   implicit none
        \\   integer :: i, total
        \\   total = 0
        \\   !$omp parallel do reduction(+:total)
        \\   do i = 1, 10
        \\      total = total + i
        \\   end do
        \\   !$omp end parallel do
        \\   !$this is text about total
        \\   print *, total
        \\end program d
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("d.f90", "fortran");
    try w.expectNoDiagnostics("d.f90");
    // the names of the directive's clauses are found as before; the text
    // line is no code
    try expectLines(try refLines(w, "d.f90", w.pos("d.f90", "total = 0", 0, 0)), &.{ 2, 3, 4, 6, 6, 10 });
    // hover on the directive's keywords is as without the feature
    if ((try w.hover("d.f90", w.pos("d.f90", "parallel do", 0, 0))) == null) return error.NoDirectiveHover;
}

test "a !$ line continued with !$ & (#276)" {
    const files = [_]h.File{.{ .name = "c.f90", .text =
        \\program c
        \\   implicit none
        \\   integer :: a, b
        \\   a = 1
        \\   b = 2
        \\   !$ call sub(a, &
        \\   !$ & b)
        \\contains
        \\   subroutine sub(x, y)
        \\      integer, intent(in) :: x, y
        \\      print *, x, y
        \\   end subroutine sub
        \\end program c
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try expectLines(try refLines(w, "c.f90", w.pos("c.f90", "b = 2", 0, 0)), &.{ 2, 4, 6 });
    const def = (try w.definition("c.f90", w.pos("c.f90", "sub(a", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 8), def.line);
}

test "with disable_openmp_conditional, !$ lines are comments (#276)" {
    const w = try h.Workspace.init(&free, .{ .settings = .{ .disable_openmp_conditional = true } });
    defer w.deinit();
    try std.testing.expect((try w.hover("o.f90", w.pos("o.f90", "nthreads)", 0, 0))) == null);
    try expectLines(try refLines(w, "o.f90", w.pos("o.f90", "nthreads", 0, 0)), &.{ 3, 4, 7 });
}

test "an edit that makes a !$ line a comment, and one that undoes it (#276)" {
    const w = try h.Workspace.init(&free, .{});
    defer w.deinit();
    try w.open("o.f90", "fortran");
    const before = free[0].text;
    const i = std.mem.find(u8, before, "!$ call").?;
    const changed = try std.mem.concat(std.testing.allocator, u8, &.{ before[0 .. i + 2], before[i + 3 ..] });
    defer std.testing.allocator.free(changed);
    try w.replaceText("o.f90", changed);
    try expectLines(try refLines(w, "o.f90", w.pos("o.f90", "nthreads", 0, 0)), &.{ 3, 4, 6, 7 });
    try w.replaceText("o.f90", before);
    try expectLines(try refLines(w, "o.f90", w.pos("o.f90", "nthreads", 0, 0)), &.{ 3, 4, 5, 6, 7 });
}
