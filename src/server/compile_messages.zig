//! The compiler's messages (compilers.zig) as diagnostics of the file
//! checked (compile.zig): their ranges, and a message about an included
//! file at the line that includes it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const str = @import("../str.zig");
const paths = @import("../paths.zig");
const compilers = @import("../compilers.zig");
const compile = @import("compile.zig");
const Job = compile.Job;
const comparable = compile.comparable;
const splitLines = compile.splitLines;

const is_windows = builtin.target.os.tag == .windows;

/// The range of a message at 1-based `line` and `column` (or the whole line
/// without one; an LFortran span when it has one)
pub fn rangeAt(lines: []const []const u8, line: usize, column: ?usize, end_line: ?usize, end_column: ?usize) lsp.Range {
    if (line == 0 or line > lines.len) return .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    const ln = line - 1;
    const text = lines[ln];
    const c = column orelse {
        const first = std.mem.findNone(u8, text, " \t") orelse 0;
        return .{ .start = .{ .line = ln, .character = str.byteToUtf16(text, first) }, .end = .{ .line = ln, .character = str.byteToUtf16(text, text.len) } };
    };
    const start = @min(c -| 1, text.len);
    if (end_line) |el| if (el >= line and el <= lines.len) {
        const end_text = lines[el - 1];
        const ec = @min(end_column orelse end_text.len, end_text.len);
        return .{ .start = .{ .line = ln, .character = str.byteToUtf16(text, start) }, .end = .{ .line = el - 1, .character = str.byteToUtf16(end_text, ec) } };
    };
    // the name that has the column, else one character: gfortran's column
    // is the last letter of the name in many messages ("Symbol 'x' at (1)
    // has no IMPLICIT type"), the others' its first
    var begin = start;
    var end = start;
    if (start < text.len and isNameChar(text[start])) {
        while (begin > 0 and isNameChar(text[begin - 1])) begin -= 1;
        while (end < text.len and isNameChar(text[end])) end += 1;
    } else end = @min(start + 1, text.len);
    return .{ .start = .{ .line = ln, .character = str.byteToUtf16(text, begin) }, .end = .{ .line = ln, .character = str.byteToUtf16(text, end) } };
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether a message's file is the file checked (`here`: its names, as
/// `comparable`); a message without a file is about it. Intel's fpp names
/// a file by its name only (`ppinc.F90(5): #error: ...`), also when it is
/// given the file's path, and Intel's compilers run in a directory of
/// zfls's (`compilers.writesToWorkDir`): a name without a directory is the
/// file checked when it is the name of the file.
pub fn isHere(a: Allocator, job: *const Job, here: []const []const u8, file: ?[]const u8) !bool {
    const named = try comparable(a, job.cwd, file orelse return true);
    for (here) |h| if (std.mem.eql(u8, named, h)) return true;
    if (compilers.writesToWorkDir(job.id) and std.mem.findAny(u8, file.?, "/\\") == null) {
        const base = std.Io.Dir.path.basename(named);
        for (here) |h| if (std.mem.eql(u8, std.Io.Dir.path.basename(h), base)) return true;
    }
    return false;
}

/// A further location of a message, one character at its line and column
fn relatedInfo(a: Allocator, job: *const Job, r: compilers.Related) !lsp.DiagnosticRelatedInformation {
    const rpath = if (r.file) |f| (if (std.Io.Dir.path.isAbsolute(f)) f else try paths.join(a, &.{ job.cwd, f })) else job.path;
    const rl = r.line -| 1;
    const rc = (r.column orelse 1) -| 1;
    return .{
        .location = .{ .uri = try paths.pathToUri(a, try paths.normpath(a, rpath)), .range = .{ .start = .{ .line = rl, .character = rc }, .end = .{ .line = rl, .character = rc + 1 } } },
        .message = r.message,
    };
}

/// The line of the `#include` of a file that is not found, when the message
/// names the line after it: gfortran's (its cpp's) `missing.h: No such file
/// or directory` does (GCC 9 to 16). Null for any other message.
fn missingInclude(lines: []const []const u8, m: compilers.Message) ?usize {
    const suffix = ": No such file or directory";
    if (!std.mem.endsWith(u8, m.message, suffix) or m.line < 2 or m.line - 1 > lines.len) return null;
    const name = m.message[0 .. m.message.len - suffix.len];
    if (name.len == 0 or !includes(lines[m.line - 2], name)) return null;
    // the message's own line includes it: it is right
    if (m.line <= lines.len and includes(lines[m.line - 1], name)) return null;
    return m.line - 1;
}

/// Whether `line` is an `#include` of `name` (`"name"` or `<name>`)
fn includes(line: []const u8, name: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0 or t[0] != '#') return false;
    const rest = std.mem.trimStart(u8, t[1..], " \t");
    if (!std.mem.startsWith(u8, rest, "include")) return false;
    const arg = std.mem.trim(u8, rest["include".len..], " \t");
    if (arg.len < 2) return false;
    const close: u8 = switch (arg[0]) {
        '"' => '"',
        '<' => '>',
        else => return false,
    };
    const end = std.mem.findScalarPos(u8, arg, 1, close) orelse return false;
    return std.mem.eql(u8, arg[1..end], name);
}

