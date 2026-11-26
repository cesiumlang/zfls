//! Cross-checks zfls's symbol extraction against LLVM Flang's
//! (`zig build test-flang-oracle`), as gfortran_oracle.zig does against
//! gfortran's: the regression check of zfls's reading of the corpus, and
//! the test of Flang's own dialect and quirks (#399).
//!
//! Each file is given to Flang's frontend (`flang -fc1 -fdebug-dump-symbols`),
//! whose scope tree (flang_oracle/dump.zig) gives the entities the file
//! declares (flang_oracle/entities.zig). They are compared with the object
//! tree zfls prints with `--debug_parser`, and each variable's type and
//! kind, rank, ALLOCATABLE, POINTER, TARGET and INTENT with what zfls's
//! hover declares (flang_oracle/types.zig): the associate names of a
//! construct's blocks each with its own block's. Then the module files
//! Flang wrote of the file, and Flang's intrinsic modules, are compared the
//! same way: zfls reading the `.mod` file, Flang reading it for a USE of
//! the module. The differences known, each with its reason, are in
//! flang_oracle/known.zig; any other fails the run.
//!
//!     flang_oracle [--flang EXE] [--zfls EXE] [-v] [PATH ...]
//!
//! PATH defaults to tests/fortran (the corpus) and tests/flang (Flang's
//! dialect and quirks), whose files must all be valid for Flang. Flang is
//! `--flang`, else `FLANG`, else `flang` or `flang-new` on the PATH; without
//! one the run is skipped.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp_client");
const zfls_mod = @import("zfls");
const util = @import("oracle_util.zig");
const dump = @import("flang_oracle/dump.zig");
const entities = @import("flang_oracle/entities.zig");
const known = @import("flang_oracle/known.zig");
const odiag = @import("oracle_diagnostics.zig");
const types = @import("flang_oracle/types.zig");

const Entities = entities.Entities;

fn isSource(name: []const u8) bool {
    return zfls_mod.suffixes.isFortran(name);
}

const Flang = struct {
    exe: []const u8,
    env: std.process.Environ.Map,
    /// `-fintrinsic-modules-path`'s directory, which `-fc1` needs
    modules: ?[]const u8,
};

