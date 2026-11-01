//! Navigation requests zfls answers beyond fortls: prepareRename,
//! selection ranges and document links.

const std = @import("std");
const h = @import("harness.zig");

const files = [_]h.File{
    .{ .name = "consts.h", .text =
    \\#define N 4
    \\
    },
    .{ .name = "body.inc", .text =
    \\x = 1
    \\
    },
    .{ .name = "m.F90", .text =
    \\module m
    \\#include "consts.h"
    \\  implicit none
    \\contains
    \\  subroutine s(x, y)
    \\    real, intent(inout) :: x, y
    \\    integer :: i
    \\    do i = 1, N
    \\      y = max(x, y * 2.0) + &
    \\        1.0
    \\    end do
    \\    include 'body.inc'
    \\  end subroutine s
    \\end module m
    \\
    },
};

test "prepareRename: the name to rename, or nothing for an intrinsic or a keyword" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const p = (try w.prepareRename("m.F90", w.pos("m.F90", "y * 2.0", 0, 0))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("y", p.placeholder);
    try std.testing.expectEqual(w.pos("m.F90", "y * 2.0", 0, 0).line, p.line);
    try std.testing.expect((try w.prepareRename("m.F90", w.pos("m.F90", "max(", 0, 1))) == null);
    try std.testing.expect((try w.prepareRename("m.F90", w.pos("m.F90", "implicit", 0, 1))) == null);
}

test "selection ranges grow from the name to its parentheses, statement, constructs, procedure, module and file" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const at = w.pos("m.F90", "max(x", 0, 4);
    const sels = try w.selectionRanges("m.F90", at);
    // x, the arguments, the parenthesized arguments, the statement
    // (continued on the next line), DO, subroutine, module, file
    try std.testing.expect(sels.len >= 8);
    try std.testing.expectEqual(h.Workspace.Sel{ .sl = at.line, .sc = at.col, .el = at.line, .ec = at.col + 1 }, sels[0]);
    const stmt = sels[3];
    try std.testing.expectEqual(at.line, stmt.sl);
    try std.testing.expectEqual(at.line + 1, stmt.el);
    const do_line = w.pos("m.F90", "do i", 0, 0).line;
    try std.testing.expectEqual(do_line, sels[4].sl);
    const last = sels[sels.len - 1];
    try std.testing.expectEqual(@as(i64, 0), last.sl);
    for (sels[1..], sels[0 .. sels.len - 1]) |outer, inner| {
        try std.testing.expect(outer.sl < inner.sl or (outer.sl == inner.sl and outer.sc <= inner.sc));
        try std.testing.expect(outer.el > inner.el or (outer.el == inner.el and outer.ec >= inner.ec));
    }
}

test "document links on the files of #include and INCLUDE" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const links = try w.documentLinks("m.F90");
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expect(std.mem.endsWith(u8, links[0].target, "/consts.h"));
    try std.testing.expectEqual(w.pos("m.F90", "consts.h", 0, 0).col, links[0].start);
    try std.testing.expect(std.mem.endsWith(u8, links[1].target, "/body.inc"));
}

test "hansec #195 workspace symbols: names containing the query first, then fuzzy matches" {
    const w = try h.Workspace.init(&.{.{ .name = "r.f90", .text =
        \\module r
        \\contains
        \\  subroutine this_amazing_routine()
        \\  end subroutine this_amazing_routine
        \\  subroutine tar_file()
        \\  end subroutine tar_file
        \\end module r
        \\
    }}, .{});
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        const names = try w.workspaceSymbols("tar");
        if (names.len < 2 or !std.mem.eql(u8, names[0], "tar_file") or !std.mem.eql(u8, names[1], "this_amazing_routine"))
            break :blk h.unmet("tar: {any}", .{names});
        const all = try w.workspaceSymbols("thisamazingroutine");
        if (all.len != 1) break :blk h.unmet("thisamazingroutine: {any}", .{all});
    };
    try h.checkIn(.hansec, 195, .fixed, outcome);
}

