//! The argument checks, the quick fixes and stub actions, and the module
//! graph.

const std = @import("std");
const h = @import("harness.zig");
const edits = @import("edits.zig");

fn indexIn(names: []const []const u8, name: []const u8) usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return std.math.maxInt(usize);
}

test "the module graph: compile order, and circular USE" {
    const w = try h.Workspace.init(&.{
        .{ .name = "kinds.f90", .text = "module kinds\n  integer, parameter :: dp = kind(1.d0)\nend module kinds\n" },
        .{ .name = "geom.f90", .text = "module geom\n  use kinds, only: dp\n  real(dp) :: origin\nend module geom\n" },
        .{ .name = "geom_impl.f90", .text = "submodule (geom) geom_impl\nend submodule geom_impl\n" },
        .{ .name = "app.f90", .text = "module app\ncontains\n  subroutine run()\n    use geom, only: origin\n    print *, origin\n  end subroutine run\nend module app\n" },
        .{ .name = "ping.f90", .text = "module ping\n  use pong\nend module ping\n" },
        .{ .name = "pong.f90", .text = "module pong\ncontains\n  subroutine back()\n    use ping\n  end subroutine back\nend module pong\n" },
    }, .{});
    defer w.deinit();
    const co = try w.compileOrder();
    // each module after those it uses (the USE inside a procedure counts),
    // a submodule after its module
    try std.testing.expect(indexIn(co.order, "kinds") < indexIn(co.order, "geom"));
    try std.testing.expect(indexIn(co.order, "geom") < indexIn(co.order, "geom_impl"));
    try std.testing.expect(indexIn(co.order, "geom") < indexIn(co.order, "app"));
    try std.testing.expectEqual(@as(usize, 1), co.cycles);
    // each USE of the cycle is an error
    for ([_][]const u8{ "ping.f90", "pong.f90" }) |f| {
        var found = false;
        for (try w.diagnostics(f)) |d| if (std.mem.eql(u8, d.code, "circular-use")) {
            found = true;
        };
        try std.testing.expect(found);
    }
    for (try w.diagnostics("geom.f90")) |d| try std.testing.expect(!std.mem.eql(u8, d.code, "circular-use"));
}

