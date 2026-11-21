//! The form of a `.fpp` file, which VS Code opens as `FortranFreeForm`
//! whatever its text and the compilers read as fixed form unless told
//! otherwise: zfls detects it, tells the editor (`zfls/sourceForm`), and
//! keeps a language the user then chooses (#632).

const std = @import("std");
const h = @import("harness.zig");

const fixed_fpp = h.File{ .name = "old.fpp", .text =
    \\C     a fixed-form file, preprocessed
    \\      SUBROUTINE OLD(X)
    \\      REAL X
    \\#ifdef DOUBLE
    \\      X = X +
    \\     &    2.0D0
    \\#else
    \\      X = X +
    \\     &    2.0
    \\#endif
    \\      END
    \\
};

const free_fpp = h.File{ .name = "new.fpp", .text =
    \\subroutine new(y)
    \\  real :: y
    \\  y = y + &
    \\      1.0
    \\end subroutine new
    \\
};

test "a fixed-form .fpp opened as FortranFreeForm is read as fixed form, and the editor told so" {
    const w = try h.Workspace.init(&.{ fixed_fpp, free_fpp }, .{});
    defer w.deinit();
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(try w.isFixed("old.fpp"), "old.fpp read as free form", .{});
    try w.expectNoDiagnostics("old.fpp");
    const symbols = try w.documentSymbols("old.fpp");
    try h.expect(symbols.len == 1 and std.mem.eql(u8, symbols[0], "OLD"), "symbols {any}", .{symbols});
    const told = try w.sentWith("zfls/sourceForm");
    try h.expect(told.len == 1 and std.mem.find(u8, told[0], "\"languageId\":\"FortranFixedForm\"") != null, "told {any}", .{told});
    // the extension's switch: closed and opened in the fixed form's
    // language, which is told nothing more
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFixedForm");
    try h.expect(try w.isFixed("old.fpp"), "old.fpp read as free form after the switch", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 1, "told again after the switch", .{});
    // the user's Change Language Mode: closed and opened at once in the
    // other language, which wins and is told nothing
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(!try w.isFixed("old.fpp"), "the user's free form is not kept", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 1, "told again after the user's choice", .{});
}

test "a free-form .fpp opened as FortranFreeForm stays free form, and nothing is told" {
    const w = try h.Workspace.init(&.{ fixed_fpp, free_fpp }, .{});
    defer w.deinit();
    try w.open("new.fpp", "FortranFreeForm");
    try h.expect(!try w.isFixed("new.fpp"), "new.fpp read as fixed form", .{});
    try w.expectNoDiagnostics("new.fpp");
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 0, "told of new.fpp", .{});
}