/// The compiler's messages as diagnostics of the file, which they may name
/// as any of `aliases` (the file, its copy, fypp's output)
pub fn toDiagnostics(a: Allocator, job: *const Job, text: []const u8, msgs: []const compilers.Message, aliases: []const []const u8) ![]const lsp.Diagnostic {
    const lines = try splitLines(a, text);
    var here: std.ArrayList([]const u8) = .empty;
    for (aliases) |p| try here.append(a, try comparable(a, job.cwd, p));
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    for (msgs) |m| {
        const ours = try isHere(a, job, here.items, m.file);
        // a missing #include, on its line rather than the next (gfortran)
        const moved = if (ours) missingInclude(lines, m) else null;
        // a message in an included file, at the line that includes it
        const site = if (ours) null else if (m.include_site) |s| (if (try isHere(a, job, here.items, s.file)) s else null) else null;
        var related: std.ArrayList(lsp.DiagnosticRelatedInformation) = .empty;
        // its place in that file first
        if (site != null) try related.append(a, try relatedInfo(a, job, .{ .file = m.file, .line = m.line, .column = m.column, .message = m.message }));
        for (m.related.items) |r| try related.append(a, try relatedInfo(a, job, r));
        // a message about another file (an included one): at the line that
        // includes it or else at the top, with its location
        const message = if (ours) m.message else try a.print("{s}:{d}: {s}", .{ m.file.?, m.line, m.message });
        try out.append(a, .{
            .range = if (moved) |l| rangeAt(lines, l, null, null, null) else if (ours) rangeAt(lines, m.line, m.column, m.end_line, m.end_column) else if (site) |s| rangeAt(lines, s.line, null, null, null) else rangeAt(lines, 0, null, null, null),
            .message = message,
            .severity = m.severity.lsp(),
            .code = m.code,
            .source = @tagName(job.id),
            .relatedInformation = if (related.items.len > 0) related.items else null,
        });
    }
    return out.items;
}

/// A module the file uses whose file did not compile: the file (`path`,
/// compiled in `cwd`), the modules it defines (in lower case), and the
/// compiler's first error about it
pub const FailedDependency = struct {
    path: []const u8,
    cwd: []const u8,
    modules: []const []const u8,
    first: compilers.Message,
};

/// `diags` with the first error of each module file that did not compile
/// (`failed`) given to the messages about its modules: those that mention
/// "module" and one of its modules' names, such as gfortran's "Cannot open
/// module file 'shapes.mod' for reading", which hides the cause (#546). The
/// error becomes their related information, and their text says which
/// file did not compile.
pub fn relateFailed(a: Allocator, diags: []const lsp.Diagnostic, failed: []const FailedDependency) ![]const lsp.Diagnostic {
    if (failed.len == 0) return diags;
    const out = try a.dupe(lsp.Diagnostic, diags);
    for (out) |*d| {
        if (std.ascii.findIgnoreCase(d.message, "module") == null) continue;
        for (failed) |f| {
            if (!mentionsAny(d.message, f.modules)) continue;
            var related: std.ArrayList(lsp.DiagnosticRelatedInformation) = .empty;
            if (d.relatedInformation) |r| try related.appendSlice(a, r);
            const named = f.first.file orelse f.path;
            const file = if (std.Io.Dir.path.isAbsolute(named)) named else try paths.join(a, &.{ f.cwd, named });
            const line = f.first.line -| 1;
            const col = (f.first.column orelse 1) -| 1;
            const base = std.Io.Dir.path.basename(f.path);
            try related.append(a, .{
                .location = .{ .uri = try paths.pathToUri(a, try paths.normpath(a, file)), .range = .{ .start = .{ .line = line, .character = col }, .end = .{ .line = line, .character = col + 1 } } },
                .message = try a.print("{s} did not compile: {s}", .{ base, f.first.message }),
            });
            d.relatedInformation = related.items;
            d.message = try a.print("{s} ({s} did not compile)", .{ d.message, base });
        }
    }
    return out;
}

