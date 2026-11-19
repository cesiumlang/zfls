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

/// Where the compile of a file writes its modules, and the directories it
/// looks for the modules it uses in, in order (absolute; #187)
pub const ModuleDirs = struct { out: []const u8, search: []const []const u8 };

/// `ModuleDirs` by the `pathKey` of the source file
pub const ModuleDirsMap = std.array_hash_map.String(ModuleDirs);

/// A path as `ModuleDirsMap` keys it: normalized, and on Windows lowercase
/// with backslashes
pub fn pathKey(a: Allocator, path: []const u8) ![]const u8 {
    const n = try paths.normpath(a, path);
    if (@import("builtin").target.os.tag == .windows) {
        for (n) |*c| c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    }
    return n;
}
/// The command of one file in a compilation database
pub const Command = struct {
    /// Where it runs (absolute)
    dir: []const u8,
    /// The compiler, then its arguments
    args: []const []const u8,
    /// The source file (absolute)
    file: []const u8,
};

/// The commands of a compilation database's Fortran files, by `fileKey`
pub const Commands = std.array_hash_map.String(Command);

pub const Found = struct {
    /// The Fortran files a compilation database compiles (absolute)
    files: std.ArrayList([]const u8) = .empty,
    include_dirs: std.ArrayList([]const u8) = .empty,
    defs: std.ArrayList(Def) = .empty,
    /// The module directories of each Fortran file
    module_dirs: ModuleDirsMap = .empty,
    /// The command of each Fortran file (compile_commands.json only)
    commands: Commands = .empty,

    fn addDir(self: *Found, a: Allocator, dir: []const u8) !void {
        for (self.include_dirs.items) |d| if (std.mem.eql(u8, d, dir)) return;
        try self.include_dirs.append(a, dir);
    }

    /// `NAME` or `NAME=VALUE`; the first definition of a name wins
    fn addDef(self: *Found, a: Allocator, def: []const u8) !void {
        const eq = std.mem.findScalar(u8, def, '=');
        const name = str.strip(if (eq) |i| def[0..i] else def);
        if (name.len == 0) return;
        for (self.defs.items) |d| if (std.mem.eql(u8, d.name, name)) return;
        try self.defs.append(a, .{ .name = name, .value = if (eq) |i| def[i + 1 ..] else "" });
    }
};

/// The `compile_commands.json` to read: `setting` when set (a file, or the
/// directory holding one; empty: none), else one in `root`, `root/build` or
/// `root/builddir` (Meson's)
pub fn findCompileCommands(io: Io, a: Allocator, root: []const u8, setting: ?[]const u8) !?[]const u8 {
    if (setting) |s| {
        if (s.len == 0) return null;
        const p = if (std.Io.Dir.path.isAbsolute(s)) s else try paths.join(a, &.{ root, s });
        if (paths.isDir(io, p)) return try paths.join(a, &.{ p, "compile_commands.json" });
        return p;
    }
    for ([_][]const u8{ ".", "build", "builddir" }) |sub| {
        const p = try paths.join(a, &.{ root, sub, "compile_commands.json" });
        if (paths.isFile(io, p)) return p;
    }
    return null;
}

/// Whether a file name has an extension of Fortran sources
pub fn isFortran(file: []const u8) bool {
    return @import("suffixes.zig").isFortran(file);
}

