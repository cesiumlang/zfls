//! GNU gfortran in the compiler check (compilers.zig): what its driver
//! needs beyond the options of the other compilers, and its messages.

const std = @import("std");
const compilers = @import("../compilers.zig");
const Parser = compilers.Parser;
const Severity = compilers.Severity;

/// Before the file, as its language: the driver knows only `.f`, `.for`,
/// `.ftn`, `.fpp`, `.f90`, `.f95`, `.f03` and `.f08` (in either case), and
/// takes a file of another suffix (`.f77`, `.f18`, `.f23`, `.pf`, `.cuf`)
/// for a linker input, which it does not check ("linker input file unused
/// because linking not done"). With `-x f95`, `-cpp` still preprocesses
/// and `-ffixed-form`/`-ffree-form` still hold (GCC 9 to 16).
pub const language: []const []const u8 = &.{ "-x", "f95" };

test "the file's language: -x f95 for gfortran" {
    const o: compilers.Options = .{ .windows = false, .mod_dir = "m" };
    try std.testing.expectEqualStrings("-x", compilers.language(.gfortran, o)[0]);
    try std.testing.expectEqualStrings("f95", compilers.language(.gfortran, o)[1]);
    try std.testing.expectEqual(@as(usize, 2), compilers.language(.gfortran, .{ .windows = true, .mod_dir = "m" }).len);
}

