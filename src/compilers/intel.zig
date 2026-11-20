//! Intel's ifx and ifort in the compiler check (compilers.zig): what their
//! drivers need beyond the options of the other compilers, and their
//! messages.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const regex = @import("../regex.zig");
const paths = @import("../paths.zig");
const compilers = @import("../compilers.zig");
const Parser = compilers.Parser;
const Severity = compilers.Severity;

/// Before the file, as its language: the driver checks only `.f`, `.for`,
/// `.ftn`, `.fpp`, `.f90` (and `.F`, `.F90`), and takes a file of another
/// suffix (`.f95`, `.f03`, `.f08`, `.f18`, `.f23`, `.f77`, `.pf`) for an
/// object ("command line warning #10161: unrecognized source type ...;
/// object file assumed"), which it does not check. With `/Tf <file>` (`-Tf
/// <file>` on Linux) the file is Fortran source whatever its suffix; `/fpp`
/// still preprocesses it, and `/free` and `/fixed` still hold (ifx 2026.2).
pub fn language(o: compilers.Options) []const []const u8 {
    return if (o.windows) &.{"/Tf"} else &.{"-Tf"};
}

test "the file's language: /Tf or -Tf right before it for ifx and ifort" {
    const win: compilers.Options = .{ .windows = true, .mod_dir = "m" };
    const linux: compilers.Options = .{ .windows = false, .mod_dir = "m" };
    try std.testing.expectEqualStrings("/Tf", compilers.language(.ifx, win)[0]);
    try std.testing.expectEqualStrings("-Tf", compilers.language(.ifx, linux)[0]);
    try std.testing.expectEqualStrings("-Tf", compilers.language(.ifort, linux)[0]);
    try std.testing.expectEqual(@as(usize, 1), compilers.language(.ifort, win).len);
}

/// The directory of the intrinsic and Intel modules (`iso_fortran_env`,
/// `ifport`, `omp_lib`, ...) of an ifx that its driver does not look in:
/// conda-forge's, whose activation script adds it to `FFLAGS` (which zfls
/// does not run). Its `ifx.exe` is in `<prefix>\Library\bin`, the modules
/// in `<prefix>\opt\compiler\include\intel64`; on Linux `<prefix>/bin/ifx`
/// and `<prefix>/opt/compiler/include/intel64`. Null when the directory
/// beside the executable `exe` (a path) has neither `ifcore.mod` nor
/// `iso_fortran_env.modintr` (Intel's intrinsic modules).
pub fn moduleDir(io: Io, a: Allocator, exe: []const u8) !?[]const u8 {
    const bin = std.Io.Dir.path.dirname(exe) orelse return null;
    for ([_][]const u8{ "..", "../.." }) |up| {
        const dir = try std.Io.Dir.path.resolveAlloc(a, &.{ bin, up, "opt", "compiler", "include", "intel64" });
        for ([_][]const u8{ "ifcore.mod", "iso_fortran_env.modintr" }) |name| {
            if (paths.isFile(io, try std.Io.Dir.path.join(a, &.{ dir, name }))) return dir;
        }
    }
    return null;
}