/// Whether `text` has one of `names` (lower case) as a word, in any case
fn mentionsAny(text: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        var i: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, i, n)) |at| : (i = at + 1) {
            const before_ok = at == 0 or !isNameChar(text[at - 1]);
            const after = at + n.len;
            if (before_ok and (after == text.len or !isNameChar(text[after]))) return true;
        }
    }
    return false;
}

test "a module file that did not compile: its first error with the messages about its module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = if (is_windows) "C:\\w" else "/w";
    const path = try paths.join(a, &.{ cwd, "main.f90" });
    const job: Job = .{ .arena = arena, .uri = "", .path = path, .id = .gfortran, .exes = &.{}, .compiler_path = null, .cwd = cwd, .deps = &.{}, .deps_fixed = &.{}, .deps_cwd = &.{}, .args = &.{}, .fixed = false, .work_dir = cwd };
    // MSYS2's gfortran 16.1: shapes.f90, then main.f90, which uses shapes
    const dep = try compilers.parse(a, .gfortran, "shapes.f90:11:43: Error: Symbol 'undeclared_in_module' at (1) has no IMPLICIT type\n");
    const msgs = try compilers.parse(a, .gfortran,
        \\main.f90:2:7: Fatal Error: Cannot open module file 'shapes.mod' for reading at (1): No such file or directory
        \\compilation terminated.
    );
    const text = "program main\n  use shapes\n  implicit none\nend program main\n";
    const ds = try toDiagnostics(a, &job, text, msgs, &.{path});
    const failed = [_]FailedDependency{.{ .path = try paths.join(a, &.{ cwd, "shapes.f90" }), .cwd = cwd, .modules = &.{"shapes"}, .first = dep[0] }};
    const got = try relateFailed(a, ds, &failed);
    try std.testing.expectEqualStrings("Cannot open module file 'shapes.mod' for reading at (1): No such file or directory (shapes.f90 did not compile)", got[0].message);
    const rel = got[0].relatedInformation.?;
    try std.testing.expectEqual(@as(usize, 1), rel.len);
    try std.testing.expect(std.mem.endsWith(u8, rel[0].location.uri, "/shapes.f90"));
    try std.testing.expectEqual(@as(usize, 10), rel[0].location.range.start.line);
    try std.testing.expectEqual(@as(usize, 42), rel[0].location.range.start.character);
    try std.testing.expectEqualStrings("shapes.f90 did not compile: Symbol 'undeclared_in_module' at (1) has no IMPLICIT type", rel[0].message);
    // a message about another module, or not about a module: unchanged
    const other = [_]FailedDependency{.{ .path = "x.f90", .cwd = cwd, .modules = &.{"shape"}, .first = dep[0] }};
    try std.testing.expectEqual(@as(?[]const lsp.DiagnosticRelatedInformation, null), (try relateFailed(a, ds, &other))[0].relatedInformation);
    try std.testing.expect(mentionsAny("Error in opening the compiled module file.  [KMOD]", &.{"kmod"}));
    try std.testing.expect(!mentionsAny("module kmodx", &.{"kmod"}));
}

test "ranges: the name at the column, the whole line, a span" {
    const lines = [_][]const u8{ "program p", "  x = 1 + yy", "end" };
    const r = rangeAt(&lines, 2, 11, null, null);
    try std.testing.expectEqual(@as(usize, 10), r.start.character);
    try std.testing.expectEqual(@as(usize, 12), r.end.character);
    const whole = rangeAt(&lines, 2, null, null, null);
    try std.testing.expectEqual(@as(usize, 2), whole.start.character);
    try std.testing.expectEqual(@as(usize, 12), whole.end.character);
    const span = rangeAt(&lines, 1, 1, 3, 3);
    try std.testing.expectEqual(@as(usize, 2), span.end.line);
    try std.testing.expectEqual(@as(usize, 3), span.end.character);
    const none = rangeAt(&lines, 0, null, null, null);
    try std.testing.expectEqual(@as(usize, 0), none.end.character);
    // not a name: one character
    const plus = rangeAt(&lines, 2, 7, null, null);
    try std.testing.expectEqual(@as(usize, 6), plus.start.character);
    try std.testing.expectEqual(@as(usize, 7), plus.end.character);
}

