//! zfls's own formatter (#986, `formatter = "zfls"`): free-form files
//! indented by their scopes, every token kept, formatting twice as once.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");
const formatted = @import("harness_format.zig").formatted;

const io = std.testing.io;

const messy = h.File{ .name = "m.F90", .text =
    \\module m
    \\implicit none
    \\type :: point
    \\real :: x
    \\contains
    \\procedure :: show
    \\end type
    \\contains
    \\subroutine show(self)
    \\class(point), intent(in) :: self
    \\integer :: k
    \\       if (self%x > 0) then
    \\k = 1
    \\  else if (self%x < 0) then
    \\k = 2
    \\    else
    \\k = 3
    \\end if
    \\select case (k)
    \\case (1)
    \\print *, 'one', &
    \\'and more'
    \\case default
    \\print *, 'a long &
    \\    literal'
    \\end select
    \\#ifdef DEBUG
    \\    print *, k
    \\#endif
    \\  ! a comment
    \\do k = 1, 2
    \\end do
    \\end subroutine
    \\end module m
    \\
};

const want =
    \\module m
    \\  implicit none
    \\  type :: point
    \\    real :: x
    \\  contains
    \\    procedure :: show
    \\  end type
    \\contains
    \\  subroutine show(self)
    \\    class(point), intent(in) :: self
    \\    integer :: k
    \\    if (self%x > 0) then
    \\      k = 1
    \\    else if (self%x < 0) then
    \\      k = 2
    \\    else
    \\      k = 3
    \\    end if
    \\    select case (k)
    \\    case (1)
    \\      print *, 'one', &
    \\        'and more'
    \\    case default
    \\      print *, 'a long &
    \\    literal'
    \\    end select
    \\#ifdef DEBUG
    \\    print *, k
    \\#endif
    \\    ! a comment
    \\    do k = 1, 2
    \\    end do
    \\  end subroutine
    \\end module m
    \\
;

test "a free-form file indented by its scopes (#986)" {
    const w = try h.Workspace.init(&.{messy}, .{ .init_options = "{\"formatter\": \"zfls\", \"formatter_args\": [\"--indent\", \"2\"]}" });
    defer w.deinit();
    try std.testing.expectEqualStrings(want, try formatted(w, "m.F90"));
}

test "SELECT TYPE and SELECT RANK: a guard's block one level in, as a CASE's (#986)" {
    const w = try h.Workspace.init(&.{.{ .name = "g.f90", .text = "subroutine g(x, r)\nclass(*) :: x\nreal :: r(..)\nselect type (x)\ntype is (integer)\nprint *, x\nclass default\nprint *, 0\nend select\nselect rank (r)\nrank (0)\nprint *, r\nrank default\nprint *, 1\nend select\nend subroutine\n" }}, .{ .init_options = "{\"formatter\": \"zfls\", \"formatter_args\": [\"--indent\", \"2\"]}" });
    defer w.deinit();
    try std.testing.expectEqualStrings(
        "subroutine g(x, r)\n  class(*) :: x\n  real :: r(..)\n  select type (x)\n  type is (integer)\n    print *, x\n  class default\n    print *, 0\n  end select\n  select rank (r)\n  rank (0)\n    print *, r\n  rank default\n    print *, 1\n  end select\nend subroutine\n",
        try formatted(w, "g.f90"),
    );
}

test "a continuation line indented further than its statement keeps that offset (#986)" {
    const w = try h.Workspace.init(&.{.{ .name = "k.f90", .text = "program p\ncall f(a, &\n       b)\nx = 1 + &\n2\nend program p\n" }}, .{ .init_options = "{\"formatter\": \"zfls\"}" });
    defer w.deinit();
    try std.testing.expectEqualStrings("program p\n   call f(a, &\n          b)\n   x = 1 + &\n      2\nend program p\n", try formatted(w, "k.f90"));
}

test "--case writes the keywords in a case, not the names (#986)" {
    const w = try h.Workspace.init(&.{.{ .name = "c.f90", .text = "PROGRAM Main\nINTEGER :: Do_It\nDo_It = 1\nIF (Do_It > 0) PRINT *, 'If'\nEND PROGRAM Main\n" }}, .{ .init_options = "{\"formatter\": \"zfls\", \"formatter_args\": [\"--case\", \"lower\"]}" });
    defer w.deinit();
    try std.testing.expectEqualStrings("program Main\n   integer :: Do_It\n   Do_It = 1\n   if (Do_It > 0) print *, 'If'\nend program Main\n", try formatted(w, "c.f90"));
}

