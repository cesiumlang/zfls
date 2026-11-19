//! LLVM Flang in the compiler check (compilers.zig): the options that
//! differ between its releases, and its messages.

const std = @import("std");
const compilers = @import("../compilers.zig");
const Parser = compilers.Parser;
const Severity = compilers.Severity;

/// How a fixed-form file's debug lines are read. Comments are Flang's
/// default, so that needs no option: Flang 20 has neither
/// `-fd-lines-as-comments` nor `-fd-lines-as-code` ("unknown argument"),
/// which Flang 21 added. A Flang known (`version`) to be older reads them
/// as comments whatever zfls does: an option would only fail every check.
pub fn dLines(code: bool, version: ?u32) []const []const u8 {
    if (version) |v| if (v < 21) return &.{};
    return if (code) &.{"-fd-lines-as-code"} else &.{};
}

/// The warnings on by default (when `compiler_args` and the file's command
/// give none), the nearest to gfortran's `-Wall`: Flang 22 and later. Flang
/// 21 knows neither ("Unknown diagnostic option"), Flang 20 has only
/// `-Werror`, and `-Wall` is never one of Flang's ("argument unused").
/// None when the version is not known.
pub fn warnings(version: ?u32) []const []const u8 {
    const v = version orelse return &.{};
    return if (v >= 22) &.{ "-Wunused-variable", "-Wused-undefined-variable" } else &.{};
}

/// The major version in `flang --version`'s output: `flang version
/// 23.1.5`, `flang-new version 19.1.7`, `Homebrew flang version 21.1.0`;
/// null for another compiler's (classic Flang's says `clang version`)
pub fn parseVersion(output: []const u8) ?u32 {
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        const line = compilers.trimCr(raw);
        for ([_][]const u8{ "flang version ", "flang-new version " }) |mark| {
            const at = std.mem.find(u8, line, mark) orelse continue;
            if (at > 0 and line[at - 1] != ' ') continue;
            const rest = line[at + mark.len ..];
            var end: usize = 0;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            if (end == 0) continue;
            return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
        }
    }
    return null;
}

test "flang's version, and what depends on it" {
    try std.testing.expectEqual(@as(?u32, 23), parseVersion("flang version 23.1.5\r\nTarget: x86_64-pc-windows-msvc\r\nThread model: posix\r\n"));
    try std.testing.expectEqual(@as(?u32, 19), parseVersion("flang-new version 19.1.7 (https://github.com/llvm/llvm-project cd70802)\nTarget: x86_64-unknown-linux-gnu\n"));
    try std.testing.expectEqual(@as(?u32, 21), parseVersion("Homebrew flang version 21.1.0\n"));
    try std.testing.expectEqual(@as(?u32, 20), parseVersion("Ubuntu flang version 20.1.2 (1ubuntu1)\n"));
    try std.testing.expectEqual(@as(?u32, null), parseVersion("clang version 7.0.1 (classic flang)\n"));
    try std.testing.expectEqual(@as(?u32, null), parseVersion("myflang version 3\n"));
    try std.testing.expectEqual(@as(?u32, null), parseVersion(""));
    try std.testing.expectEqual(@as(usize, 2), warnings(22).len);
    try std.testing.expectEqualStrings("-Wused-undefined-variable", warnings(23)[1]);
    try std.testing.expectEqual(@as(usize, 0), warnings(21).len);
    try std.testing.expectEqual(@as(usize, 0), warnings(null).len);
    // as the compiler check's defaults
    const o22: compilers.Options = .{ .windows = false, .mod_dir = "m", .version = 22 };
    try std.testing.expectEqualStrings("-Wunused-variable", compilers.defaultArgs(.flang, o22)[0]);
    try std.testing.expectEqual(@as(usize, 0), compilers.defaultArgs(.flang, .{ .windows = false, .mod_dir = "m" }).len);
    try std.testing.expectEqual(@as(usize, 0), compilers.dLines(.flang, true, .{ .windows = false, .mod_dir = "m", .version = 20 }).len);
    // Flang 20 has no -fd-lines-as-code
    try std.testing.expectEqual(@as(usize, 0), dLines(true, 20).len);
    try std.testing.expectEqualStrings("-fd-lines-as-code", dLines(true, 21)[0]);
    try std.testing.expectEqualStrings("-fd-lines-as-code", dLines(true, null)[0]);
}

