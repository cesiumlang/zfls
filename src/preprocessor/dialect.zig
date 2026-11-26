//! How a compiler's preprocessor reads the condition of an `#if` or
//! `#elif` that zfls's takes (#658). zfls takes C's operators and
//! Fortran's (`.NE.`, `/=`), as LLVM Flang's preprocessor does; Intel's fpp
//! has no `/=`, gfortran's cpp none of Fortran's.

const std = @import("std");

pub const Dialect = enum {
    /// zfls's own, Flang's: C's operators and Fortran's
    any,
    /// Intel's fpp: no `/=`
    intel,
    /// gfortran's cpp: C's operators only
    gnu,
};

/// What a preprocessor does with a condition it cannot read: its message,
/// and whether it takes the branch
pub const Rejection = struct { message: []const u8, taken: bool };

/// How `dialect`'s preprocessor rejects condition `text`, if it does.
/// ifx 2026.2.0 `/fpp`: `#error: #if: parse error.` for `1 /= 2` (and
/// `(1 /= 2)`, `1 /= 2 && 1`), the branch taken, also for `1 /= 1`;
/// `.NE.`, `.AND.`, `.TRUE.` and `!=` it takes. gfortran 16.1 `-cpp`:
/// `token '/=' is not valid in preprocessor expressions` and `token '.' is
/// not valid ...` for `.NE.`, `.EQ.`, `.AND.`, `.LT.`, `.TRUE.`, the
/// branch not taken.
pub fn rejection(dialect: Dialect, text: []const u8) ?Rejection {
    const code = text;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (c == '"' or c == '\'') {
            i = std.mem.findScalarPos(u8, code, i + 1, c) orelse return null;
            continue;
        }
        if (c == '/' and i + 1 < code.len and code[i + 1] == '=') return switch (dialect) {
            .any => null,
            .intel => .{ .message = "#if: parse error.", .taken = true },
            .gnu => .{ .message = "token '/=' is not valid in preprocessor expressions", .taken = false },
        };
        if (dialect == .gnu and c == '.' and isFortranOperator(code[i..])) return .{ .message = "token '.' is not valid in preprocessor expressions", .taken = false };
    }
    return null;
}

/// Whether `text` starts with a dot operator: `.`, letters, `.`
fn isFortranOperator(text: []const u8) bool {
    var n: usize = 1;
    while (n < text.len and std.ascii.isAlphabetic(text[n])) n += 1;
    return n > 1 and n < text.len and text[n] == '.';
}

test "the conditions Intel's fpp and gfortran's cpp reject" {
    try std.testing.expect(rejection(.any, " 1 /= 2") == null);
    const i = rejection(.intel, " (1 /= 2)").?;
    try std.testing.expectEqualStrings("#if: parse error.", i.message);
    try std.testing.expect(i.taken);
    try std.testing.expect(rejection(.intel, " 1 .NE. 2 .AND. .TRUE.") == null);
    try std.testing.expect(rejection(.intel, " A != 2") == null);
    const g = rejection(.gnu, " 1 /= 2").?;
    try std.testing.expectEqualStrings("token '/=' is not valid in preprocessor expressions", g.message);
    try std.testing.expect(!g.taken);
    try std.testing.expectEqualStrings("token '.' is not valid in preprocessor expressions", rejection(.gnu, " 1 .lt. 2").?.message);
    try std.testing.expect(rejection(.gnu, " defined(A) && VER >= 2") == null);
}
