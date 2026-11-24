//! Part of the compiler check (compile.zig): where a message about an
//! included file goes in the file checked. ifx, ifort and gfortran name
//! only the included file (`inc/bad.inc(2): error #6404: …`,
//! `inc/bad.inc:2:3: Error: …`), not the line that includes it, which
//! Flang prints ("included here", `compilers.Message.include_site`). That
//! line is the INCLUDE statement or `#include` directive of the file
//! checked that names the file, or that names a file which includes it.
//! gfortran's `-Wtabs` names no file at all ("Nonconforming tab character
//! in column 1 of line 2"): when the file checked has no TAB there, the
//! file is the first included one that has (#586).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const paths = @import("../paths.zig");
const patterns = @import("../patterns.zig");
const compilers = @import("../compilers.zig");
const compile = @import("compile.zig");
const messages = @import("compile_messages.zig");
const fsio = @import("../fsio.zig");

const is_windows = builtin.target.os.tag == .windows;

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// How deep includes are followed
const max_depth = 8;

/// The file that `line` includes (`#include` or INCLUDE), as it names it
pub fn named(line: []const u8) ?[]const u8 {
    if (R().INCLUDE_DIRECTIVE.match(line)) |m| return m.group(1);
    if (R().INCLUDE.match(line)) |m| return m.group(1);
    return null;
}

/// The directories of the include options of `args` (`-Idir`, `-I dir`,
/// on Windows also `/Idir`, `/I dir`), relative to `cwd`
pub fn includeDirs(a: Allocator, cwd: []const u8, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const prefixes: []const []const u8 = if (is_windows) &.{ "-I", "/I" } else &.{"-I"};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        const dir = for (prefixes) |p| {
            if (!std.mem.startsWith(u8, x, p)) continue;
            if (x.len > p.len) break x[p.len..];
            if (i + 1 < args.len) {
                i += 1;
                break args[i];
            }
        } else continue;
        try out.append(a, if (std.Io.Dir.path.isAbsolute(dir)) dir else try paths.join(a, &.{ cwd, dir }));
    }
    return out.items;
}

/// The file that an include of `name` in a file of directory `dir` reads:
/// in `dir`, else in the first of `dirs` that has it
fn resolve(a: Allocator, io: Io, name: []const u8, dir: []const u8, dirs: []const []const u8) !?[]const u8 {
    if (std.Io.Dir.path.isAbsolute(name)) return if (paths.isFile(io, name)) name else null;
    const here = try paths.join(a, &.{ dir, name });
    if (paths.isFile(io, here)) return here;
    for (dirs) |d| {
        const p = try paths.join(a, &.{ d, name });
        if (paths.isFile(io, p)) return p;
    }
    return null;
}

/// Whether the message's file `file` (as the compiler named it, relative
/// to `cwd` or to a directory it searched) is `path`
fn isFile(a: Allocator, cwd: []const u8, file: []const u8, path: []const u8) !bool {
    const p = try compile.comparable(a, cwd, path);
    if (std.mem.eql(u8, try compile.comparable(a, cwd, file), p)) return true;
    if (std.Io.Dir.path.isAbsolute(file)) return false;
    // `inc\bad.inc`, `bad.inc`: relative to the including file, or found
    // in an include directory
    const tail = try a.dupe(u8, file);
    if (is_windows) for (tail) |*c| {
        c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    };
    const sep: u8 = if (is_windows) '\\' else '/';
    return p.len > tail.len and std.mem.endsWith(u8, p, tail) and p[p.len - tail.len - 1] == sep;
}

const Hop = struct { file: []const u8, line: usize };

/// The line (1-based) of `lines`, the lines of a file in directory `dir`,
/// that includes `file`, directly or through the files it includes (whose
/// lines that do are appended to `via`, innermost first); `found`: where
/// `file` is, when it is found
fn find(a: Allocator, io: Io, cwd: []const u8, lines: []const []const u8, dir: []const u8, dirs: []const []const u8, file: []const u8, via: *std.ArrayList(Hop), found: *?[]const u8, depth: usize) !?usize {
    for (lines, 0..) |l, i| {
        const name = named(l) orelse continue;
        const resolved = try resolve(a, io, name, dir, dirs);
        if (try isFile(a, cwd, file, resolved orelse name)) {
            found.* = resolved;
            return i + 1;
        }
    }
    if (depth >= max_depth) return null;
    for (lines, 0..) |l, i| {
        const name = named(l) orelse continue;
        const p = (try resolve(a, io, name, dir, dirs)) orelse continue;
        const text = fsio.readFile(io, a, p, .limited(16 * 1024 * 1024)) catch continue;
        const inner = try compile.splitLines(a, text);
        if (try find(a, io, cwd, inner, paths.dirname(p), dirs, file, via, found, depth + 1)) |n| {
            try via.append(a, .{ .file = p, .line = n });
            return i + 1;
        }
    }
    return null;
}

