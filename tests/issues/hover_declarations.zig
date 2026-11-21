//! Upstream issues about the hover of declarations: attribute statements,
//! `pass ( self )`, and declarations shown as written.

const std = @import("std");
const h = @import("harness.zig");

/// The hover of a variable, its declaration line alone, is `want`
fn expectDecl(w: *h.Workspace, name: []const u8, p: h.Pos, want: []const u8) !void {
    const got = (try w.hover(name, p)) orelse return h.unmet("{s}:{d}:{d}: no hover, expected {s}", .{ name, p.line + 1, p.col, want });
    const fenced = try std.mem.concat(std.testing.allocator, u8, &.{ "\n", want, "\n" });
    defer std.testing.allocator.free(fenced);
    if (std.mem.find(u8, got, fenced) == null) return h.unmet("{s}:{d}:{d}: hover is not {s}: {s}", .{ name, p.line + 1, p.col, want, got });
}

const attr_stmts = [_]h.File{
    .{ .name = "a.f90", .text =
    \\module m
    \\  implicit none
    \\contains
    \\  subroutine t(v, n, w)
    \\    integer :: n
    \\    real :: v, w
    \\    dimension v(n)
    \\    optional :: w
    \\    v(1) = 0
    \\  end subroutine
    \\  subroutine caller()
    \\    real :: arr(4)
    \\    call t(arr, 4)
    \\  end subroutine
    \\  subroutine before(q)
    \\    dimension q(2)
    \\    intent(out) q
    \\    real :: q
    \\    q = 0
    \\  end subroutine
    \\end module
    \\
    },
    .{ .name = "b.f90", .text =
    \\subroutine attrs(a, b)
    \\  real :: x, y, z, a, b, c
    \\  dimension x(3), a(*)
    \\  allocatable :: y(:)
    \\  pointer :: z
    \\  intent(in) :: a
    \\  optional :: b
    \\  save x
    \\  save
    \\  save /blk/
    \\  target :: c
    \\  c = x(1) + a(1)
    \\end subroutine
    \\
    },
    .{ .name = "c.f", .text =
    \\      SUBROUTINE S
    \\      PARAMETER (PI=3.14159, KMAX=10)
    \\      DIMENSION A(10)
    \\      A(1) = PI
    \\      PRINT *, KMAX
    \\      END
    \\
    },
    // a type declaration keeps the attributes after VALUE
    .{ .name = "d.f90", .text =
    \\subroutine s(x, y)
    \\  integer, value, intent(in) :: x
    \\  real, volatile :: y
    \\  y = x
    \\end subroutine
    \\
    },
};