fn severity(sev: []const u8) Severity {
    if (std.ascii.eqlIgnoreCase(sev, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(sev, "note") or std.ascii.eqlIgnoreCase(sev, "remark")) return .info;
    return .@"error";
}

/// Splits gfortran's trailing `[-Wflag]` off into the code: the warning's
/// option, also when `-Werror` makes it an error (`[-Werror=conversion]`
/// is `-Wconversion`)
fn message(p: *Parser, file: ?[]const u8, ln: usize, cn: ?usize, sev: []const u8, msg: []const u8) !void {
    const r = try p.re("\\s*\\[(-W[\\w=-]+)\\]$", .{});
    if (r.search(msg)) |m| {
        const flag = m.group(1).?;
        const code = if (std.mem.startsWith(u8, flag, "-Werror=")) try p.a.print("-W{s}", .{flag["-Werror=".len..]}) else flag;
        try p.push(file, ln, cn, severity(sev), msg[0..m.start(0)], code);
    } else try p.push(file, ln, cn, severity(sev), msg, null);
}

/// Whether a message's text is only a place's number, `(1)` or `(2)`: the
/// first line of a message about two places
fn isPlace(msg: []const u8) bool {
    const t = std.mem.trim(u8, msg, " \t");
    if (t.len < 3 or t[0] != '(' or t[t.len - 1] != ')') return false;
    for (t[1 .. t.len - 1]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The other place of the message just pushed, as its related information
fn attachPlace(p: *Parser, place: *?compilers.Related) !void {
    const r = place.* orelse return;
    place.* = null;
    try p.out.items[p.out.items.len - 1].related.append(p.a, r);
}

/// The messages of gfortran's output
pub fn parse(p: *Parser, output: []const u8) !void {
    // `file:line:column: Severity: message`, as printed with
    // -fno-diagnostics-show-caret
    const one = try p.re("^(?P<file>.+?):(?P<ln>\\d+):(?:(?P<cn>\\d+):)? (?P<sev>Fatal Error|Error|Warning|Note|Remark): (?P<msg>.*)$", .{});
    // the caret format: a locus line `file:line:column:` (or with a
    // range, `file:line.column-end:`), the source excerpt, and later
    // `Severity: message`
    const locus_re = try p.re("^(?P<file>.+?):(?P<ln>\\d+)[:.](?P<cn>\\d+)(?:-\\d+)?:$", .{});
    const sev_re = try p.re("^(?P<sev>Fatal Error|Error|Warning|Note|Remark): (?P<msg>.*)$", .{});
    // -Wtabs (in -Wall), at a TAB-format line: a line of the file read,
    // which it does not name
    const tab_re = try p.re("^[\\w.+-]+: (?P<sev>Warning|Error): (?P<msg>Nonconforming tab character in column (?P<cn>\\d+) of line (?P<ln>\\d+).*)$", .{});
    var locus: ?struct { file: []const u8, ln: usize, cn: usize } = null;
    // A message about two places comes as two lines in the one-line format
    // (GCC 10 to 16): first the place `(1)`, as a message whose text is
    // only `(1)`, then the message at the other place. The first becomes
    // the related information of the second.
    var place: ?compilers.Related = null;
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        // (without trailing blanks, which a script standing for gfortran
        // may add)
        const text = std.mem.trimEnd(u8, compilers.trimCr(raw), " \t");
        if (one.match(text)) |m| {
            const msg = m.named(one, "msg").?;
            locus = null;
            if (isPlace(msg)) {
                // a third place: the one before is a message of its own
                if (place) |r| try p.push(r.file, r.line, r.column, .@"error", r.message, null);
                place = .{ .file = m.named(one, "file"), .line = compilers.num(m.named(one, "ln")), .column = compilers.numOpt(m.named(one, "cn")), .message = std.mem.trim(u8, msg, " \t") };
                continue;
            }
            try message(p, m.named(one, "file"), compilers.num(m.named(one, "ln")), compilers.numOpt(m.named(one, "cn")), m.named(one, "sev").?, msg);
            try attachPlace(p, &place);
            continue;
        }
        if (locus_re.match(text)) |m| {
            // a second locus of the same message ("at (1) and (2)")
            // keeps the first
            if (locus == null) locus = .{ .file = m.named(locus_re, "file").?, .ln = compilers.num(m.named(locus_re, "ln")), .cn = compilers.num(m.named(locus_re, "cn")) };
            continue;
        }
        if (sev_re.match(text)) |m| {
            try message(p, if (locus) |l| l.file else null, if (locus) |l| l.ln else 0, if (locus) |l| l.cn else null, m.named(sev_re, "sev").?, m.named(sev_re, "msg").?);
            locus = null;
            continue;
        }
        if (tab_re.match(text)) |m| {
            try message(p, null, compilers.num(m.named(tab_re, "ln")), compilers.numOpt(m.named(tab_re, "cn")), m.named(tab_re, "sev").?, m.named(tab_re, "msg").?);
            continue;
        }
        _ = try p.driver(text);
    }
    // a place with no message after it: as it came
    if (place) |r| try p.push(r.file, r.line, r.column, .@"error", r.message, null);
}

test "gfortran one-line messages" {
    try compilers.expectBrief(.gfortran,
        \\main.f90:5:7: Error: Symbol 'j' at (1) has no IMPLICIT type
        \\inc.h:2:21: Error: Symbol 'undefined_thing' at (1) has no IMPLICIT type
        \\warn.f90:6:16: Warning: Unused variable 'unused' declared at (1) [-Wunused-variable]
        \\usem.f90:2:7: Fatal Error: Cannot open module file 'nonexistent_mod.mod' for reading at (1): No such file or directory
        \\compilation terminated.
    , &.{
        "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
        "inc.h:2:21 error: Symbol 'undefined_thing' at (1) has no IMPLICIT type",
        "warn.f90:6:16 warning: Unused variable 'unused' declared at (1) [-Wunused-variable]",
        "usem.f90:2:7 error: Cannot open module file 'nonexistent_mod.mod' for reading at (1): No such file or directory",
    });
}

test "gfortran caret format" {
    // MSYS2's gfortran 16.1 without -fno-diagnostics-show-caret (GCC 10 to
    // 15 print the same): a message about two places has one locus line
    // and the excerpts of both
    try compilers.expectBrief(.gfortran, "main.f90:5:7:\r\n\r\n    5 |   i = j + 1\r\n      |       1\r\nError: Symbol 'j' at (1) has no IMPLICIT type\r\n" ++
        "C:\\src\\fixed.f:4:11:\r\n\r\n    4 |       i = q\r\n      |           1\r\nError: Symbol 'q' at (1) has no IMPLICIT type\r\n" ++
        "two.f90:4:11:\r\n\r\n    3 |   call sub(1.0)\r\n      |           2\r\n    4 |   call sub(2)\r\n      |           1\r\n" ++
        "Error: Type mismatch between actual argument at (1) and actual argument at (2) (INTEGER(4)/REAL(4)).\r\n", &.{
        "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
        "C:\\src\\fixed.f:4:11 error: Symbol 'q' at (1) has no IMPLICIT type",
        "two.f90:4:11 error: Type mismatch between actual argument at (1) and actual argument at (2) (INTEGER(4)/REAL(4)).",
    });
}

test "gfortran: a message about two places, its place (1) related" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // MSYS2's gfortran 16.1 (and Nix's 10.5 to 15.3) on `call sub(1.0)`
    // (line 3), then `call sub(2)`; GCC 9 says nothing
    const ms = try compilers.parse(a, .gfortran,
        \\two.f90:4:11: Error: (1)
        \\two.f90:3:11: Error: Type mismatch between actual argument at (1) and actual argument at (2) (INTEGER(4)/REAL(4)).
        \\main.f90:5:7: Error: Symbol 'j' at (1) has no IMPLICIT type
        \\last.f90:2:1: Warning: (2)
    );
    const got = try compilers.brief(a, ms);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("two.f90:3:11 error: Type mismatch between actual argument at (1) and actual argument at (2) (INTEGER(4)/REAL(4)).", got[0]);
    try std.testing.expectEqual(@as(usize, 1), ms[0].related.items.len);
    const r = ms[0].related.items[0];
    try std.testing.expectEqualStrings("two.f90", r.file.?);
    try std.testing.expectEqual(@as(usize, 4), r.line);
    try std.testing.expectEqual(@as(?usize, 11), r.column);
    try std.testing.expectEqualStrings("(1)", r.message);
    // the next message has no place of its own
    try std.testing.expectEqual(@as(usize, 0), ms[1].related.items.len);
    // a place with nothing after it stays a message
    try std.testing.expectEqualStrings("last.f90:2:1 error: (2)", got[2]);
    try std.testing.expect(isPlace(" (12) ") and !isPlace("()") and !isPlace("(1) x"));
}

test "gfortran driver messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // MSYS2's gfortran 16.1
    const ms = try compilers.parse(a, .gfortran,
        \\gfortran: error: unrecognized command-line option '-Wbogus'
        \\f951.exe: Warning: Nonexistent include directory 'nope' [-Wmissing-include-dirs]
    );
    try std.testing.expectEqual(@as(usize, 2), ms.len);
    try std.testing.expectEqualStrings("gfortran: unrecognized command-line option '-Wbogus'", ms[0].message);
    try std.testing.expectEqual(@as(?[]const u8, null), ms[0].code);
    // the warning's option is its code, not in its text
    try std.testing.expectEqualStrings("f951.exe: Nonexistent include directory 'nope'", ms[1].message);
    try std.testing.expectEqualStrings("-Wmissing-include-dirs", ms[1].code.?);
    try std.testing.expectEqual(compilers.Severity.warning, ms[1].severity);
}

test "gfortran's -Wtabs at the TAB-format line" {
    // MSYS2's gfortran 16.1, -Wall
    try compilers.expectBrief(.gfortran,
        \\f951.exe: Warning: Nonconforming tab character in column 1 of line 4 [-Wtabs]
        \\f951: Error: Nonconforming tab character in column 3 of line 6 [-Werror=tabs]
    , &.{
        "-:4:1 warning: Nonconforming tab character in column 1 of line 4 [-Wtabs]",
        "-:6:3 error: Nonconforming tab character in column 3 of line 6 [-Wtabs]",
    });
}

test "gfortran: the code of a warning made an error by -Werror is the warning's" {
    // MSYS2's gfortran 16.1 (and Nix's 9.5 to 15.3), -Wall -Werror
    try compilers.expectBrief(.gfortran,
        \\warn.f90:6:6: Error: Possible change of value in conversion from REAL(4) to INTEGER(4) at (1) [-Werror=conversion]
        \\f951.exe: all warnings being treated as errors
    , &.{
        "warn.f90:6:6 error: Possible change of value in conversion from REAL(4) to INTEGER(4) at (1) [-Wconversion]",
    });
}
