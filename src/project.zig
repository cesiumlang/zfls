//! What a project's build files say about its sources: the include
//! directories and preprocessor definitions of the Fortran files of a
//! `compile_commands.json` (CMake, Meson, Bear, ...) and of an `fpm.toml`.
//! They add to the `include_dirs` and `pp_defs` options (fortls #512).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("json.zig");
const paths = @import("paths.zig");
const str = @import("str.zig");

pub const Def = struct { name: []const u8, value: []const u8 };

pub const Found = struct {
    include_dirs: std.ArrayList([]const u8) = .empty,
    defs: std.ArrayList(Def) = .empty,

    fn addDir(self: *Found, a: Allocator, dir: []const u8) !void {
        for (self.include_dirs.items) |d| if (std.mem.eql(u8, d, dir)) return;
        try self.include_dirs.append(a, dir);
    }

    /// `NAME` or `NAME=VALUE`; the first definition of a name wins
    fn addDef(self: *Found, a: Allocator, def: []const u8) !void {
        const eq = std.mem.indexOfScalar(u8, def, '=');
        const name = str.strip(if (eq) |i| def[0..i] else def);
        if (name.len == 0) return;
        for (self.defs.items) |d| if (std.mem.eql(u8, d.name, name)) return;
        try self.defs.append(a, .{ .name = name, .value = if (eq) |i| def[i + 1 ..] else "" });
    }
};

/// The `compile_commands.json` to read: `setting` when set (a file, or the
/// directory holding one; empty: none), else one in `root` or `root/build`
pub fn findCompileCommands(io: Io, a: Allocator, root: []const u8, setting: ?[]const u8) !?[]const u8 {
    if (setting) |s| {
        if (s.len == 0) return null;
        const p = if (std.fs.path.isAbsolute(s)) s else try paths.join(a, &.{ root, s });
        if (paths.isDir(io, p)) return try paths.join(a, &.{ p, "compile_commands.json" });
        return p;
    }
    for ([_][]const u8{ ".", "build" }) |sub| {
        const p = try paths.join(a, &.{ root, sub, "compile_commands.json" });
        if (paths.isFile(io, p)) return p;
    }
    return null;
}

const fortran_extensions = [_][]const u8{
    ".f", ".for", ".ftn", ".fpp", ".f77", ".f90", ".f95", ".f03", ".f08", ".f18",
};

fn isFortran(file: []const u8) bool {
    const ext = std.fs.path.extension(file);
    for (fortran_extensions) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// The include directories and definitions of the Fortran entries of a
/// compilation database; a relative `directory` is relative to `base`, the
/// directory of the database
pub fn readCompileCommands(a: Allocator, text: []const u8, base: []const u8) !Found {
    var found: Found = .{};
    const v = std.json.parseFromSliceLeaky(json.Value, a, text, .{}) catch return error.InvalidJson;
    if (v != .array) return error.InvalidJson;
    for (v.array.items) |entry| {
        const file = json.str(json.get(entry, "file")) orelse continue;
        if (!isFortran(file)) continue;
        const entry_dir = json.str(json.get(entry, "directory")) orelse ".";
        const dir = if (std.fs.path.isAbsolute(entry_dir)) entry_dir else try paths.join(a, &.{ base, entry_dir });
        var args: std.ArrayList([]const u8) = .empty;
        if (json.get(entry, "arguments")) |arr| {
            for (json.items(arr)) |x| if (json.str(x)) |s| try args.append(a, s);
        } else if (json.str(json.get(entry, "command"))) |cmd| {
            try splitCommand(a, cmd, &args);
        }
        try readFlags(a, dir, args.items, &found);
    }
    return found;
}

/// `-I dir`, `-Idir`, `-isystem dir`, `-D NAME[=VALUE]`, and the `/I`, `/D`
/// of compilers on Windows
fn readFlags(a: Allocator, dir: []const u8, args: []const []const u8, found: *Found) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const Flag = enum { include, define };
        const flags = [_]struct { []const u8, Flag }{
            .{ "-isystem", .include }, .{ "-I", .include }, .{ "/I", .include },
            .{ "-D", .define },        .{ "/D", .define },
        };
        for (flags) |f| {
            if (!std.mem.startsWith(u8, arg, f[0])) continue;
            var value = arg[f[0].len..];
            if (value.len == 0) {
                if (i + 1 >= args.len) break;
                i += 1;
                value = args[i];
            }
            switch (f[1]) {
                .include => {
                    const p = if (std.fs.path.isAbsolute(value)) value else try paths.join(a, &.{ dir, value });
                    try found.addDir(a, try paths.abspath(a, p));
                },
                .define => try found.addDef(a, value),
            }
            break;
        }
    }
}