test "ranges: gfortran's column, the last letter of a name, is the whole name" {
    // MSYS2's gfortran 16.1 (and Nix's 9.5 to 15.3): fxcol.f90:3:19 and
    // fxcol.f:3:23, "Symbol 'longname' at (1) has no IMPLICIT type"
    const free = [_][]const u8{ "program fxc", "  implicit none", "  print *, longname, b" };
    const r = rangeAt(&free, 3, 19, null, null);
    try std.testing.expectEqual(@as(usize, 11), r.start.character);
    try std.testing.expectEqual(@as(usize, 19), r.end.character);
    // "Symbol 'b'": 3:22
    const b = rangeAt(&free, 3, 22, null, null);
    try std.testing.expectEqual(@as(usize, 21), b.start.character);
    try std.testing.expectEqual(@as(usize, 22), b.end.character);
    const fixed = [_][]const u8{ "      program fxc", "      implicit none", "      print *, longname, b" };
    const f = rangeAt(&fixed, 3, 23, null, null);
    try std.testing.expectEqual(@as(usize, 15), f.start.character);
    try std.testing.expectEqual(@as(usize, 23), f.end.character);
    // the first letter, as the other compilers give it: the same
    const first = rangeAt(&free, 3, 12, null, null);
    try std.testing.expectEqual(@as(usize, 11), first.start.character);
    try std.testing.expectEqual(@as(usize, 19), first.end.character);
}

test "a message in an included file: at the line that includes it, its place related" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = if (is_windows) "C:\\w" else "/w";
    const path = try paths.join(a, &.{ cwd, "nest.f90" });
    const job: Job = .{ .arena = arena, .uri = "", .path = path, .id = .flang, .exes = &.{}, .compiler_path = null, .cwd = cwd, .deps = &.{}, .deps_fixed = &.{}, .deps_cwd = &.{}, .args = &.{}, .fixed = false, .work_dir = cwd };
    // Flang 23.1.5's output for an INCLUDE of an INCLUDE
    const msgs = try compilers.parse(a, .flang,
        \\error: Semantic errors in nest.f90
        \\inc/bad.inc:2:7: error: No explicit type declared for 'undeclared_in_inc'
        \\    q = undeclared_in_inc
        \\        ^^^^^^^^^^^^^^^^^
        \\inc/outer.inc:1:1: error: included here
        \\    include 'bad.inc'
        \\  ^^^^^^^^^^^^^^^^^^^
        \\nest.f90:3:1: error: included here
        \\    include 'outer.inc'
        \\  ^^^^^^^^^^^^^^^^^^^^^
    );
    const text = "program n\n  implicit none\n  include 'outer.inc'\n  print *, q\nend program n\n";
    const ds = try toDiagnostics(a, &job, text, msgs, &.{path});
    try std.testing.expectEqual(@as(usize, 1), ds.len);
    try std.testing.expectEqualStrings("inc/bad.inc:2: No explicit type declared for 'undeclared_in_inc'", ds[0].message);
    // the INCLUDE line, from its keyword
    try std.testing.expectEqual(@as(usize, 2), ds[0].range.start.line);
    try std.testing.expectEqual(@as(usize, 2), ds[0].range.start.character);
    try std.testing.expectEqual(@as(usize, 21), ds[0].range.end.character);
    const rel = ds[0].relatedInformation.?;
    try std.testing.expectEqual(@as(usize, 2), rel.len);
    try std.testing.expect(std.mem.endsWith(u8, rel[0].location.uri, "/inc/bad.inc"));
    try std.testing.expectEqual(@as(usize, 1), rel[0].location.range.start.line);
    try std.testing.expectEqual(@as(usize, 6), rel[0].location.range.start.character);
    try std.testing.expectEqualStrings("No explicit type declared for 'undeclared_in_inc'", rel[0].message);
    try std.testing.expect(std.mem.endsWith(u8, rel[1].location.uri, "/inc/outer.inc"));
    try std.testing.expectEqualStrings("included here", rel[1].message);
}