/// Gives each message about another file than the one checked (`job`'s
/// file, named as any of `aliases`, as in `isHere`) that has no
/// `include_site` the line of the file checked (its lines `lines`) that
/// includes it, and the lines of the files in between as related
/// information ("included here"). The included files are looked for as the
/// compilers do: beside the including file, then in the include
/// directories of `job.args`.
pub fn fill(a: Allocator, io: Io, job: *const compile.Job, lines: []const []const u8, aliases: []const []const u8, msgs: []compilers.Message) !void {
    var here: std.ArrayList([]const u8) = .empty;
    for (aliases) |p| try here.append(a, try compile.comparable(a, job.cwd, p));
    var dirs: ?[]const []const u8 = null;
    for (msgs) |*m| {
        if (m.include_site != null) continue;
        if (m.file == null and job.id == .gfortran and isTabWarning(m.message)) {
            if (m.line == 0 or m.column == null or hasTab(lines, m.line, m.column.?)) continue;
            if (dirs == null) dirs = try includeDirs(a, job.cwd, job.args);
            var via: std.ArrayList(Hop) = .empty;
            var found: ?[]const u8 = null;
            const line = (try findTab(a, io, lines, paths.dirname(job.path), dirs.?, m.line, m.column.?, &via, &found, 0)) orelse continue;
            m.file = found;
            m.include_site = .{ .file = job.path, .line = line, .column = null, .message = "included here" };
            for (via.items) |v| try m.related.append(a, .{ .file = v.file, .line = v.line, .column = null, .message = "included here" });
            continue;
        }
        const file = m.file orelse continue;
        if (try messages.isHere(a, job, here.items, file)) continue;
        if (dirs == null) dirs = try includeDirs(a, job.cwd, job.args);
        var via: std.ArrayList(Hop) = .empty;
        var found: ?[]const u8 = null;
        const line = (try find(a, io, job.cwd, lines, paths.dirname(job.path), dirs.?, file, &via, &found, 0)) orelse continue;
        // the file where it is, which a name relative to an include
        // directory (gfortran's `bad.inc`) does not say
        if (found) |f| m.file = f;
        m.include_site = .{ .file = job.path, .line = line, .column = null, .message = "included here" };
        for (via.items) |v| try m.related.append(a, .{ .file = v.file, .line = v.line, .column = null, .message = "included here" });
    }
}

/// gfortran's `-Wtabs` warning (or error, with `-Werror`)
fn isTabWarning(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "Nonconforming tab character in column ");
}

/// Whether line `line` of `lines` has a TAB in column `column` (1-based)
fn hasTab(lines: []const []const u8, line: usize, column: usize) bool {
    if (line == 0 or line > lines.len or column == 0) return false;
    const l = lines[line - 1];
    return column <= l.len and l[column - 1] == '\t';
}

/// The line (1-based) of `lines` that includes the first file, in the order
/// gfortran reads them, whose line `line` has a TAB in column `column`
/// (`found`), directly or through the files it includes (`via`, as `find`)
fn findTab(a: Allocator, io: Io, lines: []const []const u8, dir: []const u8, dirs: []const []const u8, line: usize, column: usize, via: *std.ArrayList(Hop), found: *?[]const u8, depth: usize) !?usize {
    if (depth >= max_depth) return null;
    for (lines, 0..) |l, i| {
        const name = named(l) orelse continue;
        const p = (try resolve(a, io, name, dir, dirs)) orelse continue;
        const text = fsio.readFile(io, a, p, .limited(16 * 1024 * 1024)) catch continue;
        const inner = try compile.splitLines(a, text);
        if (hasTab(inner, line, column)) {
            found.* = p;
            return i + 1;
        }
        if (try findTab(a, io, inner, paths.dirname(p), dirs, line, column, via, found, depth + 1)) |n| {
            try via.append(a, .{ .file = p, .line = n });
            return i + 1;
        }
    }
    return null;
}

test "gfortran's -Wtabs of an included file: at the INCLUDE line (#586)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    patterns.init();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "tabbed.inc", .data = "C     an include with a TAB-format line\n\tI = 1\n" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try paths.join(a, &.{ dir, "ti.f" });
    const gf = testJob(arena, .gfortran, path, dir, &.{path});
    const ti = [_][]const u8{ "      PROGRAM TI", "      IMPLICIT NONE", "      INTEGER I", "      INCLUDE 'tabbed.inc'", "      PRINT *, I", "      END" };
    // MSYS2's gfortran 16.1, -Wall
    const msgs = try compilers.parse(a, .gfortran, "f951.exe: Warning: Nonconforming tab character in column 1 of line 2 [-Wtabs]\n");
    try fill(a, io, &gf, &ti, &.{path}, msgs);
    try std.testing.expectEqual(@as(usize, 4), msgs[0].include_site.?.line);
    try std.testing.expectEqualStrings(try paths.join(a, &.{ dir, "tabbed.inc" }), msgs[0].file.?);
    // a TAB of the file checked itself: left there
    const own = [_][]const u8{ "      PROGRAM T", "\tI = 1", "      INCLUDE 'tabbed.inc'", "      END" };
    const again = try compilers.parse(a, .gfortran, "f951.exe: Warning: Nonconforming tab character in column 1 of line 2 [-Wtabs]\n");
    try fill(a, io, &gf, &own, &.{path}, again);
    try std.testing.expect(again[0].include_site == null and again[0].file == null);
}

