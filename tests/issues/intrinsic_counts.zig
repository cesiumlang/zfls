//! The number of arguments and the keywords of calls of any intrinsic
//! function (#877), read from the M_intrinsics synopses and checked against
//! gfortran 16.1 (the counts of src/argcheck/_test/intrinsic_arity.zig),
//! Flang 23.1.5 and ifx 2026.2.0: all three reject each call below.

const std = @import("std");
const h = @import("harness.zig");

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, "intrinsic-arguments")) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

fn expectAll(got: []const []const u8, want: []const []const u8) !void {
    if (want.len != got.len) {
        for (got) |g| std.debug.print("got: {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "argument counts and keywords of intrinsics that had none checked" {
    inline for ([_][]const u8{ "neutral", "gfortran", "ifx", "flang" }) |d| {
        const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
            \\program p
            \\  implicit none
            \\  real :: x, y, a(3)
            \\  integer :: i
            \\  character(len=3) :: s
            \\  i = index(s)
            \\  i = index(s, s, .true., 4, 5)
            \\  i = len()
            \\  i = size(a, 1, 4, 5)
            \\  x = sqrt(x, y)
            \\  x = abs(b=x)
            \\  x = atan(x, y, x)
            \\  i = nint(x, 4, 4)
            \\  x = hypot(x)
            \\  i = ichar()
            \\  x = dot_product(a)
            \\  x = product()
            \\end program
            \\
        }}, .{ .init_options = "{\"lint_dialect\": \"" ++ d ++ "\"}" });
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &.{
            "6: too few arguments in the call of intrinsic index",
            "7: too many arguments in the call of intrinsic index",
            "8: too few arguments in the call of intrinsic len",
            "9: too many arguments in the call of intrinsic size",
            "10: too many arguments in the call of intrinsic sqrt",
            "11: intrinsic abs has no argument named b",
            "12: too many arguments in the call of intrinsic atan",
            "13: too many arguments in the call of intrinsic nint",
            "14: too few arguments in the call of intrinsic hypot",
            "15: too few arguments in the call of intrinsic ichar",
            "16: too few arguments in the call of intrinsic dot_product",
            "17: too few arguments in the call of intrinsic product",
        });
    }
}

test "valid calls, and names the program defines, are not reported" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  function scan(a, b, c, d, e)
        \\    integer :: scan, a, b, c, d, e
        \\    scan = a
        \\  end function
        \\end module
        \\program p
        \\  use m
        \\  implicit none
        \\  real :: x, y, a(3), b(2, 2)
        \\  integer :: i
        \\  character(len=3) :: s
        \\  i = index(s, 'a') + index(s, 'a', back=.true.) + index(string=s, substring='b', kind=4)
        \\  i = size(a) + size(a, 1) + size(a, dim=1, kind=8) + size(array=a)
        \\  x = atan(x) + atan(y, x) + atan(y=x, x=y) + hypot(x, y) + sqrt(x)
        \\  x = sum(a) + sum(a, 1) + sum(a, dim=1, mask=a > 0.0) + sum(array=a)
        \\  x = maxval(a) + maxval(a, 1, a > 0.0) + minval(a, mask=a > 0.0) + product(a)
        \\  x = max(x, y) + min(x, y, 3.0, 4.0, 5.0)
        \\  i = scan(1, 2, 3, 4, 5) + scan(s, 'a') * 0
        \\  b = reshape(a, [2, 2], order=[2, 1], pad=[0.0])
        \\  x = real(i) + real(i, 8) + real(i, kind=8) + dble(x) + cmplx(x, y, 8) + merge(x, y, i > 0)
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{});
}