/// The files, include directories and definitions of the Fortran entries
/// of a compilation database; a relative `directory` is relative to
/// `base`, the directory of the database, and a relative `file` to its
/// `directory`
pub fn readCompileCommands(a: Allocator, text: []const u8, base: []const u8) !Found {
    var found: Found = .{};
    const v = std.json.parseFromSliceLeaky(json.Value, a, str.withoutBom(text), .{}) catch return error.InvalidJson;
    if (v != .array) return error.InvalidJson;
    for (v.array.items) |entry| {
        const file = json.str(json.get(entry, "file")) orelse continue;
        if (!isFortran(file)) continue;
        const entry_dir = json.str(json.get(entry, "directory")) orelse ".";
        const dir = if (std.Io.Dir.path.isAbsolute(entry_dir)) entry_dir else try paths.join(a, &.{ base, entry_dir });
        try found.files.append(a, try paths.normpath(a, if (std.Io.Dir.path.isAbsolute(file)) file else try paths.join(a, &.{ dir, file })));
        var args: std.ArrayList([]const u8) = .empty;
        if (json.get(entry, "arguments")) |arr| {
            for (json.items(arr)) |x| if (json.str(x)) |s| try args.append(a, s);
        } else if (json.str(json.get(entry, "command"))) |cmd| {
            try splitCommand(a, cmd, &args);
        }
        try readFlags(a, dir, args.items, &found);
        try readModuleDirs(a, dir, args.items, found.files.items[found.files.items.len - 1], &found);
        // the first entry of a file is its command
        const abs = try paths.normpath(a, if (std.Io.Dir.path.isAbsolute(file)) file else try paths.join(a, &.{ dir, file }));
        const gop = try found.commands.getOrPut(a, try fileKey(a, abs));
        if (!gop.found_existing) gop.value_ptr.* = .{ .dir = try paths.normpath(a, dir), .args = args.items, .file = abs };
    }
    return found;
}

/// The module directory of the compile of `file` (`-J dir`, `-module dir`,
/// `/module:dir`, ...; its working directory `dir` without one) and its
/// search path: that directory, the include directories, `dir`. The first
/// entry of a file is its command.
fn readModuleDirs(a: Allocator, dir: []const u8, args: []const []const u8, file: []const u8, found: *Found) !void {
    const gop = try found.module_dirs.getOrPut(a, try pathKey(a, file));
    if (gop.found_existing) return;
    const Kind = enum { module, include };
    const Opt = struct { []const u8, Kind };
    // followed by their value
    const separate = [_]Opt{
        .{ "-J", .module },  .{ "-module", .module }, .{ "-module-dir", .module }, .{ "-mdir", .module },
        .{ "-I", .include }, .{ "/I", .include },     .{ "-isystem", .include },
    };
    // with their value attached
    const attached = [_]Opt{
        .{ "-J", .module },  .{ "/module:", .module }, .{ "-module:", .module },  .{ "-fmod=", .module }, .{ "-qmoddir=", .module },
        .{ "-I", .include }, .{ "/I", .include },      .{ "-isystem", .include },
    };
    var out: ?[]const u8 = null;
    var includes: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var value: ?[]const u8 = null;
        var kind: Kind = .include;
        find: {
            for (separate) |o| if (std.mem.eql(u8, arg, o[0])) {
                kind = o[1];
                if (i + 1 < args.len) {
                    i += 1;
                    value = args[i];
                }
                break :find;
            };
            for (attached) |o| if (arg.len > o[0].len and std.mem.startsWith(u8, arg, o[0])) {
                kind = o[1];
                value = arg[o[0].len..];
                break :find;
            };
        }
        const v = value orelse continue;
        const abs = try paths.normpath(a, if (std.Io.Dir.path.isAbsolute(v)) v else try paths.join(a, &.{ dir, v }));
        switch (kind) {
            .module => out = abs,
            .include => try includes.append(a, abs),
        }
    }
    const cwd = try paths.normpath(a, dir);
    var search: std.ArrayList([]const u8) = .empty;
    try search.append(a, out orelse cwd);
    try search.appendSlice(a, includes.items);
    try search.append(a, cwd);
    gop.value_ptr.* = .{ .out = out orelse cwd, .search = search.items };
}

/// A path as `Commands` keys it: normalized, and on Windows lowercase with
/// backslashes
pub fn fileKey(a: Allocator, path: []const u8) ![]const u8 {
    const n = try paths.normpath(a, path);
    if (@import("builtin").target.os.tag != .windows) return n;
    for (n) |*c| c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    return n;
}

