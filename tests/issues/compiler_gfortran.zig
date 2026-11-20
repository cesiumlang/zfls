//! The compiler check (`compiler_diagnostics`) with gfortran's command
//! line, through a stand-in gfortran that logs its arguments: the files of
//! suffixes its driver does not know (#521), a missing `#include` (#524),
//! the messages without a file (#525), and a directory of .mod files for
//! each major version (#526).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in gfortran that appends its arguments to `gfortran.log` beside
/// it and gives a driver message, `gfortran: error: logged`
const fake: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho %* >> \"%~dp0gfortran.log\"\r\necho gfortran: error: logged 1>&2\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/gfortran.log\"\necho 'gfortran: error: logged' >&2\n" };

const module = h.File{ .name = "k.f18", .text = "module k\n  integer :: n\nend module k\n" };
const user = h.File{ .name = "u.f77", .text = "      program p\n      use k\n      n = 1\n      end program p\n" };

test "gfortran: the file and the modules it uses with -x f95 right before them, for any suffix (#521)" {
    const w = try h.Workspace.init(&.{ module, user, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    try w.open("u.f77", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"gfortran: logged\"", 60)) orelse return error.NoCompilerDiagnostics;
    const calls = try w.tmp.dir.readFileAlloc(io, "gfortran.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(calls);
    var it = std.mem.tokenizeAny(u8, calls, "\r\n");
    var files: usize = 0;
    while (it.next()) |call| {
        const line = std.mem.trimEnd(u8, call, " ");
        // the module, compiled first, then the file
        const file = if (std.mem.endsWith(u8, line, "k.f18")) "k.f18" else if (std.mem.endsWith(u8, line, "u.f77")) "u.f77" else continue;
        files += 1;
        // nothing but the file's path after it
        const x = std.mem.findLast(u8, line, " -x f95 ");
        if (x == null or std.mem.find(u8, line[x.? + " -x f95 ".len ..], " -") != null) {
            std.debug.print("\nno -x f95 before {s}: {s}\n", .{ file, line });
            return error.NoLanguage;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), files);
}

/// A stand-in gfortran that says what gfortran's cpp says of a missing
/// `#include` on line 3: on line 4
const missing_include: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho p.F90:4:2: Fatal Error: missing.h: No such file or directory 1>&2\r\necho compilation terminated. 1>&2\r\nexit /b 1\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\necho 'p.F90:4:2: Fatal Error: missing.h: No such file or directory' >&2\necho 'compilation terminated.' >&2\nexit 1\n" };

test "gfortran: a missing #include is on its line, not the next (#524)" {
    const pp = h.File{ .name = "p.F90", .text = "program p\n  implicit none\n#include \"missing.h\"\nend program p\n" };
    const w = try h.Workspace.init(&.{ pp, missing_include }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ missing_include.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, missing_include.name, .executable_file, .{});
    try w.open("p.F90", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"missing.h: No such file or directory\"", 60)) orelse return error.NoCompilerDiagnostics;
    const at = std.mem.find(u8, sent, "\"message\":\"missing.h: No such file or directory\"").?;
    const mark = "\"range\":{\"start\":{\"line\":";
    const r = std.mem.findLast(u8, sent[0..at], mark) orelse return h.unmet("no range in {s}", .{sent});
    try h.expect(std.mem.startsWith(u8, sent[r + mark.len ..], "2,"), "the missing #include is not on line 3: {s}", .{sent[r..at]});
}

/// A stand-in gfortran that gives what gfortran 16.1 says of a TAB-format
/// fixed-form file with -Wall, and of an include directory that is not
/// there: messages without a file and line
const tabs: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho f951.exe: Warning: Nonconforming tab character in column 1 of line 2 [-Wtabs] 1>&2\r\necho f951.exe: Warning: Nonexistent include directory 'nope' [-Wmissing-include-dirs] 1>&2\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\necho 'f951: Warning: Nonconforming tab character in column 1 of line 2 [-Wtabs]' >&2\necho \"f951: Warning: Nonexistent include directory 'nope' [-Wmissing-include-dirs]\" >&2\n" };