test "attribute statements give their attribute to the names they list (#238)" {
    const w = try h.Workspace.init(&attr_stmts, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("a.f90");
    try expectDecl(w, "a.f90", w.pos("a.f90", "v(1) = 0", 0, 0), "REAL, DIMENSION(n) :: v");
    try expectDecl(w, "a.f90", w.pos("a.f90", "w)", 0, 0), "REAL, OPTIONAL :: w");
    // the declaration after the statements
    try expectDecl(w, "a.f90", w.pos("a.f90", "q = 0", 0, 0), "REAL, DIMENSION(2), INTENT(OUT) :: q");
    for ([_][2][]const u8{
        .{ "x, y", "REAL, DIMENSION(3), SAVE :: x" },
        .{ "y, z", "REAL, ALLOCATABLE, DIMENSION(:) :: y" },
        .{ "z, a", "REAL, POINTER :: z" },
        .{ "a, b, c", "REAL, DIMENSION(*), INTENT(IN) :: a" },
        .{ "b, c", "REAL, OPTIONAL :: b" },
        .{ "c\n", "REAL, TARGET :: c" },
    }) |case| try expectDecl(w, "b.f90", w.pos("b.f90", case[0], 0, 0), case[1]);
    // implicitly typed names: the statement declares them
    try expectDecl(w, "c.f", w.pos("c.f", "PI\n", 0, 0), "REAL, PARAMETER :: PI = 3.14159");
    try expectDecl(w, "c.f", w.pos("c.f", "PI=", 0, 0), "REAL, PARAMETER :: PI = 3.14159");
    try expectDecl(w, "c.f", w.pos("c.f", "KMAX\n", 0, 0), "INTEGER, PARAMETER :: KMAX = 10");
    try expectDecl(w, "c.f", w.pos("c.f", "A(1)", 0, 0), "REAL, DIMENSION(10) :: A");
    try expectDecl(w, "c.f", w.pos("c.f", "A(10)", 0, 0), "REAL, DIMENSION(10) :: A");
    const def = (try w.definition("c.f", w.pos("c.f", "PI\n", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 1), def.line);
    try expectDecl(w, "d.f90", w.pos("d.f90", "x\n", 0, 0), "INTEGER, VALUE, INTENT(IN) :: x");
    try expectDecl(w, "d.f90", w.pos("d.f90", "y = x", 0, 0), "REAL, VOLATILE :: y");
}

test "`pass ( self )` with blanks names the passed-object argument (#243)" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module m
        \\  implicit none
        \\  type t
        \\    integer :: v
        \\  contains
        \\    procedure, pass ( self ) :: get
        \\    procedure, pass(self) :: get2 => get
        \\    procedure, PASS( SELF ), public :: get3 => get
        \\  end type
        \\contains
        \\  integer function get(k, self)
        \\    integer, intent ( in ) :: k
        \\    class(t), intent(in) :: self
        \\    get = self%v + k
        \\  end function
        \\  subroutine use_it()
        \\    type(t) :: o
        \\    print *, o%get(1)
        \\    print *, o%get2(1)
        \\    print *, o%get3(1)
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("a.f90");
    for ([_][]const u8{ "get(1)", "get2(1)", "get3(1)" }) |call| {
        const p = w.pos("a.f90", call, 0, 0);
        try w.expectHoverContains("a.f90", p, "(k) RESULT(get)\n INTEGER, INTENT(IN) :: k");
        const hv = (try w.hover("a.f90", p)).?;
        try h.expect(std.mem.find(u8, hv, ":: self") == null, "{s}: the hover lists self: {s}", .{ call, hv });
        const sig = (try w.signature("a.f90", w.pos("a.f90", call, 0, call.len - 2))) orelse return h.unmet("{s}: no signature help", .{call});
        try h.expect(std.mem.endsWith(u8, sig.label, "(k)"), "{s}: signature {s}", .{ call, sig.label });
    }
}

const decl_hovers = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  integer, parameter :: arr(3) = [1, 2, 3]
    \\  integer, dimension(3), parameter :: crr = [1, 2, 3]
    \\  character(len=3), parameter :: names(2) = ['abc', 'def']
    \\  character(len=6), parameter :: space_str = 'a   b' // "c"
    \\  character :: s(3)[*]*10
    \\  character :: s2(3)*10
    \\  real, dimension(3) :: a, b(5)
    \\  real, dimension(3), target :: c(2,2)
    \\  integer, parameter :: d(2, 2) = reshape([1, 2, 3, 4], [2, 2])
    \\  integer, parameter :: p1 = 1, p2(2) = [1, 2], p3 = 3
    \\  character(len=*), parameter :: blanks = "x  y", &
    \\       more = 'u   v'
    \\  character(len=4), parameter :: q1 = 'a;b'; integer, parameter :: q2 = 2
    \\  character(kind=4, len=200) :: k4*100
    \\contains
    \\  subroutine old(u, v)
    \\    character*(*) u, v*8
    \\    real*8 r8b, r4*4
    \\    print *, arr
    \\  end subroutine
    \\  logical function lf()
    \\    !! doc of lf
    \\    lf = .false.
    \\  end function
    \\  function lg()
    \\    !! doc of lg
    \\    logical :: lg
    \\    lg = .false.
    \\  end function
    \\end module
    \\
}};