test "gfortran: a missing #include is at its line, not the next" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = if (is_windows) "C:\\w" else "/w";
    const path = try paths.join(a, &.{ cwd, "ppinc.F90" });
    const job: Job = .{ .arena = arena, .uri = "", .path = path, .id = .gfortran, .exes = &.{}, .compiler_path = null, .cwd = cwd, .deps = &.{}, .deps_fixed = &.{}, .deps_cwd = &.{}, .args = &.{}, .fixed = false, .work_dir = cwd };
    const text = "program ppinc\n  implicit none\n#include \"inc/bad.inc\"\n#ifdef FOO\n#error FOO must not be set\n#endif\n#include \"missing.h\"\n  print *, q\nend program\n";
    // MSYS2's gfortran 16.1 (and Nix's 9.5 to 15.3) with -DFOO: the
    // #include of line 7 is reported on line 8; #error on its own line
    const msgs = try compilers.parse(a, .gfortran,
        \\ppinc.F90:5:2: Error: #error FOO must not be set
        \\ppinc.F90:8:2: Fatal Error: missing.h: No such file or directory
        \\compilation terminated.
    );
    const ds = try toDiagnostics(a, &job, text, msgs, &.{path});
    try std.testing.expectEqual(@as(usize, 2), ds.len);
    try std.testing.expectEqual(@as(usize, 4), ds[0].range.start.line);
    try std.testing.expectEqualStrings("missing.h: No such file or directory", ds[1].message);
    try std.testing.expectEqual(@as(usize, 6), ds[1].range.start.line);
    try std.testing.expectEqual(@as(usize, 0), ds[1].range.start.character);
    try std.testing.expectEqual(@as(usize, 20), ds[1].range.end.character);
    // the same message on the #include's own line, or after a line that
    // includes another file: where it is
    const lines = try splitLines(a, text);
    try std.testing.expectEqual(@as(?usize, null), missingInclude(lines, .{ .file = null, .line = 7, .column = 2, .severity = .@"error", .message = "missing.h: No such file or directory" }));
    try std.testing.expectEqual(@as(?usize, null), missingInclude(lines, .{ .file = null, .line = 4, .column = 2, .severity = .@"error", .message = "missing.h: No such file or directory" }));
    try std.testing.expect(includes("  # include <x/y.h>", "x/y.h") and !includes("#include \"x.h", "x.h") and !includes("! #include \"x.h\"", "x.h"));
}

test "fpp's messages, which name the file by its name only, are about the file checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (is_windows) "C:\\w" else "/w";
    const path = try paths.join(a, &.{ root, "src", "ppinc.F90" });
    // Intel's compilers run in a directory of zfls's
    const cwd = try paths.join(a, &.{ root, "cache", "run" });
    const job: Job = .{ .arena = arena, .uri = "", .path = path, .id = .ifx, .exes = &.{}, .compiler_path = null, .cwd = cwd, .deps = &.{}, .deps_fixed = &.{}, .deps_cwd = &.{}, .args = &.{}, .fixed = false, .work_dir = cwd };
    // ifx 2026.2.0 /fpp on Windows, given the file's absolute path
    const output = "ppinc.F90(5): #error:  FOO must not be set\r\n\r\nppinc.F90(7): #error: can't find include file: missing.h\r\n" ++
        (if (is_windows) "C:\\w\\src\\ppinc.F90" else "/w/src/ppinc.F90") ++ "(9): error #6404: This name does not have a type, and must have an explicit type.   [UNDECLARED_PP]\r\n  undeclared_pp = 3\r\n--^\r\n" ++
        "other.F90(2): #error: not this file\r\n";
    const msgs = try compilers.parse(a, .ifx, output);
    const text = "program ppinc\n  implicit none\n#include \"inc/bad.inc\"\n#ifdef FOO\n#error FOO must not be set\n#endif\n#include \"missing.h\"\n  ok_inc = 2\n  undeclared_pp = 3\nend program\n";
    const ds = try toDiagnostics(a, &job, text, msgs, &.{path});
    try std.testing.expectEqual(@as(usize, 4), ds.len);
    try std.testing.expectEqualStrings("FOO must not be set", ds[0].message);
    try std.testing.expectEqual(@as(usize, 4), ds[0].range.start.line);
    try std.testing.expectEqualStrings("can't find include file: missing.h", ds[1].message);
    try std.testing.expectEqual(@as(usize, 6), ds[1].range.start.line);
    try std.testing.expectEqual(@as(usize, 8), ds[2].range.start.line);
    // another file's name: at the top, with its name
    try std.testing.expectEqual(@as(usize, 0), ds[3].range.start.line);
    try std.testing.expectEqualStrings("other.F90:2: not this file", ds[3].message);
    // gfortran runs in the file's directory, where a name is a file there
    var gjob = job;
    gjob.id = .gfortran;
    gjob.cwd = try paths.join(a, &.{ root, "src" });
    const gds = try toDiagnostics(a, &gjob, text, try compilers.parse(a, .gfortran, "ppinc.F90:5:2: Error: #error FOO must not be set\n"), &.{path});
    try std.testing.expectEqual(@as(usize, 4), gds[0].range.start.line);
}