/// Before the file, as its language: the driver knows only `.f`, `.for`,
/// `.fpp`, `.f90`, `.f95`, `.f03` and `.f08` (in either case), and takes a
/// file of another suffix (`.cuf`, `.f77`, `.ftn`, `.f18`, `.pf`) for a
/// linker input, which it does not check ("'linker' input unused"). With
/// `-x f95`, `-cpp` still preprocesses, the form options still hold, and
/// `.cuf` is still CUDA Fortran (Flang 20 to 23).
pub const language: []const []const u8 = &.{ "-x", "f95" };

/// The messages of Flang's output
pub fn parse(p: *Parser, output: []const u8) !void {
    // `file:line:column: severity: message`, as clang; flang adds
    // context lines without a severity (`file:line:column: Declaration
    // of 'x'`), which belong to the message before them
    const r = try p.re("^(?P<file>.+?):(?P<ln>\\d+):(?P<cn>\\d+): (?:(?P<sev>fatal error|error|warning|portability|note|remark|because): )?(?P<msg>.*)$", .{});
    const summary = try p.re("^error: (?:Semantic errors in|Could not scan|Could not parse) ", .{});
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        const text = compilers.trimCr(raw);
        if (r.match(text)) |m| {
            const sev_text = m.named(r, "sev");
            const sev: ?Severity = if (sev_text) |s|
                (if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "fatal error")) .@"error" else if (std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "portability")) .warning else if (std.mem.eql(u8, s, "remark")) .info else null)
            else
                null;
            const ln = compilers.num(m.named(r, "ln"));
            const cn = compilers.num(m.named(r, "cn"));
            const msg = m.named(r, "msg").?;
            if (sev != null and p.out.items.len > 0 and std.mem.eql(u8, std.mem.trim(u8, msg, " \t"), "included here")) {
                // where the message before's file is included: an include
                // between it and the file checked becomes related
                const last = &p.out.items[p.out.items.len - 1];
                if (last.include_site) |inner| try last.related.append(p.a, inner);
                last.include_site = .{ .file = m.named(r, "file"), .line = ln, .column = cn, .message = "included here" };
            } else if (sev) |s| {
                const text_msg = if (std.mem.eql(u8, sev_text.?, "portability")) try p.a.print("portability: {s}", .{msg}) else msg;
                try p.push(m.named(r, "file"), ln, cn, s, text_msg, null);
            } else if (p.out.items.len > 0) {
                // a note, a "because" or a context line
                try p.out.items[p.out.items.len - 1].related.append(p.a, .{ .file = m.named(r, "file"), .line = ln, .column = cn, .message = std.mem.trim(u8, msg, " \t") });
            }
            continue;
        }
        // "error: Semantic errors in x.f90" (or "Could not scan", "Could
        // not parse") sums up the messages after it
        if (summary.match(text) != null) continue;
        if (try p.driver(text)) continue;
        if (std.mem.startsWith(u8, text, "error: ")) try p.push(null, 0, null, .@"error", text["error: ".len..], null);
    }
}

test "debug lines: no option for comments, which Flang 20 rejects" {
    try std.testing.expectEqualStrings("-fd-lines-as-code", dLines(true, null)[0]);
    try std.testing.expectEqual(@as(usize, 0), dLines(false, null).len);
    const o: compilers.Options = .{ .windows = false, .mod_dir = "m" };
    try std.testing.expectEqual(@as(usize, 0), compilers.dLines(.flang, false, o).len);
    // gfortran rejects debug lines without an option
    try std.testing.expectEqualStrings("-fd-lines-as-comments", compilers.dLines(.gfortran, false, o)[0]);
}

test "the file's language: -x f95 for flang only" {
    try std.testing.expectEqualStrings("-x", compilers.language(.flang)[0]);
    try std.testing.expectEqualStrings("f95", compilers.language(.flang)[1]);
    try std.testing.expectEqual(@as(usize, 0), compilers.language(.gfortran).len);
}