fn severity(sev: []const u8) Severity {
    if (std.ascii.eqlIgnoreCase(sev, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(sev, "remark") or std.ascii.eqlIgnoreCase(sev, "info")) return .info;
    return .@"error";
}

/// The messages of ifx's and ifort's output
pub fn parse(p: *Parser, output: []const u8) !void {
    // `file(line): error #6404: message   [NAME]`, then the source line
    // and a caret line `-----^`; fpp prints `file(line): #error: message`
    const msg_re = try p.re("^(?P<file>.+?)\\((?P<ln>\\d+)\\): (?:#)?(?P<sev>catastrophic error|fatal error|error|warning|remark|info)(?: #(?P<code>\\d+))?: (?P<msg>.*)$", regex.I);
    const caret = try p.re("^(?P<dashes>[-.]*)\\^\\s*$", .{});
    // the driver's, with a number or without: `ifx: command line warning
    // #10006: ignoring unknown option '/Qbogus'`, `ifx: command line error:
    // Unrecognized keyword 'f99' for option '/stand'`, `ifx: error #10037:
    // could not find 'link.exe'`
    const drv = try p.re("^(?P<bin>ifx|ifort|icx)(?:\\.exe)?: (?:command line )?(?P<sev>error|warning|remark)(?: #(?P<code>\\d+))?: (?P<msg>.+)$", regex.I);
    // the compiler proper's (xfortcom; ifort's fortcom), without a
    // location, with the file it is about two lines later: `xfortcom:
    // Severe: No such file or directory`, ``, `... file is 'nothere.f90'`
    const front = try p.re("^(?P<bin>x?fortcom)(?:\\.exe)?: (?P<sev>Severe|Fatal|Error|Warning|Remark|Info): (?P<msg>.+)$", regex.I);
    const file_is = try p.re("^\\.\\.\\. file is '(?P<file>.*)'$", .{});
    var all: std.ArrayList([]const u8) = .empty;
    var it = compilers.lines(output);
    while (it.next()) |raw| try all.append(p.a, compilers.trimCr(raw));
    for (all.items, 0..) |text, i| {
        const m = msg_re.match(text) orelse {
            if (drv.match(text)) |d| {
                try p.push(null, 0, null, severity(d.named(drv, "sev").?), try p.a.print("{s}: {s}", .{ d.named(drv, "bin").?, d.named(drv, "msg").? }), d.named(drv, "code"));
            } else if (front.match(text)) |f| {
                var msg = f.named(front, "msg").?;
                for (all.items[i + 1 .. @min(i + 3, all.items.len)]) |next| if (file_is.match(next)) |fi| {
                    msg = try p.a.print("{s}: '{s}'", .{ msg, fi.named(file_is, "file").? });
                    break;
                };
                try p.push(null, 0, null, severity(f.named(front, "sev").?), try p.a.print("{s}: {s}", .{ f.named(front, "bin").?, msg }), null);
            }
            continue;
        };
        var column: ?usize = null;
        // the source line and the caret line follow the message
        var j = i + 1;
        while (j <= i + 2 and j < all.items.len) : (j += 1) {
            if (caret.match(all.items[j])) |c| {
                column = c.named(caret, "dashes").?.len + 1;
                break;
            }
            if (msg_re.match(all.items[j]) != null) break;
        }
        try p.push(m.named(msg_re, "file"), compilers.num(m.named(msg_re, "ln")), column, severity(m.named(msg_re, "sev").?), m.named(msg_re, "msg").?, m.named(msg_re, "code"));
    }
}

test "ifx and ifort messages" {
    try compilers.expectBrief(.ifx,
        \\test.f90(3): error #6404: This name does not have a type, and must have an explicit type.   [X]
        \\  x = 1
        \\--^
        \\C:\work\test.f90(7): warning #6717: This name has not been given an explicit type.   [Y]
        \\      y = 2
        \\------^
        \\test.f90(9): remark #7712: This variable has not been used.   [Z]
        \\test.f90(2): #error: unsupported configuration
        \\test.f90(12): catastrophic error: Too many errors, exiting
        \\compilation aborted for test.f90 (code 1)
    , &.{
        "test.f90:3:3 error: This name does not have a type, and must have an explicit type.   [X] [6404]",
        "C:\\work\\test.f90:7:7 warning: This name has not been given an explicit type.   [Y] [6717]",
        "test.f90:9:- info: This variable has not been used.   [Z] [7712]",
        "test.f90:2:- error: unsupported configuration",
        "test.f90:12:- error: Too many errors, exiting",
    });
}

test "ifx and ifort messages without a location: the driver's, with a number or without, and xfortcom's" {
    // ifx 2026.2.0 on Windows
    try compilers.expectBrief(.ifx,
        \\ifx: command line error: Unrecognized keyword 'f99' for option '/stand'
        \\ifx: command line error: target architecture triple setting of 'bogus' not supported with ifx; use the Intel(R) oneAPI DPC++/C++ Compiler with option '-fortlib'
        \\ifx: command line warning #10006: ignoring unknown option '/Qbogusopt'
        \\ifx: error #10037: could not find 'link.exe'
        \\xfortcom: Severe: No such file or directory
        \\
        \\... file is 'nothere.f90'
        \\fortcom: Warning: something else
    , &.{
        "-:0:- error: ifx: Unrecognized keyword 'f99' for option '/stand'",
        "-:0:- error: ifx: target architecture triple setting of 'bogus' not supported with ifx; use the Intel(R) oneAPI DPC++/C++ Compiler with option '-fortlib'",
        "-:0:- warning: ifx: ignoring unknown option '/Qbogusopt' [10006]",
        "-:0:- error: ifx: could not find 'link.exe' [10037]",
        "-:0:- error: xfortcom: No such file or directory: 'nothere.f90'",
        "-:0:- warning: fortcom: something else",
    });
}

test "conda-forge's ifx: its modules beside it, else none" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Windows's layout: <prefix>\Library\bin\ifx.exe, <prefix>\opt\...
    try tmp.dir.createDirPath(io, "win/Library/bin");
    try tmp.dir.createDirPath(io, "win/opt/compiler/include/intel64");
    try tmp.dir.writeFile(io, .{ .sub_path = "win/opt/compiler/include/intel64/iso_fortran_env.modintr", .data = "" });
    // Linux's: <prefix>/bin/ifx, <prefix>/opt/...
    try tmp.dir.createDirPath(io, "linux/bin");
    try tmp.dir.createDirPath(io, "linux/opt/compiler/include/intel64");
    try tmp.dir.writeFile(io, .{ .sub_path = "linux/opt/compiler/include/intel64/ifcore.mod", .data = "" });
    // an ifx without them there (Intel's installer's finds its own)
    try tmp.dir.createDirPath(io, "plain/bin");
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const win = (try moduleDir(io, a, try paths.join(a, &.{ dir, "win", "Library", "bin", "ifx.exe" }))).?;
    try std.testing.expectEqualStrings(try paths.join(a, &.{ dir, "win", "opt", "compiler", "include", "intel64" }), win);
    const linux = (try moduleDir(io, a, try paths.join(a, &.{ dir, "linux", "bin", "ifx" }))).?;
    try std.testing.expectEqualStrings(try paths.join(a, &.{ dir, "linux", "opt", "compiler", "include", "intel64" }), linux);
    try std.testing.expect((try moduleDir(io, a, try paths.join(a, &.{ dir, "plain", "bin", "ifx" }))) == null);
    try std.testing.expect((try moduleDir(io, a, "ifx")) == null);
}