const Oracle = struct {
    io: Io,
    a: Allocator,
    flang: Flang,
    zfls: []const u8,
    workdir: []const u8,
    verbose: bool,
    /// how often each rule of `known.rules` named a difference
    used: []usize,
    checked: usize = 0,
    failed: usize = 0,
    dirs: usize = 0,

    /// A fresh directory of the work directory
    fn newDir(self: *Oracle) ![]const u8 {
        self.dirs += 1;
        const d = try std.Io.Dir.path.join(self.a, &.{ self.workdir, try self.a.print("{d}", .{self.dirs}) });
        try Io.Dir.cwd().createDirPath(self.io, d);
        return d;
    }

    /// Flang's dump of `src`, read in form `fixed` or free,
    /// which writes its module files to `dir` and finds those it uses there
    /// and in `include`, or null when Flang failed (said)
    fn flangDump(self: *Oracle, key: []const u8, src: []const u8, fixed: bool, dir: []const u8, include: ?[]const u8, extra: []const []const u8) !?*const dump.Scope {
        const a = self.a;
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(a, &.{ self.flang.exe, "-fc1" });
        if (self.flang.modules) |m| try cmd.appendSlice(a, &.{ "-fintrinsic-modules-path", m });
        try cmd.appendSlice(a, &.{ "-module-dir", dir, "-I", dir });
        if (include) |i| try cmd.appendSlice(a, &.{ "-I", i });
        // and the preprocessor for an upper-case suffix as zfls has it
        try cmd.append(a, if (fixed) "-ffixed-form" else "-ffree-form");
        const ext = std.Io.Dir.path.extension(src);
        var upper = false;
        for (ext) |c| upper = upper or std.ascii.isUpper(c);
        if (upper or std.ascii.eqlIgnoreCase(ext, ".fpp")) try cmd.append(a, "-cpp");
        try cmd.appendSlice(a, extra);
        try cmd.appendSlice(a, &.{ "-fdebug-dump-symbols", src });
        const r = try util.run(self.io, a, cmd.items, dir, &self.flang.env);
        if (!r.ok) {
            self.fail(key, "rejected by Flang: {s}", .{util.failure(r)});
            return null;
        }
        return switch (try dump.parse(a, r.stdout)) {
            .global => |g| g,
            .bad => |b| {
                self.fail(key, "Flang's dump not read, line {d} ({s}): {s}", .{ b.line, b.why, b.text });
                return null;
            },
        };
    }

    const Tree = struct { entities: Entities, decls: []const entities.Declared, fixed: bool };

    /// zfls's entities of `path` and their declarations, and the form it
    /// read it in
    fn zflsTree(self: *Oracle, key: []const u8, path: []const u8, extra: []const []const u8) !?Tree {
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(self.a, &.{ self.zfls, "--debug_parser", "--debug_filepath", path });
        try cmd.appendSlice(self.a, extra);
        const z = try util.run(self.io, self.a, cmd.items, null, null);
        var decls: std.ArrayList(entities.Declared) = .empty;
        const got = try entities.fromZfls(self.a, z.stdout, &decls) orelse {
            self.fail(key, "zfls printed no object tree ({s})", .{z.code});
            return null;
        };
        return .{ .entities = got, .decls = decls.items, .fixed = std.mem.find(u8, z.stdout, "Detected format: fixed") != null };
    }

    fn fail(self: *Oracle, key: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.failed += 1;
        std.debug.print("FAIL {s}: " ++ fmt ++ "\n", .{key} ++ args);
    }

    const Ref = struct { entities: Entities, vars: []const types.Item };

    /// Flang's entities of a dump (of module `module`'s scope, when not
    /// null) and its variables, or null when one is of a kind not known
    /// (said)
    fn flangEntities(self: *Oracle, key: []const u8, global: *const dump.Scope, module: ?[]const u8) !?Ref {
        var unknown: ?entities.Unknown = null;
        var vars: std.ArrayList(types.Item) = .empty;
        const got = readFlang(self.a, global, module, &unknown, &vars) catch |e| switch (e) {
            error.UnknownDetails => {
                if (unknown) |u|
                    self.fail(key, "a symbol of Flang's dump of a kind not known, line {d}: {s}", .{ u.line, u.details })
                else
                    self.fail(key, "a scope of Flang's dump without a name", .{});
                return null;
            },
            else => |x| return x,
        };
        return .{ .entities = got orelse {
            self.fail(key, "Flang's dump has no module {s}", .{module.?});
            return null;
        }, .vars = vars.items };
    }

    /// Compares one file's entities and variables and says how they differ
    fn compare(self: *Oracle, key: []const u8, flang: Ref, zfls: Tree) !void {
        const a = self.a;
        const ref = flang.entities;
        const got = zfls.entities;
        self.checked += 1;
        const Line = struct { diff: known.Diff, name: []const u8, kind: entities.Kind, text: []const u8 };
        var lines: std.ArrayList(Line) = .empty;
        for (ref.keys(), ref.values()) |name, kind| {
            if (got.get(name)) |zk| {
                if (!entities.sameKind(kind, zk)) try lines.append(a, .{ .diff = .kind, .name = name, .kind = kind, .text = try a.print("Flang={s} zfls={s}", .{ @tagName(kind), @tagName(zk) }) });
            } else try lines.append(a, .{ .diff = .missing, .name = name, .kind = kind, .text = @tagName(kind) });
        }
        for (got.keys(), got.values()) |name, zk| if (!ref.contains(name)) try lines.append(a, .{ .diff = .extra, .name = name, .kind = zk, .text = @tagName(zk) });
        // each variable's type and attributes, with Flang's of its path:
        // the n-th of a path (the associate names of a construct's blocks)
        // with the n-th (#715)
        var by_path: std.array_hash_map.String(struct { flang: std.ArrayList(types.Var) = .empty, zfls: std.ArrayList([]const u8) = .empty }) = .empty;
        for (flang.vars) |v| {
            const gop = try by_path.getOrPut(a, v.path);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.flang.append(a, v.v);
        }
        for (zfls.decls) |d| if (by_path.getPtr(d.path)) |e| try e.zfls.append(a, d.decl);
        var compared: usize = 0;
        for (by_path.keys(), by_path.values()) |path, e| {
            if (e.zfls.items.len == 0) continue;
            if (e.zfls.items.len != e.flang.items.len) {
                try lines.append(a, .{ .diff = .differs, .name = path, .kind = .variable, .text = try a.print("{d} declared, Flang {d}", .{ e.zfls.items.len, e.flang.items.len }) });
                continue;
            }
            compared += e.zfls.items.len;
            for (e.flang.items, e.zfls.items, 1..) |v, decl, n| if (try types.mismatch(a, v, decl)) |why| {
                const which = if (e.zfls.items.len > 1) try a.print("{d} of {d}: ", .{ n, e.zfls.items.len }) else "";
                try lines.append(a, .{ .diff = .differs, .name = path, .kind = .variable, .text = try a.print("{s}{s}: {s}", .{ which, decl, why }) });
            };
        }
        std.mem.sort(Line, lines.items, {}, struct {
            fn lt(_: void, x: Line, y: Line) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        var unexpected: usize = 0;
        var known_n: usize = 0;
        for (lines.items) |l| if (known.find(key, l.name, l.diff, l.kind, l.text)) |i| {
            self.used[i] += 1;
            known_n += 1;
        } else {
            unexpected += 1;
        };
        const what = [_][]const u8{ "missing in zfls", "only in zfls   ", "kind differs   ", "differs        " };
        if (unexpected == 0) {
            std.debug.print("OK   {s}: {d} entities, {d} variables, {d} known differences\n", .{ key, ref.count(), compared, known_n });
        } else {
            self.failed += 1;
            std.debug.print("FAIL {s}: {d} entities, {d} differences not known\n", .{ key, ref.count(), unexpected });
        }
        for (lines.items) |l| {
            const rule = known.find(key, l.name, l.diff, l.kind, l.text);
            if (rule) |i| {
                if (self.verbose) std.debug.print("   known: {s} {s} ({s}): {s}\n", .{ what[@backingInt(l.diff)], l.name, l.text, known.rules[i].why });
            } else std.debug.print("   {s} {s} ({s})\n", .{ what[@backingInt(l.diff)], l.name, l.text });
        }
    }

    /// The file `src`, then each module file Flang wrote of it
    fn checkFile(self: *Oracle, src: []const u8) !void {
        const a = self.a;
        const key = try displayPath(a, src);
        const abs = try Io.Dir.cwd().realPathFileAlloc(self.io, src, a);
        const dir = try self.newDir();
        const text = try Io.Dir.cwd().readFileAlloc(self.io, src, a, .limited(1 << 24));
        const flang_args = try util.headerArgs(a, text, "oracle-flang-args:");
        const zfls_args = try util.headerArgs(a, text, "oracle-zfls-args:");
        const got = try self.zflsTree(key, abs, zfls_args) orelse return;
        // the suffix's form, the form zfls detects for one of none (`.fpp`,
        // which Flang reads as fixed form)
        const fixed = switch (zfls_mod.suffixes.formOf(src) orelse .free) {
            .fixed => true,
            .free => false,
            .detect => got.fixed,
        };
        const global = try self.flangDump(key, abs, fixed, dir, std.Io.Dir.path.dirname(abs), flang_args) orelse return;
        const ref = try self.flangEntities(key, global, null) orelse return;
        try self.compare(key, ref, got);
        // zfls's own errors and warnings on code Flang accepts (#735)
        for (try odiag.report(self.io, a, self.zfls, abs, zfls_args)) |d| self.fail(key, "zfls reports: {s}", .{d});
        // the module files, in the order of their names
        var mods: std.ArrayList([]const u8) = .empty;
        var d = try Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true });
        defer d.close(self.io);
        var it = d.iterate();
        while (try it.next(self.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".mod")) continue;
            // a submodule's (`ancestor-submodule.mod`), which no USE reads
            if (std.mem.findScalar(u8, e.name, '-') != null) {
                std.debug.print("     {s} > {s}: a submodule's, which zfls does not read (no USE names it): not compared\n", .{ key, e.name });
                continue;
            }
            try mods.append(a, try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, mods.items, {}, util.lessThan);
        const ext = if (std.ascii.eqlIgnoreCase(std.Io.Dir.path.extension(src), ".cuf")) ".cuf" else ".f90";
        for (mods.items) |m| try self.checkModFile(try a.print("{s} > {s}", .{ key, m }), dir, m, ext, flang_args);
    }

    /// The module file `name` of `dir`: zfls reading it, and Flang reading
    /// it for a USE of the module, in a file of suffix `ext`, with the
    /// fixture's arguments `flang_args` (`-funsigned`)
    fn checkModFile(self: *Oracle, key: []const u8, dir: []const u8, name: []const u8, ext: []const u8, flang_args: []const []const u8) !void {
        const a = self.a;
        const module = name[0 .. name.len - ".mod".len];
        const use_dir = try self.newDir();
        const use_src = try std.Io.Dir.path.join(a, &.{ use_dir, try a.print("zfls_oracle_use{s}", .{ext}) });
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = use_src, .data = try a.print("program zfls_oracle_use\n  use {s}\nend program\n", .{module}) });
        const global = try self.flangDump(key, use_src, false, use_dir, dir, flang_args) orelse return;
        const ref = try self.flangEntities(key, global, module) orelse return;
        const got = try self.zflsTree(key, try std.Io.Dir.path.join(a, &.{ dir, name }), &.{}) orelse return;
        try self.compare(key, ref, got);
    }
};