/// The command of the file at `path` (absolute), else that of another file
/// in its directory, else null
pub fn commandFor(a: Allocator, commands: *const Commands, path: []const u8) !?Command {
    const key = try fileKey(a, path);
    if (commands.get(key)) |c| return c;
    const dir = paths.dirname(key);
    for (commands.keys(), commands.values()) |k, c| if (std.mem.eql(u8, paths.dirname(k), dir)) return c;
    return null;
}

/// The arguments of `cmd` for checking another run of its compiler: without
/// the compiler, `-c`, the output file, the source file, the module
/// directory (the checker has its own) and the dependency files, nor
/// colors and carets in the messages
pub fn compilerArgs(a: Allocator, cmd: Command) ![]const []const u8 {
    // dropped with the argument after them (or attached to them)
    const with_value = [_][]const u8{ "-o", "-J", "-module", "-module-dir", "-mdir", "-MF", "-MT", "-MQ" };
    // dropped when the argument starts with them
    const prefixed = [_][]const u8{ "/module:", "-module:", "-fmod=", "-qmoddir=", "/Fo", "-Fo", "/object:", "/Fe", "/exe:", "-fdiagnostics-color", "-fcolor-diagnostics", "-fno-color-diagnostics", "-fdiagnostics-show-caret", "-fno-diagnostics-show-caret" };
    // dropped as they are
    const alone = [_][]const u8{ "-c", "/c", "-M", "-MM", "-MD", "-MMD", "-MP" };
    const source = try fileKey(a, cmd.file);
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = if (cmd.args.len > 0) 1 else 0;
    outer: while (i < cmd.args.len) : (i += 1) {
        const x = cmd.args[i];
        for (alone) |o| if (std.mem.eql(u8, x, o)) continue :outer;
        for (with_value) |o| if (std.mem.eql(u8, x, o)) {
            i += 1;
            continue :outer;
        };
        for (prefixed) |o| if (std.mem.startsWith(u8, x, o)) continue :outer;
        // -Jdir, -MFfile; -ofile only as an object file (-o is the start of
        // other options too)
        for ([_][]const u8{ "-J", "-MF", "-MT", "-MQ" }) |o| if (std.mem.startsWith(u8, x, o)) continue :outer;
        if (std.mem.startsWith(u8, x, "-o") and (std.mem.endsWith(u8, x, ".o") or std.mem.endsWith(u8, x, ".obj"))) continue;
        if (x.len > 0 and x[0] != '-' and isFortran(x)) {
            const abs = if (std.Io.Dir.path.isAbsolute(x)) x else try paths.join(a, &.{ cmd.dir, x });
            if (std.mem.eql(u8, try fileKey(a, abs), source)) continue;
        }
        try out.append(a, x);
    }
    return out.items;
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
                    const p = if (std.Io.Dir.path.isAbsolute(value)) value else try paths.join(a, &.{ dir, value });
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
    var lines = std.mem.splitScalar(u8, str.withoutBom(text), '\n');
    while (lines.next()) |raw| {
        const line = str.strip(stripTomlComment(raw));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = str.strip(std.mem.trim(u8, line, "[]"));
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = str.strip(line[0..eq]);
        var value = str.strip(line[eq + 1 ..]);
        // an array that goes on over the next lines
        if (std.mem.startsWith(u8, value, "[") and std.mem.findScalar(u8, value, ']') == null) {
            var joined: std.ArrayList(u8) = .empty;
            try joined.appendSlice(a, value);
            while (lines.next()) |more| {
                try joined.appendSlice(a, str.strip(stripTomlComment(more)));
                if (std.mem.findScalar(u8, more, ']') != null) break;
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

/// A line of TOML without its `#` comment (outside strings)
pub fn stripTomlComment(line: []const u8) []const u8 {
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
        const end = std.mem.findScalarPos(u8, value, i + 1, q) orelse return;
        try out.append(a, try a.dupe(u8, value[i + 1 .. end]));
        i = end;
    }
}

/// Whether `path` is an interface module that ifort and ifx write beside
/// each source with `-warn interfaces` or `-gen-interfaces`: a
/// `<name>__genmod.f90` whose first line is
/// `!COMPILER-GENERATED INTERFACE MODULE: <date>`. It repeats the external
/// procedures of the source; a hand-written file of that name is kept.
pub fn isIfortInterface(io: Io, path: []const u8) bool {
    const suffix = "__genmod.f90";
    const base = std.Io.Dir.path.basename(path);
    if (!std.ascii.endsWithIgnoreCase(base, suffix)) return false;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buf: [128]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return false;
    const head = std.mem.trimStart(u8, buf[0..n], " \t");
    return std.ascii.startsWithIgnoreCase(head, "!COMPILER-GENERATED INTERFACE MODULE");
}

test "ifort's interface modules are told by their name and first line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const generated = "        !COMPILER-GENERATED INTERFACE MODULE: Mon Jan 01 00:00:00 2018\n        MODULE FOO__genmod\n        END MODULE FOO__genmod\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "foo__genmod.f90", .data = generated });
    try tmp.dir.writeFile(io, .{ .sub_path = "BAR__GENMOD.F90", .data = generated });
    try tmp.dir.writeFile(io, .{ .sub_path = "x__genmod.f90", .data = "module x__genmod\nend module\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "foo.f90", .data = generated });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const want = [_]struct { []const u8, bool }{ .{ "foo__genmod.f90", true }, .{ "BAR__GENMOD.F90", true }, .{ "x__genmod.f90", false }, .{ "foo.f90", false }, .{ "none__genmod.f90", false } };
    for (want) |x| try std.testing.expectEqual(x[1], isIfortInterface(io, try paths.join(arena.allocator(), &.{ root, x[0] })));
}

test "compile_commands.json: the flags of Fortran entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (@import("builtin").target.os.tag == .windows) "C:\\\\p" else "/p";
    const text = try a.print(
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
    // the Fortran files, absolute
    try std.testing.expectEqual(@as(usize, 2), f.files.items.len);
    const p = if (@import("builtin").target.os.tag == .windows) "C:\\p" else "/p";
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "a.F90" }), f.files.items[0]);
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "c.f90" }), f.files.items[1]);
}

