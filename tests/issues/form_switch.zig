//! LLVM Flang's `!dir$ fixed` and `!dir$ free`, which switch the source
//! form of the lines after them (#387).

const std = @import("std");
const h = @import("harness.zig");

const free_file =
    \\module formsw2
    \\  implicit none
    \\contains
    \\!dir$ fixed
    \\      SUBROUTINE OLD(X)
    \\C     A COMMENT LINE CALL NOWHERE(Q)
    \\*     ANOTHER
    \\      IMPLICIT NONE
    \\      REAL X
    \\      X = X +
    \\     &    1.0 ! a comment
    \\      END SUBROUTINE
    \\!dir$ free
    \\  subroutine new(y)
    \\    real :: y
    \\    y = y + &
    \\        2.0
    \\  end subroutine
    \\end module
    \\
;

const fixed_file =
    \\      MODULE BACK
    \\      IMPLICIT NONE
    \\      CONTAINS
    \\      SUBROUTINE OLD(X)
    \\C     A COMMENT LINE CALL NOWHERE(Q)
    \\      REAL X
    \\      X = X +
    \\     &    1.0
    \\      END SUBROUTINE
    \\CDIR$ FREE
    \\subroutine new(y)
    \\  real :: y
    \\  y = y + &
    \\      2.0
    \\end subroutine
    \\!DIR$ FIXED
    \\      SUBROUTINE OLD2(Z)
    \\      REAL Z
    \\      Z = UNDECL
    \\      END SUBROUTINE
    \\      END MODULE
    \\
;

test "the fixed-form part of a free-form file, the free-form part of a fixed-form one" {
    const w = try h.Workspace.init(&.{
        .{ .name = "formsw2.f90", .text = free_file },
        .{ .name = "back.f", .text = fixed_file },
    }, .{});
    defer w.deinit();
    // the C and * lines are comments, the continuations continue
    try w.expectNoDiagnostics("formsw2.f90");
    const diags = try w.diagnostics("back.f");
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(i64, 18), diags[0].line);
    try std.testing.expectEqualStrings("Name \"UNDECL\" is not declared (IMPLICIT NONE)", diags[0].message);
    const symbols = try w.documentSymbols("back.f");
    for ([_][]const u8{ "OLD", "new", "OLD2" }) |name| {
        for (symbols) |s| {
            if (std.mem.eql(u8, s, name)) break;
        } else return error.TestUnexpectedResult;
    }
    // without the directive, the fixed-form lines are free-form ones
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, free_file, "!dir$ fixed", "!dir$ fixe");
    defer std.testing.allocator.free(edited);
    try w.replaceText("formsw2.f90", edited);
    var found = false;
    for (try w.diagnostics("formsw2.f90")) |d| if (std.mem.eql(u8, d.message, "Name \"COMMENT\" is not declared (IMPLICIT NONE)")) {
        found = true;
    };
    try std.testing.expect(found);
}
