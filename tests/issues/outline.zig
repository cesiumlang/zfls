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