fn readFlang(a: Allocator, global: *const dump.Scope, module: ?[]const u8, unknown: *?entities.Unknown, vars: *std.ArrayList(types.Item)) entities.Error!?Entities {
    if (module) |m| return entities.fromFlangModule(a, global, m, unknown, vars);
    return try entities.fromFlang(a, global, unknown, vars);
}

/// `path` with forward slashes, as the known differences name files
fn displayPath(a: Allocator, path: []const u8) ![]const u8 {
    const out = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn findFlang(io: Io, a: Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("FLANG")) |f| if (f.len > 0) return f;
    if (try util.findOnPath(io, a, env, "flang")) |f| return f;
    return util.findOnPath(io, a, env, "flang-new");
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var flang_arg: ?[]const u8 = null;
    var zfls: []const u8 = "zig-out/bin/zfls";
    var verbose = false;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if ((std.mem.eql(u8, arg, "--flang") or std.mem.eql(u8, arg, "--zfls")) and i + 1 < argv.len) {
            i += 1;
            if (arg[2] == 'f') flang_arg = argv[i] else zfls = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("usage: flang_oracle [--flang EXE] [--zfls EXE] [-v] [PATH ...]\n", .{});
            return if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) 0 else 2;
        } else try paths.append(a, arg);
    }
    const env = init.environ_map;
    const exe = flang_arg orelse try findFlang(io, a, env) orelse {
        std.debug.print("LLVM Flang not found; skipping\n", .{});
        return 0;
    };
    const flang_env = try util.envWithDirOf(io, a, env, exe);
    const version = try util.run(io, a, &.{ exe, "--version" }, null, &flang_env);
    if (!version.ok) {
        std.debug.print("FAIL {s} --version: {s}\n", .{ exe, util.failure(version) });
        return 1;
    }
    var first = std.mem.splitScalar(u8, version.stdout, '\n');
    std.debug.print("flang: {s} ({s})\n", .{ exe, std.mem.trim(u8, first.next() orelse "?", " \r") });
    const module_dir = try zfls_mod.compilers_flang_modules.moduleDir(io, a, version.stdout);
    std.debug.print("intrinsic modules: {s}\n", .{module_dir orelse "(not found)"});
    // the corpus and the fixtures are all valid Fortran for Flang
    const defaults = paths.items.len == 0;
    if (defaults) try paths.appendSlice(a, &.{ "tests/fortran", "tests/flang" });
    const files = try util.collect(io, a, paths.items, isSource);
    const workdir = try lsp.tempDir(io, a, env, "zfls_flang_");
    defer Io.Dir.cwd().deleteTree(io, workdir) catch {};
    var o: Oracle = .{
        .io = io,
        .a = a,
        .flang = .{ .exe = exe, .env = flang_env, .modules = module_dir },
        .zfls = zfls,
        .workdir = workdir,
        .verbose = verbose,
        .used = try a.alloc(usize, known.rules.len),
    };
    @memset(o.used, 0);
    for (files) |src| try o.checkFile(src);
    // Flang's intrinsic modules, as zfls reads them for a USE (#468)
    if (defaults) {
        const dir = module_dir orelse {
            o.fail("intrinsic", "Flang's intrinsic modules not found", .{});
            return 1;
        };
        var mods: std.ArrayList([]const u8) = .empty;
        var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".mod")) try mods.append(a, try a.dupe(u8, e.name));
        std.mem.sort([]const u8, mods.items, {}, util.lessThan);
        for (mods.items) |m| try o.checkModFile(try a.print("intrinsic > {s}", .{m}), dir, m, ".cuf", &.{});
        // a rule that names no difference any more
        for (known.rules, o.used) |r, n| if (n == 0) o.fail(r.file, "known difference not seen any more: {s} {s}", .{ @tagName(r.diff), r.entity });
    }
    std.debug.print("\n{d} files checked, {d} failures\n", .{ o.checked, o.failed });
    return if (o.failed > 0) 1 else 0;
}

test {
    _ = util;
    _ = dump;
    _ = entities;
    _ = known;
    _ = types;
}
