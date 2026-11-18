//! Upstream issues about the structure of a file in the editor: the outline
//! (document symbols) and folding.

const std = @import("std");
const h = @import("harness.zig");

const source =
    \\module shapes
    \\  implicit none
    \\  real, parameter :: pi = 3.14159
    \\  integer :: count
    \\  type :: circle
    \\    real :: radius
    \\  contains
    \\    procedure :: area
    \\  end type circle
    \\  interface
    \\    subroutine ext(x)
    \\      real :: x
    \\    end subroutine ext
    \\  end interface
    \\contains
    \\  ! the area of
    \\  ! a circle
    \\  real function area(self)
    \\    class(circle), intent(in) :: self
    \\    area = pi*self%radius**2
    \\  end function area
    \\  subroutine grow(c, by)
    \\    type(circle), intent(inout) :: c
    \\    real, intent(in) :: by
    \\    if (by > 0) then
    \\      c%radius = c%radius + by
    \\    else if (by < 0) then
    \\      c%radius = c%radius - by
    \\    else
    \\      count = count + 1
    \\    end if
    \\#ifdef DEBUG
    \\    print *, c%radius
    \\#else
    \\    count = count + 1
    \\#endif
    \\  contains
    \\    subroutine log_it()
    \\    end subroutine log_it
    \\  end subroutine grow
    \\end module shapes
    \\
;

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn expectOutline(w: *h.Workspace) !void {
    const paths = try w.symbolPaths("shapes.f90");
    const expected = [_][]const u8{
        "shapes",             "shapes/pi",            "shapes/count",
        "shapes/circle",      "shapes/circle/radius", "shapes/circle/area",
        "shapes/ext",         "shapes/area",          "shapes/grow",
        "shapes/grow/log_it",
    };
    for (expected) |e| try h.expect(contains(paths, e), "no symbol {s}", .{e});
    // not the local variables of procedures
    try h.expect(!contains(paths, "shapes/grow/c"), "a local variable is in the outline", .{});
    try h.expect(paths.len == expected.len, "{d} symbols, not {d}", .{ paths.len, expected.len });
}

