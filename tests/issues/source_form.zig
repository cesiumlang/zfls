//! The form of a `.fpp` file, which VS Code opens as `FortranFreeForm`
//! whatever its text and the compilers read as fixed form unless told
//! otherwise: zfls detects it, tells the editor (`zfls/sourceForm`), and
//! keeps a language the user then chooses (#632); a file association
//! (VS Code's `files.associations`) with a form's language is a lasting
//! choice, which zfls reads it in, detecting nothing (#686).

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

const legacy_fpp = h.File{ .name = "legacy/new.fpp", .text = free_fpp.text };
const upper_fpp = h.File{ .name = "UPPER.FPP", .text = fixed_fpp.text };

test "an association with a form's language is a lasting choice: no detection, nothing told (#686)" {
    const w = try h.Workspace.init(&.{ fixed_fpp, free_fpp }, .{ .init_options = "{\"file_associations\": {\"*.fpp\": \"FortranFreeForm\", \"*.md\": \"markdown\"}}" });
    defer w.deinit();
    // not open: read in the association's form too
    try h.expect(!try w.isFixed("old.fpp"), "old.fpp read as fixed form while closed", .{});
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(!try w.isFixed("old.fpp"), "old.fpp read as fixed form", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 0, "told of old.fpp", .{});
    // Change Language Mode on it: the user's, and nothing told
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFixedForm");
    try h.expect(try w.isFixed("old.fpp"), "the user's fixed form is not kept", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 0, "told after the user's choice", .{});
}

test "a pattern with a slash matches the path, the longest wins, and other files are detected (#686)" {
    const w = try h.Workspace.init(&.{ fixed_fpp, upper_fpp, legacy_fpp }, .{ .init_options = "{\"file_associations\": {\"**/legacy/*.fpp\": \"FortranFixedForm\", \"*.FPP\": \"FortranFreeForm\", \"o*.fpp\": \"plaintext\"}}" });
    defer w.deinit();
    try w.open("legacy/new.fpp", "FortranFixedForm");
    try h.expect(try w.isFixed("legacy/new.fpp"), "legacy/new.fpp read as free form", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 0, "told of legacy/new.fpp", .{});
    // in either letter case
    try h.expect(!try w.isFixed("UPPER.FPP"), "UPPER.FPP read as fixed form", .{});
    // the longest pattern that matches names no form: detected
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(try w.isFixed("old.fpp"), "old.fpp read as free form", .{});
    const told = try w.sentWith("zfls/sourceForm");
    try h.expect(told.len == 1 and std.mem.find(u8, told[0], "old.fpp") != null, "told {any}", .{told});
}

test "a change of the associations applies to the open documents (#686)" {
    const w = try h.Workspace.init(&.{ fixed_fpp, free_fpp }, .{});
    defer w.deinit();
    try w.open("old.fpp", "FortranFreeForm");
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFixedForm");
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 1, "not told once", .{});
    // an association: read in its form, the editor told
    try w.changeConfiguration("{\"zfls\": {\"file_associations\": {\"*.fpp\": \"FortranFreeForm\"}}}");
    try h.expect(!try w.isFixed("old.fpp"), "old.fpp read as fixed form with the association", .{});
    var told = try w.sentWith("zfls/sourceForm");
    try h.expect(told.len == 2 and std.mem.find(u8, told[1], "\"languageId\":\"FortranFreeForm\"") != null, "told {any}", .{told});
    // the extension's switch, which is told nothing more
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(!try w.isFixed("old.fpp"), "old.fpp read as fixed form after the switch", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 2, "told after the switch", .{});
    // the closed new.fpp is unchanged; without the association, old.fpp
    // is detected and told again
    try h.expect(!try w.isFixed("new.fpp"), "new.fpp read as fixed form", .{});
    try w.changeConfiguration("{\"zfls\": {\"file_associations\": {}}}");
    try h.expect(try w.isFixed("old.fpp"), "old.fpp read as free form without the association", .{});
    told = try w.sentWith("zfls/sourceForm");
    try h.expect(told.len == 3 and std.mem.find(u8, told[2], "\"languageId\":\"FortranFixedForm\"") != null, "told {any}", .{told});
}

test "re-indexing keeps the editor's form (#688)" {
    const f90 = h.File{ .name = "fixed.f90", .text = fixed_fpp.text };
    const w = try h.Workspace.init(&.{f90}, .{});
    defer w.deinit();
    try w.open("fixed.f90", "FortranFixedForm");
    try h.expect(try w.isFixed("fixed.f90"), "not fixed at open", .{});
    try w.changeConfiguration("{\"zfls\": {\"include_dirs\": [\"inc\"]}}");
    try h.expect(try w.isFixed("fixed.f90"), "not fixed after re-indexing", .{});
}

test "re-indexing keeps the user's choice for a .fpp (#688)" {
    const w = try h.Workspace.init(&.{ fixed_fpp, free_fpp }, .{});
    defer w.deinit();
    try w.open("old.fpp", "FortranFreeForm");
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFixedForm");
    // Change Language Mode to free form
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(!try w.isFixed("old.fpp"), "the user's free form is not kept", .{});
    try w.changeConfiguration("{\"zfls\": {\"include_dirs\": [\"inc\"]}}");
    try h.expect(!try w.isFixed("old.fpp"), "the user's free form is not kept after re-indexing", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 1, "told again after re-indexing", .{});
    // reopened in the user's language: still the user's
    try w.close("old.fpp");
    try w.open("old.fpp", "FortranFreeForm");
    try h.expect(!try w.isFixed("old.fpp"), "the user's free form is not kept when reopened", .{});
    try h.expect((try w.sentWith("zfls/sourceForm")).len == 1, "told when reopened", .{});
}