test "hover of a declaration shows it as written: values, strings, lengths, one DIMENSION (#237)" {
    const w = try h.Workspace.init(&decl_hovers, .{});
    defer w.deinit();
    for ([_][2][]const u8{
        .{ "arr(3)", "INTEGER, PARAMETER, DIMENSION(3) :: arr = [1, 2, 3]" },
        .{ "crr", "INTEGER, DIMENSION(3), PARAMETER :: crr = [1, 2, 3]" },
        .{ "names", "CHARACTER(len=3), PARAMETER, DIMENSION(2) :: names = ['abc', 'def']" },
        .{ "space_str", "CHARACTER(len=6), PARAMETER :: space_str = 'a   b' // \"c\"" },
        .{ "s(3)", "CHARACTER*10, DIMENSION(3), CODIMENSION[*] :: s" },
        .{ "s2", "CHARACTER*10, DIMENSION(3) :: s2" },
        .{ "a, b", "REAL, DIMENSION(3) :: a" },
        .{ "b(5)", "REAL, DIMENSION(5) :: b" },
        .{ "c(2,2)", "REAL, DIMENSION(2,2), TARGET :: c" },
        .{ "d(2, 2)", "INTEGER, PARAMETER, DIMENSION(2, 2) :: d = reshape([1, 2, 3, 4], [2, 2])" },
        .{ "p1", "INTEGER, PARAMETER :: p1 = 1" },
        .{ "p2", "INTEGER, PARAMETER, DIMENSION(2) :: p2 = [1, 2]" },
        .{ "p3", "INTEGER, PARAMETER :: p3 = 3" },
        .{ "blanks", "CHARACTER(len=*), PARAMETER :: blanks = \"x  y\"" },
        .{ "more", "CHARACTER(len=*), PARAMETER :: more = 'u   v'" },
        .{ "q1", "CHARACTER(len=4), PARAMETER :: q1 = 'a;b'" },
        .{ "q2", "INTEGER, PARAMETER :: q2 = 2" },
        .{ "k4", "CHARACTER(kind=4, LEN=100) :: k4" },
        .{ "u, v", "CHARACTER*(*) :: u" },
        .{ "v*8", "CHARACTER*8 :: v" },
        .{ "r8b", "REAL*8 :: r8b" },
        .{ "r4*4", "REAL*4 :: r4" },
    }) |case| try expectDecl(w, "m.f90", w.pos("m.f90", case[0], 0, 0), case[1]);
    // the documentation of a function with a type prefix is the function's
    const lf = (try w.hover("m.f90", w.pos("m.f90", "lf()", 0, 0))) orelse return error.NoHover;
    try h.expect(std.mem.find(u8, lf, "**Return:**") == null, "lf: {s}", .{lf});
    try h.expect(std.mem.find(u8, lf, "```\n-----\ndoc of lf") != null, "lf: {s}", .{lf});
    const lg = (try w.hover("m.f90", w.pos("m.f90", "lg()", 0, 0))) orelse return error.NoHover;
    try h.expect(std.mem.find(u8, lg, "```\n-----\ndoc of lg") != null, "lg: {s}", .{lg});
    // the named-constant inlay hint has the value too
    var found = false;
    for (try w.inlayHints("m.f90")) |hint| found = found or std.mem.find(u8, hint.label, "[1, 2, 3]") != null;
    try h.expect(found, "no inlay hint = [1, 2, 3] on the use of arr", .{});
}

test "a pointer initialized with `=> target` hovers as itself, not its target (#700)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text =
        \\module m
        \\  implicit none
        \\  real, target :: t(3)
        \\  real, pointer :: p(:) => t
        \\  integer, target :: t2(2, 2)
        \\  integer, pointer :: r(:, :) => t2, s => null()
        \\contains
        \\  subroutine use_them()
        \\    print *, p, r, s
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    for ([_]struct { usize, []const u8 }{
        .{ 0, "REAL, POINTER, DIMENSION(:) :: p" },
        .{ 3, "INTEGER, POINTER, DIMENSION(:, :) :: r" },
        .{ 6, "INTEGER, POINTER :: s" },
    }) |case| try expectDecl(w, "p.f90", w.pos("p.f90", "p, r, s", 0, case[0]), case[1]);
}