fn testJob(arena: std.heap.ArenaAllocator, id: compilers.Id, path: []const u8, cwd: []const u8, args: []const []const u8) compile.Job {
    return .{ .arena = arena, .uri = "", .path = path, .id = id, .exes = &.{}, .compiler_path = null, .cwd = cwd, .deps = &.{}, .deps_fixed = &.{}, .deps_cwd = &.{}, .args = args, .fixed = false, .work_dir = cwd };
}

test "a message in an included file: the INCLUDE that includes it, also through another one" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    patterns.init();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "inc");
    try tmp.dir.writeFile(io, .{ .sub_path = "inc/bad.inc", .data = "  integer :: ok_inc\n  undeclared_in_inc = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "inc/outer.inc", .data = "  include 'bad.inc'\n" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try paths.join(a, &.{ dir, "nest.f90" });
    // ifx in zfls's directory, with an include directory (made absolute,
    // `compilers.absoluteDirs`): ifx 2026.2.0 names the file of the
    // INCLUDE of an INCLUDE as it found it
    const work = try paths.join(a, &.{ dir, "work" });
    const inc_opt = try std.mem.concat(a, u8, &.{ if (is_windows) "/I" else "-I", try paths.join(a, &.{ dir, "inc" }) });
    const ifx = testJob(arena, .ifx, path, work, &.{ inc_opt, path });
    const nest = [_][]const u8{ "program nest", "  implicit none", "  include 'outer.inc'", "  ok_inc = 2", "end program" };
    for ([_][]const u8{ "inc/bad.inc", try paths.join(a, &.{ dir, "inc", "bad.inc" }) }) |named_as| {
        const msgs = try compilers.parse(a, .ifx, try a.print("{s}(2): error #6404: This name does not have a type, and must have an explicit type.   [UNDECLARED_IN_INC]\n  undeclared_in_inc = 1\n--^\n", .{named_as}));
        try fill(a, io, &ifx, &nest, &.{path}, msgs);
        try std.testing.expectEqual(@as(usize, 3), msgs[0].include_site.?.line);
        try std.testing.expectEqual(@as(usize, 1), msgs[0].related.items.len);
        try std.testing.expect(std.mem.endsWith(u8, msgs[0].related.items[0].file.?, "outer.inc"));
        try std.testing.expectEqual(@as(usize, 1), msgs[0].related.items[0].line);
        try std.testing.expect(std.mem.endsWith(u8, msgs[0].file.?, "bad.inc") and std.Io.Dir.path.isAbsolute(msgs[0].file.?));
    }
    // gfortran 16.1, in the file's directory: `inc/bad.inc` of an INCLUDE
    // and of an `#include`; `bad.inc` of an INCLUDE in an included file
    const gf = testJob(arena, .gfortran, path, dir, &.{path});
    for ([_][]const u8{ "  include 'inc/bad.inc'", "#include \"inc/bad.inc\"" }) |inc| {
        const msgs = try compilers.parse(a, .gfortran, "inc/bad.inc:2:3: Error: Symbol 'undeclared_in_inc' at (1) has no IMPLICIT type\n");
        const direct = [_][]const u8{ "program incl", "  implicit none", inc, "end program" };
        try fill(a, io, &gf, &direct, &.{path}, msgs);
        try std.testing.expectEqual(@as(usize, 3), msgs[0].include_site.?.line);
        try std.testing.expectEqual(@as(usize, 0), msgs[0].related.items.len);
    }
    const gf_inc = testJob(arena, .gfortran, path, dir, &.{ "-Iinc", path });
    const nested = try compilers.parse(a, .gfortran, "bad.inc:2:3: Error: Symbol 'undeclared_in_inc' at (1) has no IMPLICIT type\n");
    try fill(a, io, &gf_inc, &nest, &.{path}, nested);
    try std.testing.expectEqual(@as(usize, 3), nested[0].include_site.?.line);
    try std.testing.expectEqualStrings(try paths.join(a, &.{ dir, "inc", "bad.inc" }), nested[0].file.?);
    // a file that no INCLUDE names, and the file checked: no site
    const others = try compilers.parse(a, .gfortran, "other.f90:2:3: Error: x\nnest.f90:4:3: Error: y\n");
    try fill(a, io, &gf, &nest, &.{path}, others);
    try std.testing.expect(others[0].include_site == null and others[1].include_site == null);
}