test "compile_commands.json: the module directories of each file (#187)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = @import("builtin").target.os.tag == .windows;
    const root = if (windows) "C:\\\\p" else "/p";
    const text = try a.print(
        \\[
        \\  {{"directory": "{s}", "file": "a.f90", "command": "gfortran -Jmod -Iinc -c a.f90"}},
        \\  {{"directory": "{s}/b", "file": "b.f90", "arguments": ["ifx", "-module", "../mods", "-c", "b.f90"]}},
        \\  {{"directory": "{s}", "file": "c.f90", "arguments": ["ifx", "/module:wmods", "/I", "inc", "c.f90"]}},
        \\  {{"directory": "{s}", "file": "d.f90", "arguments": ["gfortran", "-c", "d.f90"]}}
        \\]
    , .{ root, root, root, root });
    const f = try readCompileCommands(a, text, root);
    const p = if (windows) "C:\\p" else "/p";
    const dirsOf = struct {
        fn get(al: Allocator, found: *const Found, path: []const u8) !ModuleDirs {
            return found.module_dirs.get(try pathKey(al, path)) orelse error.NoEntry;
        }
    }.get;
    const ad = try dirsOf(a, &f, try paths.join(a, &.{ p, "a.f90" }));
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "mod" }), ad.out);
    try std.testing.expectEqual(@as(usize, 3), ad.search.len);
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "inc" }), ad.search[1]);
    try std.testing.expectEqualStrings(p, ad.search[2]);
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "mods" }), (try dirsOf(a, &f, try paths.join(a, &.{ p, "b", "b.f90" }))).out);
    const cd = try dirsOf(a, &f, try paths.join(a, &.{ p, "c.f90" }));
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "wmods" }), cd.out);
    try std.testing.expectEqualStrings(try paths.join(a, &.{ p, "inc" }), cd.search[1]);
    // none: the working directory
    try std.testing.expectEqualStrings(p, (try dirsOf(a, &f, try paths.join(a, &.{ p, "d.f90" }))).out);
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

