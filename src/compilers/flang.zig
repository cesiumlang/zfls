//! LLVM Flang in the compiler check (compilers.zig): the options that
//! differ between its releases, and its messages.

const std = @import("std");
const compilers = @import("../compilers.zig");
const Parser = compilers.Parser;
const Severity = compilers.Severity;

/// How a fixed-form file's debug lines are read. Comments are Flang's
/// default, so that needs no option: Flang 20 has neither
/// `-fd-lines-as-comments` nor `-fd-lines-as-code` ("unknown argument"),
/// which Flang 21 added.
pub fn dLines(code: bool) []const []const u8 {
    return if (code) &.{"-fd-lines-as-code"} else &.{};
}

/// The messages of Flang's output
pub fn parse(p: *Parser, output: []const u8) !void {
    // `file:line:column: severity: message`, as clang; flang adds
    // context lines without a severity (`file:line:column: Declaration
    // of 'x'`), which belong to the message before them
    const r = try p.re("^(?P<file>.+?):(?P<ln>\\d+):(?P<cn>\\d+): (?:(?P<sev>fatal error|error|warning|portability|note|remark|because): )?(?P<msg>.*)$", .{});
    const summary = try p.re("^error: (?:Semantic errors in|Could not scan) ", .{});
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
            if (sev) |s| {
                const text_msg = if (std.mem.eql(u8, sev_text.?, "portability")) try p.a.print("portability: {s}", .{msg}) else msg;
                try p.push(m.named(r, "file"), ln, cn, s, text_msg, null);
            } else if (p.out.items.len > 0) {
                // a note, a "because" or a context line
                try p.out.items[p.out.items.len - 1].related.append(p.a, .{ .file = m.named(r, "file"), .line = ln, .column = cn, .message = std.mem.trim(u8, msg, " \t") });
            }
            continue;
        }
        // "error: Semantic errors in x.f90" repeats the messages above it
        if (summary.match(text) != null) continue;
        if (try p.driver(text)) continue;
        if (std.mem.startsWith(u8, text, "error: ")) try p.push(null, 0, null, .@"error", text["error: ".len..], null);
    }
}

test "debug lines: no option for comments, which Flang 20 rejects" {
    try std.testing.expectEqualStrings("-fd-lines-as-code", dLines(true)[0]);
    try std.testing.expectEqual(@as(usize, 0), dLines(false).len);
    const o: compilers.Options = .{ .windows = false, .mod_dir = "m" };
    try std.testing.expectEqual(@as(usize, 0), compilers.dLines(.flang, false, o).len);
    // gfortran rejects debug lines without an option
    try std.testing.expectEqualStrings("-fd-lines-as-comments", compilers.dLines(.gfortran, false, o)[0]);
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