test "Modern Fortran #647 the outline is a tree, for breadcrumbs and sticky scroll" {
    const w = try h.Workspace.init(&.{.{ .name = "shapes.f90", .text = source }}, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try h.checkIn(.modern_fortran, 647, .fixed, expectOutline(w));
}

const namelist_source =
    \\! the run
    \\&run_params
    \\  steps = 100, dt = 1.0d-3 ! seconds
    \\  title = 'a = b / c', flags(1:2) = .true., .false.
    \\/
    \\$output
    \\  path = "out/"
    \\$end
    \\
;

/// The outline of the namelist documents, and nothing of Fortran: no
/// workspace file, no diagnostics, no messages
fn expectNamelistOutline(w: *h.Workspace) !void {
    // by its language, and by its name with any language
    try w.open("params.in", "FortranNamelist");
    try w.open("run.nml", "FortranFreeForm");
    const expected = [_][]const u8{
        "run_params", "run_params/steps", "run_params/dt", "run_params/title", "run_params/flags",
        "output",     "output/path",
    };
    for ([_][]const u8{ "params.in", "run.nml" }) |name| {
        const got = try w.symbolPaths(name);
        try h.expect(got.len == expected.len, "{s}: {d} symbols, not {d}", .{ name, got.len, expected.len });
        for (expected, got) |e, g| try h.expect(std.mem.eql(u8, e, g), "{s}: {s}, not {s}", .{ name, g, e });
        try h.expect(w.server.workspace.get(try w.path(name)) == null, "{s} is parsed as Fortran", .{name});
    }
    // its changes are followed
    try w.replaceText("run.nml", "&solo n = 1 /\n");
    const changed = try w.symbolPaths("run.nml");
    try h.expect(changed.len == 2 and std.mem.eql(u8, changed[1], "solo/n"), "{d} symbols after a change", .{changed.len});
    for (w.sent.items) |body| try h.expect(std.mem.find(u8, body, "publishDiagnostics") == null, "diagnostics published: {s}", .{body});
    try h.expect((try w.messages()).len == 0, "messages posted", .{});
}

test "Modern Fortran #1296 the outline of a namelist file: its groups and their variables" {
    const w = try h.Workspace.init(&.{
        .{ .name = "params.in", .text = namelist_source },
        .{ .name = "run.nml", .text = namelist_source },
    }, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try h.checkIn(.modern_fortran, 1296, .fixed, expectNamelistOutline(w));
    // and the flat list of a client without the tree
    const w2 = try h.Workspace.init(&.{.{ .name = "run.nml", .text = namelist_source }}, .{});
    defer w2.deinit();
    try w2.open("run.nml", "FortranNamelist");
    const names = try w2.documentSymbols("run.nml");
    try std.testing.expectEqual(@as(usize, 7), names.len);
    try std.testing.expectEqualStrings("steps", names[1]);
}

test "a client without hierarchical symbols gets fortls's flat list" {
    const w = try h.Workspace.init(&.{.{ .name = "shapes.f90", .text = source }}, .{});
    defer w.deinit();
    const names = try w.documentSymbols("shapes.f90");
    // fortls lists scopes and type members, not module variables, and not
    // the procedures contained in procedures
    try std.testing.expect(contains(names, "grow"));
    try std.testing.expect(contains(names, "radius"));
    try std.testing.expect(!contains(names, "pi"));
    try std.testing.expect(!contains(names, "log_it"));
}

fn expectFolds(w: *h.Workspace) !void {
    const folds = try w.foldingRanges("shapes.f90");
    const Want = struct { from: []const u8, to: []const u8 };
    // each from its first line to the line before its END (or the next
    // branch)
    const want = [_]Want{
        .{ .from = "module shapes", .to = "  end subroutine grow" },
        .{ .from = "  type :: circle", .to = "    procedure :: area" },
        .{ .from = "  ! the area of", .to = "  ! a circle" },
        .{ .from = "  real function area", .to = "    area = pi" },
        .{ .from = "  subroutine grow", .to = "    end subroutine log_it" },
        .{ .from = "    if (by > 0)", .to = "      c%radius = c%radius + by" },
        .{ .from = "    else if", .to = "      c%radius = c%radius - by" },
        .{ .from = "    else\n", .to = "      count = count + 1" },
        .{ .from = "#ifdef DEBUG", .to = "    print *" },
        .{ .from = "#else", .to = "    count = count + 1\n#endif" },
    };
    for (want) |x| {
        const start = w.pos("shapes.f90", x.from, 0, 0).line;
        const end = w.pos("shapes.f90", x.to, 0, 0).line;
        var found = false;
        for (folds) |f| if (f.start == start and f.end == end) {
            found = true;
        };
        try h.expect(found, "no folding range for lines {d}-{d} ({s})", .{ start + 1, end + 1, x.from });
    }
}

test "hansec #166 folding follows the program units, constructs and their branches" {
    const w = try h.Workspace.init(&.{.{ .name = "shapes.f90", .text = source }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 166, .fixed, expectFolds(w));
}

/// The folding ranges of a file as `start-end` pairs (0-based), in the
/// order the server gives them
fn foldPairs(w: *h.Workspace, name: []const u8) ![]const [2]i64 {
    var out: std.ArrayList([2]i64) = .empty;
    for (try w.foldingRanges(name)) |f| try out.append(w.arena.allocator(), .{ f.start, f.end });
    return out.items;
}

fn expectFoldPairs(w: *h.Workspace, name: []const u8, want: []const [2]i64) !void {
    const got = try foldPairs(w, name);
    std.testing.expectEqualSlices([2]i64, want, got) catch |e| {
        for (got) |g| std.debug.print("({d}, {d}) ", .{ g[0], g[1] });
        return e;
    };
}

test "a SELECT construct folds as a whole and branch by branch; continued statements fold (#275)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text =
        \\subroutine s(k, &
        \\             x, &
        \\             y)
        \\  integer :: k
        \\  real :: x, y
        \\  select case (k)
        \\  case (1)
        \\    x = 1
        \\    y = 1
        \\  case default
        \\    x = 2
        \\    y = 2
        \\  end select
        \\  if (k > 1) then
        \\    x = 3
        \\    y = 3
        \\  end if
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try expectFoldPairs(w, "s.f90", &.{ .{ 0, 16 }, .{ 5, 11 }, .{ 6, 8 }, .{ 9, 11 }, .{ 13, 15 } });
}

test "nested and named SELECT constructs, SELECT TYPE (#275)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text =
        \\subroutine s(k, j, v)
        \\  integer :: k, j
        \\  class(*) :: v
        \\  sel: select case (k)
        \\  case (1) sel
        \\    select case (j)
        \\    case (1)
        \\      k = 2
        \\    case default
        \\      k = 3
        \\    end select
        \\  case default sel
        \\    k = 4
        \\  end select sel
        \\  select type (v)
        \\  type is (integer)
        \\    k = v
        \\  class default
        \\    k = 0
        \\  end select
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try expectFoldPairs(w, "s.f90", &.{
        .{ 0, 19 },  .{ 3, 12 },  .{ 4, 10 },  .{ 5, 9 }, .{ 6, 7 }, .{ 8, 9 }, .{ 11, 12 },
        .{ 14, 18 }, .{ 15, 16 }, .{ 17, 18 },
    });
}

test "continued statements of three lines or more fold, comment lines between them included (#275)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text =
        \\subroutine s(k)
        \\  integer :: k
        \\  real :: a, &
        \\    ! a comment line in between
        \\          b, &
        \\          c
        \\  real :: d, &
        \\          e
        \\  if (k > 1) then
        \\    call t(a, &
        \\           b, &
        \\           c)
        \\  end if
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try expectFoldPairs(w, "s.f90", &.{ .{ 0, 12 }, .{ 2, 5 }, .{ 8, 11 }, .{ 9, 11 } });
}

test "continued statements in fixed form fold (#275)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f", .text =
        \\      SUBROUTINE S(K)
        \\      INTEGER K
        \\      CALL T(K,
        \\C     a comment line
        \\     &       K,
        \\     &       K)
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try expectFoldPairs(w, "s.f", &.{ .{ 0, 5 }, .{ 2, 5 } });
}