test "--spacing and --align: blanks around operators, the :: of declarations in a column (#986)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = "subroutine s(x,n)\nreal(8),intent(inout)::x(:)\ninteger::n\ninteger::k\ndo k=1,n\nif(x(k)>=0)x(k)=f(x(k),key=2)\nend do\nend subroutine\n" }}, .{ .init_options = "{\"formatter\": \"zfls\", \"formatter_args\": [\"--spacing\", \"--align\"]}" });
    defer w.deinit();
    try std.testing.expectEqualStrings(
        "subroutine s(x, n)\n   real(8), intent(inout) :: x(:)\n   integer                :: n\n   integer                :: k\n   do k = 1, n\n      if(x(k) >= 0)x(k) = f(x(k), key=2)\n   end do\nend subroutine\n",
        try formatted(w, "s.f90"),
    );
}

test "Enter indents the line it ends: an END at its construct's depth (#986)" {
    const old = "      end do";
    const w = try h.Workspace.init(&.{.{ .name = "e.f90", .text = "program p\n   integer :: k\n   do k = 1, 2\n      k = k\n" ++ old ++ "\n\nend program p\n" }}, .{ .init_options = "{\"formatter\": \"zfls\"}" });
    defer w.deinit();
    try w.open("e.f90", "fortran");
    const edits = try w.onTypeFormatting("e.f90", .{ .line = 5, .col = 0 }, "\n");
    var line: []const u8 = old;
    var i = edits.len;
    while (i > 0) {
        i -= 1;
        const e = edits[i];
        line = try std.mem.concat(w.a(), u8, &.{ line[0..@intCast(e.start)], e.new_text, line[@intCast(e.end)..] });
    }
    try std.testing.expectEqualStrings("   end do", line);
    // another formatter's: nothing
    const other = try h.Workspace.init(&.{.{ .name = "e.f90", .text = "program p\n      end program p\n\n" }}, .{});
    defer other.deinit();
    try other.open("e.f90", "fortran");
    try std.testing.expectEqual(@as(usize, 0), (try other.onTypeFormatting("e.f90", .{ .line = 2, .col = 0 }, "\n")).len);
}

test "fixed form: the code after column 6 indented, labels, comments and continued literals as they are (#986)" {
    const fixed = h.File{ .name = "f.f", .text = "      program p\nc     a comment\n      integer i\n      do 10 i = 1, 2\n      if (i .gt. 1) then\n      print *, 'it''s a long\n     &literal'\n      else\n      print *, i,\n     &  i\n      end if\n   10 continue\n      end\n" };
    const w = try h.Workspace.init(&.{fixed}, .{ .init_options = "{\"formatter\": \"zfls\"}" });
    defer w.deinit();
    try std.testing.expectEqualStrings(
        "      program p\nc     a comment\n         integer i\n         do 10 i = 1, 2\n            if (i .gt. 1) then\n      print *, 'it''s a long\n     &literal'\n            else\n               print *, i,\n     &           i\n            end if\n   10    continue\n      end\n",
        try formatted(w, "f.f"),
    );
}

test "the corpus formatted keeps its tokens, and formatting it again changes nothing (#986)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fortran", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next(io)) |e| for ([_][]const u8{ "{\"formatter\": \"zfls\"}", "{\"formatter\": \"zfls\", \"formatter_args\": [\"--spacing\", \"--align\", \"--indent-directives\"]}" }) |options| {
        if (e.kind != .file or !(std.mem.endsWith(u8, e.name, ".f90") or std.mem.endsWith(u8, e.name, ".F90") or std.mem.endsWith(u8, e.name, ".f"))) continue;
        const text = try dir.readFileAlloc(io, e.name, a, .limited(1 << 22));
        const w = try h.Workspace.init(&.{.{ .name = e.name, .text = text }}, .{ .init_options = options });
        defer w.deinit();
        const once = try formatted(w, e.name);
        const before = try zfls.indent.tokens(a, try lines(a, text));
        const after = try zfls.indent.tokens(a, try lines(a, once));
        try h.expect(std.mem.eql(u8, before, after), "{s}: the tokens changed", .{e.name});
        try w.replaceText(e.name, once);
        const twice = try formatted(w, e.name);
        try h.expect(std.mem.eql(u8, once, twice), "{s}: formatting again changed it", .{e.name});
        checked += 1;
    };
    try h.expect(checked >= 10, "{d} files of the corpus", .{checked});
}

fn lines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, l);
    return out.items;
}