test "flang's summary of a syntax error is no message of its own" {
    // Flang 23.1.5 on Windows; Flang 20 to 22 print the same lines
    try compilers.expectBrief(.flang,
        \\error: Could not parse C:\w\parse.f90
        \\C:\w\parse.f90:5:16: error: expected end of statement
        \\      print *, i +
        \\                 ^
        \\C:\w\parse.f90:5:5: in the context: execution part construct
        \\      print *, i +
        \\      ^
        \\C:\w\parse.f90:4:3: in the context: DO construct
        \\    do i = 1, 3
        \\    ^
        \\error: Could not scan C:\w\ppinc.F90
        \\C:\w\ppinc.F90:1:10: error: #include: Source file 'bad.inc' was not found
        \\  #include "bad.inc"
        \\           ^^^^^^^^^
    , &.{
        "C:\\w\\parse.f90:5:16 error: expected end of statement",
        "C:\\w\\ppinc.F90:1:10 error: #include: Source file 'bad.inc' was not found",
    });
}

test "flang: \"included here\" is where the message's file is included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Flang 23.1.5 on Windows; Flang 20 to 22 print the same lines
    const ms = try compilers.parse(a, .flang,
        \\inc\warn.inc:1:14: warning: Value of local variable 'unused_v' is never used [-Wunused-variable]
        \\    integer :: unused_v
        \\               ^^^^^^^^
        \\winc.f90:3:1: warning: included here
        \\    include 'warn.inc'
        \\  ^^^^^^^^^^^^^^^^^^^^
        \\error: Could not parse pinc.F90
        \\inc\perr.inc:1:14: error: expected end of statement
        \\pinc.F90:4:1: error: included here
        \\inc\perr.inc:1:3: in the context: execution part construct
        \\pinc.F90:4:1: in the context: included here
        \\pinc.F90:1:1: in the context: main program
    );
    const got = try compilers.brief(a, ms);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("inc\\warn.inc:1:14 warning: Value of local variable 'unused_v' is never used [-Wunused-variable]", got[0]);
    try std.testing.expectEqualStrings("inc\\perr.inc:1:14 error: expected end of statement", got[1]);
    try std.testing.expectEqualStrings("winc.f90", ms[0].include_site.?.file.?);
    try std.testing.expectEqual(@as(usize, 3), ms[0].include_site.?.line);
    try std.testing.expectEqual(@as(usize, 4), ms[1].include_site.?.line);
    // the context lines stay with the message
    try std.testing.expectEqual(@as(usize, 3), ms[1].related.items.len);
    try std.testing.expectEqualStrings("in the context: execution part construct", ms[1].related.items[0].message);
}

test "flang messages and their context lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out =
        \\error: Semantic errors in test.f90
        \\./test.f90:3:3: error: No explicit type declared for 'x'
        \\    x = 1
        \\    ^
        \\./test.f90:5:7: error: 'y' is already declared in this scoping unit
        \\    real :: y
        \\            ^
        \\./test.f90:4:14: Previous declaration of 'y'
        \\./test.f90:8:1: portability: nonstandard usage: tab character
        \\./test.f90:9:3: warning: Variable 'z' is used but never defined [-Wused-undefined-variable]
        \\flang: error: unknown argument: '-Wbogus'
    ;
    const ms = try compilers.parse(a, .flang, out);
    const want = [_][]const u8{
        "./test.f90:3:3 error: No explicit type declared for 'x'",
        "./test.f90:5:7 error: 'y' is already declared in this scoping unit",
        "./test.f90:8:1 warning: portability: nonstandard usage: tab character",
        "./test.f90:9:3 warning: Variable 'z' is used but never defined [-Wused-undefined-variable]",
        "-:0:- error: flang: unknown argument: '-Wbogus'",
    };
    const got = try compilers.brief(a, ms);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expectEqual(@as(usize, 1), ms[1].related.items.len);
    try std.testing.expectEqualStrings("Previous declaration of 'y'", ms[1].related.items[0].message);
    try std.testing.expectEqual(@as(usize, 4), ms[1].related.items[0].line);
}