/// Splits a shell command line into its arguments (quotes and backslash
/// escapes, as POSIX shells read them)
fn splitCommand(a: Allocator, cmd: []const u8, out: *std.ArrayList([]const u8)) !void {
    var cur: std.ArrayList(u8) = .empty;
    var in_arg = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (c == '\\' and quote == '"' and i + 1 < cmd.len) {
                i += 1;
                try cur.append(a, cmd[i]);
            } else try cur.append(a, c);
            continue;
        }
        switch (c) {
            ' ', '\t', '\n' => if (in_arg) {
                try out.append(a, try cur.toOwnedSlice(a));
                in_arg = false;
            },
            '"', '\'' => {
                quote = c;
                in_arg = true;
            },
            '\\' => {
                in_arg = true;
                if (i + 1 < cmd.len) {
                    i += 1;
                    try cur.append(a, cmd[i]);
                }
            },
            else => {
                in_arg = true;
                try cur.append(a, c);
            },
        }
    }
    if (in_arg) try out.append(a, try cur.toOwnedSlice(a));
}

/// The include directory and preprocessor macros of an `fpm.toml` in
/// `root`: `[library] include-dir` (default `include`, when it exists) and
/// `[preprocess.cpp] macros`
pub fn readFpm(io: Io, a: Allocator, root: []const u8, text: []const u8) !Found {
    var found: Found = .{};
    var section: []const u8 = "";
    var include_dirs: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = str.strip(stripTomlComment(raw));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = str.strip(std.mem.trim(u8, line, "[]"));
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = str.strip(line[0..eq]);
        var value = str.strip(line[eq + 1 ..]);
        // an array that goes on over the next lines
        if (std.mem.startsWith(u8, value, "[") and std.mem.indexOfScalar(u8, value, ']') == null) {
            var joined: std.ArrayList(u8) = .empty;
            try joined.appendSlice(a, value);
            while (lines.next()) |more| {
                try joined.appendSlice(a, str.strip(stripTomlComment(more)));
                if (std.mem.indexOfScalar(u8, more, ']') != null) break;
            }
            value = joined.items;
        }
        if (std.mem.eql(u8, section, "library") and std.mem.eql(u8, key, "include-dir")) {
            try tomlStrings(a, value, &include_dirs);
        } else if (std.mem.eql(u8, section, "preprocess.cpp") and std.mem.eql(u8, key, "macros")) {
            var macros: std.ArrayList([]const u8) = .empty;
            try tomlStrings(a, value, &macros);
            for (macros.items) |m| try found.addDef(a, m);
        }
    }
    if (include_dirs.items.len == 0) try include_dirs.append(a, "include");
    for (include_dirs.items) |d| {
        const p = try paths.abspath(a, try paths.join(a, &.{ root, d }));
        if (paths.isDir(io, p)) try found.addDir(a, p);
    }
    return found;
}

fn stripTomlComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') return line[0..i];
    }
    return line;
}

/// The strings of a TOML string or array of strings
fn tomlStrings(a: Allocator, value: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const q = value[i];
        if (q != '"' and q != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, value, i + 1, q) orelse return;
        try out.append(a, try a.dupe(u8, value[i + 1 .. end]));
        i = end;
    }
}

test "compile_commands.json: the flags of Fortran entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (@import("builtin").os.tag == .windows) "C:\\\\p" else "/p";
    const text = try std.fmt.allocPrint(a,
        \\[
        \\  {{"directory": "{s}", "file": "a.F90",
        \\   "command": "gfortran -I inc -Iinc2 -DFOO -D BAR=2 -c a.F90"}},
        \\  {{"directory": "{s}", "file": "b.c", "command": "cc -Ic_only -DC_ONLY -c b.c"}},
        \\  {{"directory": "{s}", "file": "c.f90",
        \\   "arguments": ["ifx", "/Iwin", "/DWIN=\"x y\"", "-DFOO=3", "c.f90"]}}
        \\]
    , .{ root, root, root });
    const f = try readCompileCommands(a, text, root);
    try std.testing.expectEqual(@as(usize, 3), f.include_dirs.items.len);
    try std.testing.expect(std.mem.endsWith(u8, f.include_dirs.items[0], "inc"));
    try std.testing.expectEqual(@as(usize, 3), f.defs.items.len);
    try std.testing.expectEqualStrings("FOO", f.defs.items[0].name);
    try std.testing.expectEqualStrings("", f.defs.items[0].value);
    try std.testing.expectEqualStrings("2", f.defs.items[1].value);
    try std.testing.expectEqualStrings("\"x y\"", f.defs.items[2].value);
}

test "a shell command line is split as a shell would" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try splitCommand(arena.allocator(), "f90 -DA=\"b c\" 'd e' f\\ g", &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("-DA=b c", out.items[1]);
    try std.testing.expectEqualStrings("d e", out.items[2]);
    try std.testing.expectEqualStrings("f g", out.items[3]);
}
