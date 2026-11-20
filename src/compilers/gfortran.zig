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

/// Splits gfortran's trailing `[-Wflag]` off into the code
fn message(p: *Parser, file: ?[]const u8, ln: usize, cn: ?usize, sev: []const u8, msg: []const u8) !void {
    const r = try p.re("\\s*\\[(-W[\\w=-]+)\\]$", .{});
    if (r.search(msg)) |m| {
        try p.push(file, ln, cn, severity(sev), msg[0..m.start(0)], m.group(1));
    } else try p.push(file, ln, cn, severity(sev), msg, null);
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
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        const text = compilers.trimCr(raw);
        if (one.match(text)) |m| {
            try message(p, m.named(one, "file"), compilers.num(m.named(one, "ln")), compilers.numOpt(m.named(one, "cn")), m.named(one, "sev").?, m.named(one, "msg").?);
            locus = null;
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
    try compilers.expectBrief(.gfortran, "main.f90:5:7:\r\n\r\n    5 |   i = j + 1\r\n      |       1\r\nError: Symbol 'j' at (1) has no IMPLICIT type\r\n" ++
        "C:\\src\\fixed.f:4:11:\r\n\r\n    4 |       i = q\r\n      |           1\r\nError: Symbol 'q' at (1) has no IMPLICIT type\r\n" ++
        "two.f90:8.13-15:\r\ntwo.f90:12:3:\r\nWarning: Type mismatch at (1) and (2)\r\n", &.{
        "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
        "C:\\src\\fixed.f:4:11 error: Symbol 'q' at (1) has no IMPLICIT type",
        "two.f90:8:13 warning: Type mismatch at (1) and (2)",
    });
}

test "gfortran driver messages" {
    try compilers.expectBrief(.gfortran,
        \\gfortran: error: unrecognized command-line option '-Wbogus'
        \\f951.exe: Warning: Nonexistent include directory 'nope' [-Wmissing-include-dirs]
    , &.{
        "-:0:- error: gfortran: unrecognized command-line option '-Wbogus'",
        "-:0:- warning: f951.exe: Nonexistent include directory 'nope' [-Wmissing-include-dirs]",
    });
}

test "gfortran's -Wtabs at the TAB-format line" {
    // MSYS2's gfortran 16.1, -Wall
    try compilers.expectBrief(.gfortran,
        \\f951.exe: Warning: Nonconforming tab character in column 1 of line 4 [-Wtabs]
        \\f951: Error: Nonconforming tab character in column 3 of line 6 [-Werror=tabs]
    , &.{
        "-:4:1 warning: Nonconforming tab character in column 1 of line 4 [-Wtabs]",
        "-:6:3 error: Nonconforming tab character in column 3 of line 6 [-Werror=tabs]",
    });
}