test "argument checks: count, keywords, missing arguments, INTENT(IN) assignments" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module ops
        \\  implicit none
        \\  type :: box
        \\    real :: v
        \\  contains
        \\    procedure :: scale
        \\  end type box
        \\contains
        \\  subroutine move(p, dx, dy)
        \\    real, intent(inout) :: p
        \\    real, intent(in) :: dx
        \\    real, intent(in), optional :: dy
        \\    dx = 1.0
        \\    p = p + dx
        \\  end subroutine move
        \\  subroutine scale(self, f)
        \\    class(box), intent(inout) :: self
        \\    real, intent(in) :: f
        \\    self%v = self%v * f
        \\  end subroutine scale
        \\  real function half(x)
        \\    real, intent(in) :: x
        \\    half = x / 2
        \\  end function half
        \\end module ops
        \\program main
        \\  use ops
        \\  implicit none
        \\  real :: q
        \\  type(box) :: b
        \\  call move(q, 1.0)
        \\  call move(q, 1.0, 2.0)
        \\  call move(q, 1.0, 2.0, 3.0)
        \\  call move(q, dz=1.0)
        \\  call move(q)
        \\  call move(q, 1.0, &
        \\            dy=2.0)
        \\  call b%scale(2.0)
        \\  call b%scale()
        \\  q = half(q) + half(x=q)
        \\  q = half(q, q)
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("a.f90")) |d| {
        if (std.mem.eql(u8, d.code, "argument-mismatch") or std.mem.eql(u8, d.code, "intent-in-assigned")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Assignment to INTENT(IN) argument dx",
        "Too many arguments for move: 3 expected",
        "move has no argument dz",
        "Missing argument dx of move",
        "Missing argument dx of move",
        "Missing argument f of scale",
        "Too many arguments for half: 1 expected",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn actionNamed(acts: []const h.Workspace.Action, title: []const u8) ?h.Workspace.Action {
    for (acts) |act| if (std.mem.eql(u8, act.title, title)) return act;
    return null;
}

test "quick fixes: IMPLICIT NONE, modern operators, kind parameters, keyword case" {
    const w = try h.Workspace.init(&.{.{ .name = "q.f90", .text =
        \\program q
        \\  real*8 :: x
        \\  real :: len
        \\  len = 3
        \\  if (x.eq.1.0d0 .and. len.ge.2) print *, 'x.eq.1'
        \\end program q
        \\
    }}, .{});
    defer w.deinit();
    // IMPLICIT NONE after the first line of the program
    const implicit = actionNamed(try w.codeActions("q.f90", 0), "Add IMPLICIT NONE to q") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  implicit none\n", implicit.new_text);
    try std.testing.expectEqual(@as(i64, 1), implicit.line);
    const kinds = actionNamed(try w.codeActions("q.f90", 1), "Write the kinds given with * as kind parameters") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  real(8) :: x", kinds.new_text);
    const ops = actionNamed(try w.codeActions("q.f90", 4), "Write .eq. ... .ge. as == ... >=") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  if (x == 1.0d0 .and. len >= 2) print *, 'x.eq.1'", ops.new_text);
    // keyword case: a Source Action, not offered otherwise
    try std.testing.expect(actionNamed(try w.codeActions("q.f90", 4), "Keywords in upper case") == null);
    const src = try w.codeActionsOf("q.f90", 0, 0, &.{"source"});
    const upper = actionNamed(src, "Keywords in upper case") orelse return error.TestUnexpectedResult;
    // program, real, real, if, eq, and, ge, print, end, program; not the
    // variable len
    try std.testing.expectEqual(@as(usize, 10), upper.edits);
    try std.testing.expectEqualStrings("PROGRAM", upper.new_text);
}

test "argument checks: the type and rank of variables and literals" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module ops
        \\  implicit none
        \\  type :: pt
        \\    real :: x
        \\  end type pt
        \\contains
        \\  subroutine take(n, x, v, p, s)
        \\    integer, intent(in) :: n
        \\    real(8), intent(in) :: x
        \\    real, intent(in) :: v(:)
        \\    type(pt), intent(in) :: p
        \\    character(len=*), intent(in) :: s
        \\  end subroutine take
        \\  elemental real function sq(a)
        \\    real, intent(in) :: a
        \\    sq = a * a
        \\  end function sq
        \\  subroutine any_rank(a)
        \\    real, intent(in) :: a(..)
        \\  end subroutine any_rank
        \\end module ops
        \\program main
        \\  use ops
        \\  implicit none
        \\  integer :: i
        \\  real :: r, arr(3)
        \\  type(pt) :: q
        \\  call take(1, 2.0d0, arr, q, 'ok')
        \\  call take(1.5, 2, arr, q, 'ok')
        \\  call take(i, r, r, q, 'ok')
        \\  call take(i, r, arr, q, s=3)
        \\  call take(i, r, 1.0, 'x', 'ok')
        \\  arr = sq(arr)
        \\  call any_rank(arr)
        \\  call any_rank(r)
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("t.f90")) |d| {
        if (std.mem.eql(u8, d.code, "argument-mismatch")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Argument n of take: integer expected, real given",
        "Argument x of take: real expected, integer given",
        // not for a scalar variable: it may be an array element passed to an
        // explicit-shape or assumed-size array (sequence association)
        "Argument s of take: character expected, integer given",
        "Argument v of take: an array expected, a scalar given",
        "Argument p of take: derived expected, character given",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "stub actions: an interface block for an external procedure, submodule stubs" {
    const w = try h.Workspace.init(&.{
        .{ .name = "ext.f90", .text =
        \\subroutine ext(a)
        \\  real, intent(in) :: a
        \\end subroutine ext
        \\
        },
        .{ .name = "main.f90", .text =
        \\program main
        \\  implicit none
        \\  real :: r
        \\  call ext(r)
        \\end program main
        \\
        },
        .{ .name = "m.f90", .text =
        \\module m
        \\  interface
        \\    module subroutine foo(x)
        \\      real, intent(in) :: x
        \\    end subroutine foo
        \\  end interface
        \\end module m
        \\
        },
        .{ .name = "n.f90", .text =
        \\module n
        \\  interface
        \\    module subroutine bar()
        \\    end subroutine bar
        \\  end interface
        \\end module n
        \\
        },
        .{ .name = "n_sub.f90", .text =
        \\submodule (n) n_sub
        \\contains
        \\end submodule n_sub
        \\
        },
    }, .{});
    defer w.deinit();
    const iface = actionNamed(try w.codeActions("main.f90", 3), "Add an interface block for ext") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, iface.new_text, "  interface\n    subroutine ext(a)\n      real, intent(in) :: a\n    end subroutine ext\n  end interface\n"));
    try std.testing.expectEqual(@as(i64, 3), iface.line);
    const new_sub = actionNamed(try w.codeActions("m.f90", 2), "Implement foo in a new submodule") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, new_sub.new_text, "submodule (m) m_impl\ncontains\n  module procedure foo\n") != null);
    try std.testing.expect(actionNamed(try w.codeActions("n.f90", 2), "Implement bar in submodule n_sub") != null);
}

