//! OpenMP (`!$omp`) and OpenACC (`!$acc`) directives: the variables of
//! their clauses, the completion of their directive and clause names.

const std = @import("std");
const h = @import("harness.zig");

const loops =
    \\subroutine s(a, n, total)
    \\  implicit none
    \\  integer, intent(in) :: n
    \\  real, intent(in) :: a(n)
    \\  real, intent(out) :: total
    \\  integer :: i
    \\  total = 0
    \\  !$omp parallel do reduction(+:total)
    \\  do i = 1, n
    \\    total = total + a(i)
    \\  end do
    \\  !$acc parallel loop copyin(a) reduction(+:total)
    \\  do i = 1, n
    \\    total = total + a(i)
    \\  end do
    \\end subroutine
    \\
;

test "the variables of OpenACC clauses: hover, definition, references and rename, as of OpenMP's (#725)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = loops }}, .{});
    defer w.deinit();
    const acc_a = w.pos("t.f90", "a) reduction", 0, 0);
    try w.expectHoverContains("t.f90", acc_a, "REAL, INTENT(IN), DIMENSION(n) :: a");
    const acc_total = w.pos("t.f90", "total)\n  do", 1, 0);
    try w.expectHoverContains("t.f90", acc_total, "REAL, INTENT(OUT) :: total");
    const def = (try w.definition("t.f90", acc_total)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 4), def.line);
    // the declaration, the assignment, both directives and the two loops
    const refs = try w.references("t.f90", w.pos("t.f90", "total = 0", 0, 0));
    var on_acc = false;
    for (refs) |r| on_acc = on_acc or r.line == 11;
    try h.expect(on_acc, "references: {any}", .{refs});
    try std.testing.expectEqual(@as(usize, 9), refs.len);
    const edits = try w.rename("t.f90", w.pos("t.f90", "total = 0", 0, 0), "sum");
    on_acc = false;
    for (edits) |e| on_acc = on_acc or e.line == 11;
    try h.expect(on_acc, "rename edits: {any}", .{edits});
    try w.expectNoDiagnostics("t.f90");
}

fn labels(w: *h.Workspace, name: []const u8, needle: []const u8, plus: usize) ![]const []const u8 {
    return w.completion(name, w.pos(name, needle, 0, plus));
}

fn has(items: []const []const u8, label: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i, label)) return true;
    return false;
}

test "completion of OpenMP and OpenACC directive and clause names (#742)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "t.f90", .text = "subroutine s(x, n)\n" ++
            "  integer :: n, i\n" ++
            "  real :: x(n), private_x\n" ++
            "  !$omp parallel do priv\n" ++
            "  !$omp tar\n" ++
            "  !$acc kernels cop\n" ++
            "  !$OMP PARALLEL DO &\n" ++
            "  !$OMP& FIRST\n" ++
            "  !$omp parallel do private(priv\n" ++
            "end subroutine\n" },
        .{ .name = "f.f", .text = "      subroutine f(x)\n" ++
            "      real x\n" ++
            "c$omp parallel sha\n" ++
            "c$omp+ red\n" ++
            "      end\n" },
    }, .{});
    defer w.deinit();
    // a clause after the directive
    var items = try labels(w, "t.f90", "priv\n", 4);
    try h.expect(has(items, "private") and !has(items, "private_x"), "priv: {any}", .{items});
    // a directive after the sentinel, not a clause
    items = try labels(w, "t.f90", "tar\n", 3);
    try h.expect(has(items, "target") and !has(items, "taskwait"), "tar: {any}", .{items});
    items = try labels(w, "t.f90", "cop\n", 3);
    try h.expect(has(items, "copy") and has(items, "copyin") and has(items, "copyout"), "cop: {any}", .{items});
    // the case of the sentinel, on a continuation line
    items = try labels(w, "t.f90", "FIRST\n", 5);
    try h.expect(has(items, "FIRSTPRIVATE"), "FIRST: {any}", .{items});
    // in a clause's parentheses, the names of the scope
    items = try labels(w, "t.f90", "private(priv\n", 12);
    try h.expect(has(items, "private_x") and !has(items, "private"), "private(priv: {any}", .{items});
    // fixed form
    items = try labels(w, "f.f", "sha\n", 3);
    try h.expect(has(items, "shared"), "sha: {any}", .{items});
    items = try labels(w, "f.f", "red\n", 3);
    try h.expect(has(items, "reduction"), "red: {any}", .{items});
}

fn tokenOn(toks: []const h.Token, line: i64, text: []const u8) ?[]const u8 {
    for (toks) |t| if (t.line == line and std.mem.eql(u8, t.text, text)) return t.type;
    return null;
}

test "the variables of OpenMP and OpenACC clauses are semantic tokens, their keywords are not (#725)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "t.f90", .text = loops },
        .{ .name = "c.f90", .text = "subroutine c(x, y)\n  real :: x(10), y(10)\n  integer :: i\n  !$omp parallel do private(i) &\n  !$omp& shared(x, y)\n  do i = 1, 10\n    x(i) = y(i)\n  end do\nend subroutine\n" },
        .{ .name = "f.f", .text = "      subroutine f(x)\n      real x(10)\nc$omp parallel do shared(x)\n      do 10 i = 1, 10\n        x(i) = 0\n   10 continue\n      end\n" },
    }, .{});
    defer w.deinit();
    var toks = try w.semanticTokens("t.f90");
    const omp = w.pos("t.f90", "total)\n  do", 0, 0).line;
    try h.expect(std.mem.eql(u8, tokenOn(toks, omp, "total") orelse "", "parameter"), "omp total: {any}", .{toks});
    const acc = w.pos("t.f90", "total)\n  do", 1, 0).line;
    try h.expect(std.mem.eql(u8, tokenOn(toks, acc, "total") orelse "", "parameter"), "acc total: {any}", .{toks});
    try h.expect(std.mem.eql(u8, tokenOn(toks, acc, "a") orelse "", "parameter"), "acc a: {any}", .{toks});
    // the directive's words and clauses' names are none
    for ([_][]const u8{ "parallel", "loop", "reduction", "copyin" }) |word| {
        try h.expect(tokenOn(toks, acc, word) == null and tokenOn(toks, omp, word) == null, "{s} is a token", .{word});
    }
    // a clause that goes on after a continuation
    toks = try w.semanticTokens("c.f90");
    try h.expect(std.mem.eql(u8, tokenOn(toks, 3, "i") orelse "", "variable"), "private(i): {any}", .{toks});
    try h.expect(std.mem.eql(u8, tokenOn(toks, 4, "x") orelse "", "parameter"), "shared(x: {any}", .{toks});
    try h.expect(std.mem.eql(u8, tokenOn(toks, 4, "y") orelse "", "parameter"), "y): {any}", .{toks});
    // fixed form
    toks = try w.semanticTokens("f.f");
    try h.expect(std.mem.eql(u8, tokenOn(toks, 2, "x") orelse "", "parameter"), "c$omp shared(x): {any}", .{toks});
    try h.expect(tokenOn(toks, 2, "parallel") == null and tokenOn(toks, 2, "shared") == null, "words: {any}", .{toks});
}