test "inlay hints: dummy argument names of positional arguments, ASSOCIATE types" {
    const w = try h.Workspace.init(&.{.{ .name = "h.f90", .text =
        \\module geom
        \\  implicit none
        \\  type :: pt
        \\    real(8) :: x
        \\  contains
        \\    procedure :: shift
        \\  end type pt
        \\contains
        \\  subroutine move(p, dx, dy)
        \\    type(pt), intent(inout) :: p
        \\    real(8), intent(in) :: dx, dy
        \\  end subroutine move
        \\  subroutine shift(self, by)
        \\    class(pt), intent(inout) :: self
        \\    real(8), intent(in) :: by
        \\  end subroutine shift
        \\  real(8) function norm(p)
        \\    type(pt), intent(in) :: p
        \\    norm = abs(p%x)
        \\  end function norm
        \\end module geom
        \\program main
        \\  use geom
        \\  type(pt) :: p
        \\  real(8) :: d
        \\  call move(p, 1.0d0, dy=2.0d0)
        \\  call p%shift(0.5d0)
        \\  d = norm(p) + sqrt(2.0d0)
        \\  associate (xx => p%x)
        \\    d = xx
        \\  end associate
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    const hs = try w.inlayHints("h.f90");
    const Want = struct { needle: []const u8, plus: usize, label: []const u8 };
    const wants = [_]Want{
        // the argument named like its dummy argument has no hint
        .{ .needle = "1.0d0, dy", .plus = 0, .label = "dx:" },
        // the passed object of a type-bound procedure is not counted
        .{ .needle = "0.5d0)", .plus = 0, .label = "by:" },
        .{ .needle = "xx => p%x", .plus = 2, .label = ": REAL(8)" },
    };
    for (wants) |want| {
        const at = w.pos("h.f90", want.needle, 0, want.plus);
        const found = for (hs) |hint| {
            if (hint.line == at.line and hint.col == at.col and std.mem.eql(u8, hint.label, want.label)) break true;
        } else false;
        if (!found) {
            std.debug.print("hints: {any}\n", .{hs});
            return error.TestExpectedEqual;
        }
    }
    // no hint for p (named like its dummy), after a keyword argument, for an
    // intrinsic (sqrt) or for norm(p)
    for (hs) |hint| {
        try std.testing.expect(!std.mem.eql(u8, hint.label, "p:"));
        try std.testing.expect(!std.mem.eql(u8, hint.label, "dy:"));
        try std.testing.expect(!std.mem.eql(u8, hint.label, "x:"));
    }
    try std.testing.expectEqual(@as(usize, 3), hs.len);
}

fn findCall(cs: []const h.Workspace.Call, name: []const u8) ?h.Workspace.Call {
    for (cs) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    return null;
}

test "call hierarchy: callers among the references, callees in the body" {
    const w = try h.Workspace.init(&.{
        .{ .name = "lib.f90", .text =
        \\module lib
        \\  implicit none
        \\contains
        \\  subroutine step(x)
        \\    real, intent(inout) :: x
        \\    x = twice(x)
        \\    call log_it(x)
        \\  end subroutine step
        \\  real function twice(v)
        \\    real, intent(in) :: v
        \\    twice = 2 * v
        \\  end function twice
        \\  subroutine log_it(v)
        \\    real, intent(in) :: v
        \\    print *, v
        \\  end subroutine log_it
        \\end module lib
        \\
        },
        .{ .name = "main.f90", .text =
        \\program main
        \\  use lib, only: step, twice
        \\  real :: y
        \\  y = 1.0
        \\  call step(y)
        \\  call step(y)
        \\  y = twice(y)
        \\contains
        \\  subroutine inner()
        \\    call step(y)
        \\  end subroutine inner
        \\end program main
        \\
        },
    }, .{});
    defer w.deinit();
    const item = (try w.prepareCallHierarchy("lib.f90", w.pos("lib.f90", "subroutine step", 0, 12))) orelse return error.TestUnexpectedResult;
    // step is called twice by main and once by inner (not by the USE line)
    const in = try w.calls(item, true);
    try std.testing.expectEqual(@as(usize, 2), (findCall(in, "main") orelse return error.TestUnexpectedResult).sites);
    try std.testing.expectEqual(@as(usize, 1), (findCall(in, "inner") orelse return error.TestUnexpectedResult).sites);
    try std.testing.expectEqual(@as(usize, 2), in.len);
    // step calls twice and log_it
    const out = try w.calls(item, false);
    try std.testing.expect(findCall(out, "twice") != null and findCall(out, "log_it") != null);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // from a call site
    const at_call = (try w.prepareCallHierarchy("main.f90", w.pos("main.f90", "twice(y)", 0, 1))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("twice", h.Workspace.itemName(at_call));
    // main calls step and twice, not what inner calls
    const main_item = (try w.prepareCallHierarchy("main.f90", w.pos("main.f90", "program main", 0, 9))) orelse return error.TestUnexpectedResult;
    const main_out = try w.calls(main_item, false);
    try std.testing.expectEqual(@as(usize, 2), (findCall(main_out, "step") orelse return error.TestUnexpectedResult).sites);
}

test "inlay hints: the implicit type of a name that is not declared, once" {
    const w = try h.Workspace.init(&.{.{ .name = "i.f90", .text =
        \\program i
        \\  k = 1
        \\  k = k + 1
        \\  x = 2.0
        \\end program i
        \\
    }}, .{});
    defer w.deinit();
    const hs = try w.inlayHints("i.f90");
    try std.testing.expectEqual(@as(usize, 2), hs.len);
    try std.testing.expectEqualStrings(": INTEGER", hs[0].label);
    try std.testing.expectEqual(w.pos("i.f90", "k = 1", 0, 1).col, hs[0].col);
    try std.testing.expectEqualStrings(": REAL", hs[1].label);
}

test "inlay hints: the values of named constants where they are used" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text =
        \\program p
        \\  implicit none
        \\  integer, parameter :: n = 5
        \\  real, parameter :: pi = 3.14159265358979323846264338
        \\  real :: x(n)
        \\  x = pi * n + n
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    const hs = try w.inlayHints("p.f90");
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(std.testing.allocator);
    for (hs) |hint| try labels.append(std.testing.allocator, hint.label);
    // x(n) on line 5; pi and n once each on line 6; none on the declarations
    try std.testing.expectEqual(@as(usize, 3), hs.len);
    try std.testing.expectEqualStrings("= 5", hs[0].label);
    try std.testing.expectEqualStrings("= 3.1415926535897932384...", hs[1].label);
    try std.testing.expectEqual(w.pos("p.f90", "pi * n", 0, 2).col, hs[1].col);
}

test "hansec #115: from a BIND(C) procedure to its C declaration, and back" {
    const w = try h.Workspace.init(&.{
        .{ .name = "cfuncs.h", .text =
        \\#ifndef CFUNCS_H
        \\/* c_add(1, 2) in a comment */
        \\int c_add(int a, int b);
        \\double *make_grid (int n);
        \\#endif
        \\
        },
        .{ .name = "cfuncs.c", .text =
        \\#include "cfuncs.h"
        \\int c_add(int a, int b) { return a + b; }
        \\void use_it(void) {
        \\  int x = c_add(1, 2);
        \\  solve_f(x);
        \\}
        \\
        },
        .{ .name = "iface.f90", .text =
        \\module iface
        \\  use iso_c_binding
        \\  interface
        \\    integer(c_int) function c_add(a, b) bind(C, name="c_add")
        \\      import :: c_int
        \\      integer(c_int), value :: a, b
        \\    end function c_add
        \\  end interface
        \\contains
        \\  subroutine solve(n) bind(c, &
        \\      name="solve_f")
        \\    integer(c_int), value :: n
        \\    print *, c_add(n, 1)
        \\  end subroutine solve
        \\  subroutine plain()
        \\  end subroutine plain
        \\end module iface
        \\
        },
    }, .{});
    defer w.deinit();
    // the call goes to the interface, and to the C prototype and definition
    const defs = try w.definitions("iface.f90", w.pos("iface.f90", "c_add(n", 0, 1));
    try std.testing.expectEqual(@as(usize, 3), defs.len);
    try std.testing.expectEqual(@as(i64, 3), defs[0].line);
    var lines: [2]i64 = undefined;
    for (defs[1..], &lines) |d, *l| l.* = d.line;
    std.mem.sort(i64, &lines, {}, std.sort.asc(i64));
    // the prototype (cfuncs.h line 2) and the definition (cfuncs.c line 1),
    // not the comment or the call
    try std.testing.expect(std.mem.endsWith(u8, defs[1].uri, ".h") or std.mem.endsWith(u8, defs[1].uri, ".c"));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &lines);
    // a procedure without BIND(C): its definition alone
    try std.testing.expectEqual(@as(usize, 1), (try w.definitions("iface.f90", w.pos("iface.f90", "plain", 0, 1))).len);
    // zfls/bindC: the C name of the procedure at a position
    const b = try w.zflsRequest("zfls/bindC", try w.positionOf("iface.f90", w.pos("iface.f90", "solve(n)", 0, 1)));
    try std.testing.expectEqualStrings("solve_f", h.json.str(h.json.get(b, "cName")).?);
    // zfls/bindCTargets: from C to the Fortran procedure
    const t = try w.zflsRequest("zfls/bindCTargets", .{ .name = "solve_f" });
    try std.testing.expectEqual(@as(usize, 1), h.json.items(t).len);
    try std.testing.expectEqual(@as(i64, 9), h.json.int(h.json.path(h.json.items(t)[0], &.{ "range", "start", "line" })).?);
    // a C document opened in zfls: definition of the Fortran procedure it
    // calls, and nothing parsed or diagnosed
    try w.open("cfuncs.c", "c");
    const from_c = try w.definitions("cfuncs.c", w.pos("cfuncs.c", "solve_f", 0, 2));
    try std.testing.expectEqual(@as(usize, 1), from_c.len);
    try std.testing.expect(std.mem.endsWith(u8, from_c[0].uri, "iface.f90"));
    try std.testing.expectEqual(@as(usize, 0), (try w.messages()).len);
}

test "hansec #115: references across Fortran and C" {
    const w = try h.Workspace.init(&.{
        .{ .name = "cfuncs.h", .text =
        \\/* c_add(1, 2) in a comment */
        \\int c_add(int a, int b);
        \\
        },
        .{ .name = "cfuncs.c", .text =
        \\#include "cfuncs.h"
        \\int c_add(int a, int b) { return a + b; }
        \\void use_it(void) {
        \\  int x = c_add(1, 2);
        \\  solve_f(x); // solve_f(0)
        \\}
        \\
        },
        .{ .name = "iface.f90", .text =
        \\module iface
        \\  use iso_c_binding
        \\  interface
        \\    integer(c_int) function c_add(a, b) bind(C, name="c_add")
        \\      import :: c_int
        \\      integer(c_int), value :: a, b
        \\    end function c_add
        \\  end interface
        \\contains
        \\  subroutine solve(n) bind(c, name="solve_f")
        \\    integer(c_int), value :: n
        \\    print *, c_add(n, 1)
        \\  end subroutine solve
        \\end module iface
        \\
        },
        .{ .name = "other.f90", .text =
        \\module other
        \\  interface
        \\    function add2(a, b) bind(C, name="c_add")
        \\      use iso_c_binding, only: c_int
        \\      integer(c_int), value :: a, b
        \\      integer(c_int) :: add2
        \\    end function add2
        \\  end interface
        \\contains
        \\  subroutine run()
        \\    use iface, only: solve
        \\    print *, add2(1, 2)
        \\    call solve(3)
        \\  end subroutine run
        \\end module other
        \\
        },
    }, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Place = struct { file: []const u8, line: i64 };
    const places = struct {
        fn of(al: std.mem.Allocator, locs: []const h.Location) ![]const Place {
            var out: std.ArrayList(Place) = .empty;
            for (locs) |l| try out.append(al, .{ .file = std.fs.path.basename(l.uri), .line = l.line });
            std.mem.sort(Place, out.items, {}, struct {
                fn lt(_: void, x: Place, y: Place) bool {
                    const o = std.mem.order(u8, x.file, y.file);
                    return o == .lt or (o == .eq and x.line < y.line);
                }
            }.lt);
            return out.items;
        }
        fn expect(want: []const Place, got: []const Place) !void {
            errdefer for (got) |g| std.debug.print("  {s}:{d}\n", .{ g.file, g.line });
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |x, y| {
                try std.testing.expectEqualStrings(x.file, y.file);
                try std.testing.expectEqual(x.line, y.line);
            }
        }
    };
    // references of c_add: its Fortran references, those of the other
    // interface of the same C name, and the C declarations and call (not
    // the comment)
    const refs = try places.of(a, try w.references("iface.f90", w.pos("iface.f90", "c_add(n", 0, 1)));
    try places.expect(&.{
        .{ .file = "cfuncs.c", .line = 1 },
        .{ .file = "cfuncs.c", .line = 3 },
        .{ .file = "cfuncs.h", .line = 1 },
        .{ .file = "iface.f90", .line = 3 },
        .{ .file = "iface.f90", .line = 6 },
        .{ .file = "iface.f90", .line = 11 },
        .{ .file = "other.f90", .line = 2 },
        .{ .file = "other.f90", .line = 6 },
        .{ .file = "other.f90", .line = 11 },
    }, refs);
    // zfls/bindCReferences: the Fortran references alone (a C language
    // server gives the C ones)
    const fr = try w.zflsRequest("zfls/bindCReferences", .{ .name = "solve_f" });
    var locs: std.ArrayList(h.Location) = .empty;
    for (h.json.items(fr)) |item| try locs.append(a, .{
        .uri = h.json.str(h.json.get(item, "uri")).?,
        .line = h.json.int(h.json.path(item, &.{ "range", "start", "line" })).?,
        .col = 0,
    });
    try places.expect(&.{
        .{ .file = "iface.f90", .line = 9 },
        .{ .file = "iface.f90", .line = 12 },
        .{ .file = "other.f90", .line = 10 },
        .{ .file = "other.f90", .line = 12 },
    }, try places.of(a, locs.items));
    // a C document opened in zfls: the Fortran references and the C call
    try w.open("cfuncs.c", "c");
    const from_c = try places.of(a, try w.references("cfuncs.c", w.pos("cfuncs.c", "solve_f", 0, 2)));
    try places.expect(&.{
        .{ .file = "cfuncs.c", .line = 4 },
        .{ .file = "iface.f90", .line = 9 },
        .{ .file = "iface.f90", .line = 12 },
        .{ .file = "other.f90", .line = 10 },
        .{ .file = "other.f90", .line = 12 },
    }, from_c);
    // highlights stay in the document
    const hl = try w.server.dispatchPublic(a, "textDocument/documentHighlight", try w.positionOf("iface.f90", w.pos("iface.f90", "c_add(n", 0, 1)));
    for (h.json.items(hl)) |item| try std.testing.expect(std.mem.endsWith(u8, h.json.str(h.json.get(item, "uri")).?, "iface.f90"));
}

test "FortranBreaker #10: the module variables a line sees, for the debugger" {
    const w = try h.Workspace.init(&.{
        .{ .name = "consts.f90", .text =
        \\module consts
        \\  implicit none
        \\  integer, parameter :: n = 3
        \\  real :: scale = 2.0
        \\  real, private :: hidden
        \\  integer :: counter, other
        \\end module consts
        \\
        },
        .{ .name = "grid.f90", .text =
        \\module grid
        \\  use consts, only: factor => scale, counter
        \\  implicit none
        \\  real :: cells(10)
        \\  integer, private :: secret
        \\contains
        \\  subroutine step()
        \\    integer :: local_i
        \\    local_i = counter
        \\  end subroutine step
        \\end module grid
        \\
        },
        .{ .name = "main.f90", .text =
        \\program main
        \\  use grid
        \\  use consts
        \\  implicit none
        \\  call step()
        \\end program main
        \\
        },
    }, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = struct {
        fn of(al: std.mem.Allocator, v: h.json.Value) ![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (h.json.items(v)) |item| try out.append(al, try std.fmt.allocPrint(al, "{s}:{s}:{s}", .{
                h.json.str(h.json.get(item, "module")).?,
                h.json.str(h.json.get(item, "name")).?,
                h.json.str(h.json.get(item, "local")).?,
            }));
            return out.items;
        }
    };
    // in a module procedure: the module's own variables, private ones too,
    // then those of its USE, under their local names; no named constant,
    // nor what ONLY leaves out
    const in_step = try names.of(a, try w.zflsRequest("zfls/moduleVariables", try w.positionOf("grid.f90", w.pos("grid.f90", "local_i = counter", 0, 0))));
    const want_step = [_][]const u8{ "grid:cells:cells", "grid:secret:secret", "consts:scale:factor", "consts:counter:counter" };
    try std.testing.expectEqual(want_step.len, in_step.len);
    for (want_step, in_step) |x, y| try std.testing.expectEqualStrings(x, y);
    // in the program: the public variables of the modules it uses
    const in_main = try names.of(a, try w.zflsRequest("zfls/moduleVariables", try w.positionOf("main.f90", w.pos("main.f90", "call step", 0, 0))));
    const want_main = [_][]const u8{ "grid:cells:cells", "consts:scale:scale", "consts:counter:counter", "consts:other:other" };
    try std.testing.expectEqual(want_main.len, in_main.len);
    for (want_main, in_main) |x, y| try std.testing.expectEqualStrings(x, y);
    // the type, for the view
    const one = h.json.items(try w.zflsRequest("zfls/moduleVariables", try w.positionOf("grid.f90", w.pos("grid.f90", "local_i = counter", 0, 0))))[0];
    try std.testing.expectEqualStrings("REAL", h.json.str(h.json.get(one, "type")).?);
}