test "gfortran: -Wtabs of fixed form at the TAB's line, and the driver's warning option as its code (#525)" {
    const tab = h.File{ .name = "t.f", .text = "C     tab format\n\tPROGRAM T\n\tEND\n" };
    const w = try h.Workspace.init(&.{ tab, tabs }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ tabs.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, tabs.name, .executable_file, .{});
    try w.open("t.f", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "Nonexistent include directory", 60)) orelse return error.NoCompilerDiagnostics;
    const at = std.mem.find(u8, sent, "\"message\":\"Nonconforming tab character in column 1 of line 2\"") orelse return h.unmet("no -Wtabs message: {s}", .{sent});
    const mark = "\"range\":{\"start\":{\"line\":";
    const r = std.mem.findLast(u8, sent[0..at], mark) orelse return h.unmet("no range in {s}", .{sent});
    try h.expect(std.mem.startsWith(u8, sent[r + mark.len ..], "1,"), "the TAB warning is not on line 2: {s}", .{sent[r..at]});
    // the driver's message: its option is the code, not in the text
    try h.expect(std.mem.find(u8, sent, "include directory 'nope'\",") != null and std.mem.find(u8, sent, "\"code\":\"-Wmissing-include-dirs\"") != null, "the include directory warning: {s}", .{sent});
}

/// A stand-in gfortran of `version` that logs its arguments to
/// `gfortran.log` beside it and gives a driver message naming its version
fn versioned(comptime version: []const u8) h.File {
    return if (is_windows)
        .{ .name = "gfortran.cmd", .text = "@echo off\r\nif \"%1\"==\"--version\" (echo GNU Fortran ^(GCC^) " ++ version ++ "& exit /b 0)\r\necho %* >> \"%~dp0gfortran.log\"\r\necho gfortran: error: " ++ version ++ " 1>&2\r\n" }
    else
        .{ .name = "gfortran.sh", .text = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'GNU Fortran (GCC) " ++ version ++ "'; exit 0; fi\necho \"$@\" >> \"$(dirname \"$0\")/gfortran.log\"\necho 'gfortran: error: " ++ version ++ "' >&2\n" };
}

/// The `-J` directory of the last call logged in `gfortran.log`
fn lastModDir(w: *h.Workspace, a: std.mem.Allocator) ![]const u8 {
    const calls = try w.tmp.dir.readFileAlloc(io, "gfortran.log", a, .limited(1 << 20));
    var last: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, calls, "\r\n");
    while (it.next()) |call| {
        var words = std.mem.tokenizeScalar(u8, call, ' ');
        while (words.next()) |x| if (std.mem.startsWith(u8, x, "-J")) {
            last = std.mem.trim(u8, x[2..], "\"");
        };
    }
    return last orelse h.unmet("no -J in {s}", .{calls});
}

test "gfortran: the .mod files of each major version in a directory of their own (#526)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = comptime versioned("14.4.0");
    const w = try h.Workspace.init(&.{ module, user, old }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ old.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, old.name, .executable_file, .{});
    try w.open("u.f77", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"gfortran: 14.4.0\"", 60)) orelse return error.NoCompilerDiagnostics;
    const dir14 = try lastModDir(w, a);
    try h.expect(std.mem.endsWith(u8, dir14, "gfortran-14"), "gfortran 14's .mod files in {s}", .{dir14});
    // another gfortran at the same path: another directory
    const new = comptime versioned("15.3.0");
    try w.tmp.dir.writeFile(io, .{ .sub_path = new.name, .data = new.text });
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, new.name, .executable_file, .{});
    try w.save("u.f77");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"gfortran: 15.3.0\"", 60)) orelse return error.NoCompilerDiagnostics;
    const dir15 = try lastModDir(w, a);
    try h.expect(std.mem.endsWith(u8, dir15, "gfortran-15"), "gfortran 15's .mod files in {s}", .{dir15});
}