test "argument checks: kinds of variables and literals" {
    const w = try h.Workspace.init(&.{.{ .name = "k.f90", .text =
        \\module kinds
        \\  use, intrinsic :: iso_fortran_env, only: real64, int64
        \\  use, intrinsic :: iso_c_binding, only: c_double
        \\  implicit none
        \\  integer, parameter :: dp = kind(1d0), sp = selected_real_kind(6)
        \\  integer, parameter :: wp = dp, qp = selected_real_kind(p=30)
        \\contains
        \\  subroutine take(x, n, y)
        \\    real(dp), intent(in) :: x
        \\    integer(int64), intent(in) :: n
        \\    real(kind=sp), intent(in) :: y
        \\  end subroutine take
        \\end module kinds
        \\program main
        \\  use kinds
        \\  implicit none
        \\  real(real64) :: a
        \\  real(c_double) :: b
        \\  double precision :: c
        \\  real :: d
        \\  real*8 :: e
        \\  real(wp) :: f
        \\  real(qp) :: g
        \\  integer :: i
        \\  integer(8) :: j
        \\  call take(a, j, d)
        \\  call take(b, 1_int64, 1.0)
        \\  call take(c, 3_8, 2.5e0)
        \\  call take(e, j, 1.0_sp)
        \\  call take(f, j, d)
        \\  call take(1.0, j, d)
        \\  call take(d, i, 1d0)
        \\  call take(g, 3, d)
        \\  call take(2.0_dp, j, d)
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("k.f90")) |d| {
        if (std.mem.eql(u8, d.code, "argument-kind")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Argument x of take: REAL(8) expected, REAL(4) given",
        "Argument x of take: REAL(8) expected, REAL(4) given",
        "Argument n of take: INTEGER(8) expected, INTEGER(4) given",
        "Argument y of take: REAL(4) expected, REAL(8) given",
        "Argument x of take: REAL(8) expected, REAL(16) given",
        "Argument n of take: INTEGER(8) expected, INTEGER(4) given",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "argument checks: types and ranks of expressions" {
    const w = try h.Workspace.init(&.{.{ .name = "e.f90", .text =
        \\module procs
        \\  implicit none
        \\  type :: pt
        \\    integer :: n
        \\    real :: r4
        \\  end type pt
        \\  type, extends(pt) :: pt2
        \\  end type pt2
        \\contains
        \\  subroutine sr(x)
        \\    real, intent(in) :: x
        \\  end subroutine sr
        \\  subroutine sd(x)
        \\    double precision, intent(in) :: x
        \\  end subroutine sd
        \\  subroutine sa(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine sa
        \\  subroutine sc(c)
        \\    character(len=*), intent(in) :: c
        \\  end subroutine sc
        \\  real function f(x)
        \\    real, intent(in) :: x
        \\    f = x
        \\  end function f
        \\end module procs
        \\program main
        \\  use procs
        \\  implicit none
        \\  integer :: i, idx(2)
        \\  real :: r, a(3)
        \\  character(len=4) :: s
        \\  type(pt2) :: q
        \\  call sr(i + 1)
        \\  call sr(r * 2 + i)
        \\  call sr(r > 0.0 .and. i == 1)
        \\  call sa(r + 1.0)
        \\  call sa(a(1))
        \\  call sr(a(:))
        \\  call sr(a + 1.0)
        \\  call sr(q%n)
        \\  call sc('a' // s)
        \\  call sr('a' // s)
        \\  call sr(f(r))
        \\  call sr(a(idx))
        \\  call sr(sqrt(r))
        \\  call sr((1.0, 2.0))
        \\  call sa([1.0, 2.0])
        \\  call sd(q%r4)
        \\  call sr(-r)
        \\  call sr(a(i + 1))
        \\  call sc(s(1:2))
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("e.f90")) |d| {
        if (std.mem.eql(u8, d.code, "argument-mismatch") or std.mem.eql(u8, d.code, "argument-kind")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Argument x of sr: real expected, integer given",
        "Argument x of sr: real expected, logical given",
        "Argument v of sa: an array expected, a scalar given",
        "Argument x of sr: a scalar expected, an array given",
        "Argument x of sr: a scalar expected, an array given",
        "Argument x of sr: real expected, integer given",
        "Argument x of sr: real expected, character given",
        "Argument x of sr: a scalar expected, an array given",
        "Argument x of sr: real expected, complex given",
        "Argument x of sd: REAL(8) expected, REAL(4) given",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

const iface_files = [_]h.File{
    .{ .name = "kinds.f90", .text =
    \\module kinds
    \\  implicit none
    \\  integer, parameter :: dp = kind(1.d0)
    \\end module kinds
    \\
    },
    .{ .name = "ext.f90", .text =
    \\subroutine scale(v, n, factor)
    \\  use kinds, only: dp
    \\  implicit none
    \\  integer, intent(in) :: n
    \\  real(dp), intent(inout) :: v(n)
    \\  real(dp), intent(in), optional :: factor
    \\  if (present(factor)) v = v * factor
    \\end subroutine scale
    \\
    \\function norm2sq(x) result(s)
    \\  use kinds, only: dp
    \\  implicit none
    \\  integer, parameter :: m = 3
    \\  real(dp), intent(in) :: x(m)
    \\  real(dp) :: s, unused_local
    \\  s = sum(x * x)
    \\end function norm2sq
    \\
    \\integer function count_pos(a)
    \\  implicit none
    \\  integer, intent(in) :: a(:)
    \\  count_pos = count(a > 0)
    \\end function count_pos
    \\
    },
    .{ .name = "axpy.f", .text =
    \\      subroutine axpy(n, alpha, xs, ys, workspace, scratchpad)
    \\      integer n, i
    \\      double precision alpha, xs(n), ys(n), workspace(n),
    \\     &  scratchpad(n), tmp
    \\      do 10 i = 1, n
    \\         tmp = alpha*xs(i)
    \\         ys(i) = ys(i) + tmp
    \\ 10   continue
    \\      end
    \\
    },
    .{ .name = "iface.f90", .text =
    \\module iface
    \\  implicit none
    \\  interface
    \\    integer function count_pos(a)
    \\      integer, intent(in) :: a(:)
    \\    end function count_pos
    \\  end interface
    \\end module iface
    \\
    },
    // a subroutine
    .{ .name = "p1.f90", .text =
    \\program p1
    \\  use kinds, only: dp
    \\  implicit none
    \\  real(dp) :: v(3)
    \\  v = 1
    \\  call scale(v, 3)
    \\end program p1
    \\
    },
    // a function with a result, declared EXTERNAL by the caller
    .{ .name = "p2.f90", .text =
    \\program p2
    \\  use kinds, only: dp
    \\  implicit none
    \\  real(dp) :: v(3)
    \\  real(dp), external :: norm2sq
    \\  v = 1
    \\  print *, norm2sq(v)
    \\end program p2
    \\
    },
    // a function typed by the caller
    .{ .name = "p3.f90", .text =
    \\subroutine p3
    \\  implicit none
    \\  integer :: k, count_pos
    \\  k = count_pos([1, -2, 3])
    \\end subroutine p3
    \\
    },
    // explicit interfaces already: a block, a module's
    .{ .name = "p4.f90", .text =
    \\subroutine p4
    \\  use iface, only: count_pos
    \\  implicit none
    \\  interface
    \\    subroutine scale(v, n, factor)
    \\      use kinds, only: dp
    \\      integer, intent(in) :: n
    \\      real(dp), intent(inout) :: v(n)
    \\      real(dp), intent(in), optional :: factor
    \\    end subroutine scale
    \\  end interface
    \\  real(8) :: v(2)
    \\  call scale(v, 2)
    \\  print *, count_pos([1])
    \\end subroutine p4
    \\
    },
    // fixed form, from fixed form
    .{ .name = "p5.f", .text =
    \\      program p5
    \\      double precision x(3), y(3), w(3), s(3)
    \\      external axpy
    \\      call axpy(3, 2d0, x, y, w, s)
    \\      end
    \\
    },
};

/// That the action "Add an interface block for `proc`" on the line of
/// `needle` in `name` makes it `want`, which gfortran compiles
fn expectInterface(w: *h.Workspace, name: []const u8, needle: []const u8, proc: []const u8, want: []const u8) !void {
    const line = w.pos(name, needle, 0, 0).line;
    var buf: [128]u8 = undefined;
    const title = try std.mem.print(&buf, "Add an interface block for {s}", .{proc});
    const got = (try edits.applyAction(w, name, line, line, null, title)) orelse return h.unmet("no action \"{s}\" in {s}", .{ title, name });
    try h.expect(std.mem.eql(u8, got, want), "{s} becomes\n{s}", .{ name, got });
    try edits.expectCompiles(w, &.{ iface_files[0], iface_files[1], iface_files[2], .{ .name = name, .text = got } });
}

fn expectInterfaces(w: *h.Workspace) !void {
    try expectInterface(w, "p1.f90", "call scale", "scale",
        \\program p1
        \\  use kinds, only: dp
        \\  implicit none
        \\  real(dp) :: v(3)
        \\  interface
        \\    subroutine scale(v, n, factor)
        \\      use kinds, only: dp
        \\      implicit none
        \\      integer, intent(in) :: n
        \\      real(dp), intent(inout) :: v(n)
        \\      real(dp), intent(in), optional :: factor
        \\    end subroutine scale
        \\  end interface
        \\  v = 1
        \\  call scale(v, 3)
        \\end program p1
        \\
    );
    // the caller's EXTERNAL declaration goes; the named constant the
    // arguments use comes along, the local variable does not
    try expectInterface(w, "p2.f90", "print *, norm2sq", "norm2sq",
        \\program p2
        \\  use kinds, only: dp
        \\  implicit none
        \\  real(dp) :: v(3)
        \\  interface
        \\    function norm2sq(x) result(s)
        \\      use kinds, only: dp
        \\      implicit none
        \\      integer, parameter :: m = 3
        \\      real(dp), intent(in) :: x(m)
        \\      real(dp) :: s
        \\    end function norm2sq
        \\  end interface
        \\  v = 1
        \\  print *, norm2sq(v)
        \\end program p2
        \\
    );
    try expectInterface(w, "p3.f90", "k = count_pos", "count_pos",
        \\subroutine p3
        \\  implicit none
        \\  integer :: k
        \\  interface
        \\    integer function count_pos(a)
        \\      implicit none
        \\      integer, intent(in) :: a(:)
        \\    end function count_pos
        \\  end interface
        \\  k = count_pos([1, -2, 3])
        \\end subroutine p3
        \\
    );
    // in fixed form, continued within 72 columns
    try expectInterface(w, "p5.f", "call axpy", "axpy",
        \\      program p5
        \\      double precision x(3), y(3), w(3), s(3)
        \\      interface
        \\        subroutine axpy(n, alpha, xs, ys, workspace, scratchpad)
        \\          integer n
        \\          double precision alpha, xs(n), ys(n), workspace(n),
        \\     &        scratchpad(n)
        \\        end subroutine axpy
        \\      end interface
        \\      call axpy(3, 2d0, x, y, w, s)
        \\      end
        \\
    );
    for ([_][]const u8{ "call scale", "print *, count_pos" }) |needle| {
        const line = w.pos("p4.f90", needle, 0, 0).line;
        for (try w.codeActions("p4.f90", line)) |act| {
            if (std.mem.startsWith(u8, act.title, "Add an interface block")) return h.unmet("p4.f90 offers {s}", .{act.title});
        }
    }
}

test "an interface block for an external procedure, after the caller's declarations" {
    const w = try h.Workspace.init(&iface_files, .{});
    defer w.deinit();
    expectInterfaces(w) catch |e| {
        std.debug.print("\n{s}\n", .{h.lastNote()});
        return e;
    };
}

test "argument checks: the dummy arguments of `!dir$ ignore_tkr`" {
    const w = try h.Workspace.init(&.{.{ .name = "tkr.f90", .text =
        \\module tkr
        \\  implicit none
        \\  interface
        \\    subroutine ext(buf, n)
        \\      !DIR$ IGNORE_TKR buf
        \\      real :: buf(*)
        \\      integer :: n
        \\    end subroutine ext
        \\  end interface
        \\contains
        \\  subroutine s(a)
        \\    !dir$ ignore_tkr a
        \\    real :: a(*)
        \\  end subroutine
        \\  subroutine t(b, c)
        \\    !dir$ ignore_tkr (tkr) b, (k) c ! the kind of c only
        \\    real :: b
        \\    real :: c
        \\  end subroutine
        \\  subroutine all(x, y)
        \\    !dir$ ignore_tkr
        \\    real :: x, y
        \\  end subroutine
        \\  subroutine outer(z)
        \\    real :: z
        \\    interface
        \\      subroutine inner(z)
        \\        !dir$ ignore_tkr z
        \\        real :: z
        \\      end subroutine inner
        \\    end interface
        \\  end subroutine
        \\  subroutine plain(p)
        \\    real :: p
        \\  end subroutine
        \\end module
        \\program p
        \\  use tkr
        \\  implicit none
        \\  integer :: i(4), n
        \\  double precision :: d(2,2), e
        \\  call ext(i, 4)
        \\  call ext(d, 1.0)
        \\  call s(i)
        \\  call s(d)
        \\  call t(i, e)
        \\  call t(1.0, n)
        \\  call all(i, d)
        \\  call outer(n)
        \\  call plain(n)
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("tkr.f90")) |d| {
        if (std.mem.startsWith(u8, d.message, "Argument ")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Argument n of ext: integer expected, real given",
        "Argument c of t: real expected, integer given",
        "Argument z of outer: real expected, integer given",
        "Argument p of plain: real expected, integer given",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "argument checks: the dummy arguments of NO_ARG_CHECK (gfortran's and Intel's)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "nac.f90", .text =
        \\module nac
        \\  implicit none
        \\  interface
        \\    subroutine ext(buf, n)
        \\      !GCC$ ATTRIBUTES NO_ARG_CHECK :: buf
        \\      integer :: buf(*)
        \\      integer :: n
        \\    end subroutine ext
        \\  end interface
        \\contains
        \\  subroutine s(a, b)
        \\    !dir$ attributes no_arg_check :: a
        \\    integer :: a(*)
        \\    integer :: b
        \\  end subroutine
        \\  subroutine t(c)
        \\    !DEC$ ATTRIBUTES REFERENCE, NO_ARG_CHECK :: c
        \\    integer :: c
        \\  end subroutine
        \\  subroutine outer(z)
        \\    integer :: z
        \\    interface
        \\      subroutine inner(z)
        \\        !GCC$ ATTRIBUTES NO_ARG_CHECK :: z
        \\        integer :: z(*)
        \\      end subroutine inner
        \\    end interface
        \\  end subroutine
        \\end module
        \\program p
        \\  use nac
        \\  implicit none
        \\  real :: x(4), r
        \\  double precision :: d(2,2)
        \\  call ext(x, 4)
        \\  call ext(d, 1.0)
        \\  call s(x, 1)
        \\  call s(d, r)
        \\  call t(d)
        \\  call outer(r)
        \\end program
        \\
        },
        .{ .name = "fixed.f", .text =
        \\      subroutine f(buf)
        \\CDEC$ ATTRIBUTES NO_ARG_CHECK :: buf
        \\      integer buf(*)
        \\      end
        \\      subroutine g(v)
        \\      integer v
        \\      end
        \\      program q
        \\      real y(3)
        \\      call f(y)
        \\      call g(y)
        \\      end
        \\
        },
    }, .{});
    defer w.deinit();
    for ([_]struct { []const u8, []const []const u8 }{
        .{ "nac.f90", &.{
            "Argument n of ext: integer expected, real given",
            "Argument b of s: integer expected, real given",
            "Argument z of outer: integer expected, real given",
        } },
        .{ "fixed.f", &.{"Argument v of g: integer expected, real given"} },
    }) |c| {
        var msgs: std.ArrayList([]const u8) = .empty;
        defer msgs.deinit(std.testing.allocator);
        for (try w.diagnostics(c[0])) |d| {
            if (std.mem.startsWith(u8, d.message, "Argument ")) try msgs.append(std.testing.allocator, d.message);
        }
        if (msgs.items.len != c[1].len) {
            std.debug.print("{s}: got {any}\n", .{ c[0], msgs.items });
            return error.TestExpectedEqual;
        }
        for (c[1], msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
    }
}