test "compile_commands.json: a file's own command, for the compiler check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = @import("builtin").target.os.tag == .windows;
    const root = if (windows) "C:\\\\p" else "/p";
    const text = try a.print(
        \\[
        \\  {{"directory": "{s}", "file": "a.f90",
        \\   "command": "gfortran -std=f2008 -fdefault-real-8 -Jmod -Iinc -DX=1 -c a.f90 -o a.o -MD -MF a.d"}},
        \\  {{"directory": "{s}/sub", "file": "b.f90",
        \\   "arguments": ["gfortran", "-std=f2008", "-fdefault-real-8", "-J", "mod", "-Iinc", "-DX=1", "-c", "b.f90", "-o", "b.o", "-MD", "-MF", "b.d", "-fdiagnostics-color=always"]}},
        \\  {{"directory": "{s}", "file": "{s}/c.f90",
        \\   "arguments": ["ifx", "/nologo", "/module:mods", "/c", "{s}/c.f90", "/Foc.obj", "/warn:all"]}}
        \\]
    , .{ root, root, root, root, root });
    const f = try readCompileCommands(a, text, root);
    const expectArgs = struct {
        fn check(al: Allocator, cmds: *const Commands, path: []const u8, want: []const []const u8) !void {
            const cmd = (try commandFor(al, cmds, path)) orelse return error.NoCommand;
            const got = try compilerArgs(al, cmd);
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
        }
    }.check;
    const p = if (windows) "C:\\p" else "/p";
    try expectArgs(a, &f.commands, try paths.join(a, &.{ p, "a.f90" }), &.{ "-std=f2008", "-fdefault-real-8", "-Iinc", "-DX=1" });
    try expectArgs(a, &f.commands, try paths.join(a, &.{ p, "sub", "b.f90" }), &.{ "-std=f2008", "-fdefault-real-8", "-Iinc", "-DX=1" });
    try expectArgs(a, &f.commands, try paths.join(a, &.{ p, "c.f90" }), &.{ "/nologo", "/warn:all" });
    // a file without an entry: another one's in its directory
    const other = (try commandFor(a, &f.commands, try paths.join(a, &.{ p, "sub", "new.f90" }))).?;
    try std.testing.expect(std.mem.endsWith(u8, other.file, "b.f90"));
    try std.testing.expect(try commandFor(a, &f.commands, try paths.join(a, &.{ p, "elsewhere", "x.f90" })) == null);
}

test "compile_commands.json and fpm.toml with a UTF-8 byte-order mark (#407)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (@import("builtin").target.os.tag == .windows) "C:\\\\p" else "/p";
    for ([_][]const u8{ "", str.bom }) |mark| {
        const db = try a.print("{s}[{{\"directory\": \"{s}\", \"file\": \"a.f90\", \"command\": \"gfortran -DFOO -c a.f90\"}}]", .{ mark, root });
        const f = try readCompileCommands(a, db, root);
        try std.testing.expectEqual(@as(usize, 1), f.defs.items.len);
        try std.testing.expectEqualStrings("FOO", f.defs.items[0].name);
        const fpm = try a.print("{s}[preprocess.cpp]\nmacros = [\"BAR=1\"]\n", .{mark});
        const g = try readFpm(std.testing.io, a, root, fpm);
        try std.testing.expectEqual(@as(usize, 1), g.defs.items.len);
        try std.testing.expectEqualStrings("BAR", g.defs.items[0].name);
    }
}
