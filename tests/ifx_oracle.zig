//! Cross-checks zfls's symbols against ifx's listing (`zig build
//! test-ifx-oracle`), as gfortran_oracle.zig does against gfortran's parse
//! tree and flang_oracle.zig against Flang's (#519).
//!
//! Each file is compiled with `ifx /c /list /show:map` (Linux `-c -list
//! -show map`); its SYMBOL CROSS REFERENCE, SUBPROGRAMS and TYPE COMPONENTS
//! (ifx_oracle/listing.zig) are compared with the Object Tree and the
//! Declarations of `zfls --debug_parser` (ifx_oracle/zfls.zig): the
//! procedures, program units, derived types, their components and
//! type-bound procedures, and the variables, with their types and kinds,
//! ranks, ALLOCATABLE, POINTER, TARGET and INTENT. ifx names a host's or a
//! module's entity in the unit that uses it, at its first use, so names are
//! compared over the whole file, not by scope. The differences known, each
//! with its reason, are in ifx_oracle/known.zig; any other fails the run.
//!
//!     ifx_oracle [--ifx EXE] [--zfls EXE] [-v] [PATH ...]
//!
//! PATH defaults to tests/fortran (the corpus) and tests/ifx (Intel's
//! dialect). A fixture gives ifx and zfls arguments on an `oracle-ifx-args:`
//! and an `oracle-zfls-args:` line among its first ten. Without ifx
//! (`--ifx`, else `IFX`, else `ifx` on the PATH) the run is skipped.

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp_client");
const util = @import("oracle_util.zig");
const listing = @import("ifx_oracle/listing.zig");
const zfls_side = @import("ifx_oracle/zfls.zig");
const known = @import("ifx_oracle/known.zig");

const is_windows = sysinfo.target.os.tag == .windows;
const fortran_exts = [_][]const u8{ ".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp" };

fn isFortran(name: []const u8) bool {
    const ext = std.Io.Dir.path.extension(name);
    for (fortran_exts) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

fn has(set: []const []const u8, x: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Whether attribute `attr` is one of the comma-separated `attrs`
fn hasAttr(attrs: []const u8, attr: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, attrs, ',');
    while (it.next()) |x| if (std.mem.eql(u8, x, attr)) return true;
    return false;
}

const Diffs = std.ArrayList([]const u8);

/// The differences between ifx's listing `l` and zfls's objects `objs`
fn compare(a: Allocator, l: listing.Listing, objs: []const zfls_side.Object) !Diffs {
    var out: Diffs = .empty;
    // what zfls has of each name: procedures, variables, types
    var procs: std.StringHashMapUnmanaged(void) = .empty;
    var vars: std.StringHashMapUnmanaged(void) = .empty;
    var types: std.StringHashMapUnmanaged(void) = .empty;
    var units: std.StringHashMapUnmanaged(void) = .empty;
    var components: std.StringHashMapUnmanaged(void) = .empty;
    for (objs) |o| {
        switch (o.kind) {
            1, 8 => try units.put(a, o.name(), {}),
            2, 3 => if (o.parent_kind == 4) try components.put(a, try a.print("{s}.{s}", .{ o.parentName(), o.name() }), {}) else try procs.put(a, o.name(), {}),
            4 => try types.put(a, o.name(), {}),
            5 => try procs.put(a, o.name(), {}),
            6, 7 => if (o.parent_kind == 4) {
                try components.put(a, try a.print("{s}.{s}", .{ o.parentName(), o.name() }), {});
            } else if (!o.group) try vars.put(a, o.name(), {}),
            else => {},
        }
    }
    // ifx's program units and procedures
    var ifx_subs: std.StringHashMapUnmanaged(void) = .empty;
    for (l.subprograms) |e| {
        // a submodule is `ancestor@name`; a program without a PROGRAM
        // statement `_unnamed_main$$` (zfls's `main`)
        var unit = e.name[if (std.mem.findScalarLast(u8, e.name, '@')) |at| at + 1 else 0..];
        if (std.mem.eql(u8, unit, "_unnamed_main$$")) unit = "main";
        try ifx_subs.put(a, unit, {});
        if (has(&.{ "Func", "Subr" }, e.object) and !procs.contains(e.name) and !vars.contains(e.name))
            try out.append(a, try a.print("missing in zfls: procedure {s}", .{e.name}));
        if (has(&.{ "Module", "Prog" }, e.object) and !units.contains(unit))
            try out.append(a, try a.print("missing in zfls: program unit {s}", .{e.name}));
    }
    for (objs) |o| {
        if (o.in_interface or o.kind < 1 or o.kind > 4) continue;
        if ((o.kind == 2 or o.kind == 3) and o.parent_kind != 4 and !ifx_subs.contains(o.name()))
            try out.append(a, try a.print("missing in ifx: procedure {s}", .{o.fqsn}));
        if (o.kind == 1 and o.parent() == null and !ifx_subs.contains(o.name()))
            try out.append(a, try a.print("missing in ifx: program unit {s}", .{o.fqsn}));
    }
    // derived types
    var ifx_types: std.StringHashMapUnmanaged(void) = .empty;
    for (l.symbols) |e| if (std.mem.eql(u8, e.object, "Type")) try ifx_types.put(a, e.name, {});
    for (objs) |o| if (o.kind == 4 and !ifx_types.contains(o.name())) try out.append(a, try a.print("missing in ifx: type {s}", .{o.fqsn}));
    var tit = ifx_types.keyIterator();
    while (tit.next()) |t| if (!types.contains(t.*)) try out.append(a, try a.print("missing in zfls: type {s}", .{t.*}));
    // components and type-bound procedures
    var ifx_comps: std.StringHashMapUnmanaged(void) = .empty;
    for (l.components) |e| {
        const dot = std.mem.findScalar(u8, e.name, '.') orelse continue;
        // an extension's parent type is a component of it
        if (types.contains(e.name[dot + 1 ..]) and std.ascii.eqlIgnoreCase(e.type, e.name[dot + 1 ..])) continue;
        try ifx_comps.put(a, e.name, {});
        if (!components.contains(e.name)) try out.append(a, try a.print("missing in zfls: component {s}", .{e.name}));
    }
    var cit = components.keyIterator();
    while (cit.next()) |c| if (!ifx_comps.contains(c.*)) try out.append(a, try a.print("missing in ifx: component {s}", .{c.*}));
    // variables, with their types and attributes
    for (objs) |o| {
        if (o.kind != 6 or o.group or o.in_interface) continue;
        if (o.parent_kind == 4) {
            try checkVariable(a, &out, o, l.components, try a.print("{s}.{s}", .{ o.parentName(), o.name() }));
            continue;
        }
        // a function's result named as the function
        if (std.mem.eql(u8, o.parentName(), o.name())) continue;
        try checkVariable(a, &out, o, l.symbols, o.name());
    }
    for (l.symbols) |e| {
        if (!has(&.{ "Local", "Dummy", "Param", "Result" }, e.object)) continue;
        // Linux ifx's own name of a function's result, `dnrm@0`
        if (std.mem.findScalar(u8, e.name, '@') != null) continue;
        if (!vars.contains(e.name) and !procs.contains(e.name) and !hasInterfaceVar(objs, e.name))
            try out.append(a, try a.print("missing in zfls: variable {s} ({s})", .{ e.name, e.object }));
    }
    std.mem.sort([]const u8, out.items, {}, util.lessThan);
    return out;
}

fn hasInterfaceVar(objs: []const zfls_side.Object, name: []const u8) bool {
    for (objs) |o| if (o.kind == 6 and std.mem.eql(u8, o.name(), name)) return true;
    return false;
}

/// The entry of `entries` named `name` that agrees best with variable `o`:
/// a difference when none has its type, rank and attributes
fn checkVariable(a: Allocator, out: *Diffs, o: zfls_side.Object, entries: []const listing.Entry, name: []const u8) !void {
    var found = false;
    var why: []const u8 = "";
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (e.object.len > 0 and !has(&.{ "Local", "Dummy", "Param", "Result" }, e.object)) continue;
        found = true;
        why = try mismatch(a, o, e) orelse return;
    }
    if (!found) {
        try out.append(a, try a.print("missing in ifx: variable {s}", .{o.fqsn}));
    } else try out.append(a, try a.print("differs: {s}: {s}", .{ o.fqsn, why }));
}

/// How variable `o` and ifx's entry `e` differ, null when they agree
fn mismatch(a: Allocator, o: zfls_side.Object, e: listing.Entry) !?[]const u8 {
    const decl = o.declaration orelse return null;
    // the type and attributes, not the name nor the value
    const up = try std.ascii.allocUpperString(a, decl[0 .. std.mem.find(u8, decl, " :: ") orelse decl.len]);
    if (e.type.len > 0) if (try zfls_side.ifxTypes(a, zfls_side.typeSpec(decl))) |want| {
        var ok = false;
        for (want) |w| ok = ok or std.ascii.eqlIgnoreCase(w, e.type);
        if (!ok) return try a.print("type {s}, ifx {s}", .{ zfls_side.typeSpec(decl), e.type });
    };
    const r = zfls_side.rank(up);
    if ((e.rank orelse 0) != r) return try a.print("rank {d}, ifx {?d}", .{ r, e.rank });
    for ([_][2][]const u8{ .{ "ALLOCATABLE", "ALC" }, .{ "POINTER", "PTR" }, .{ "TARGET", "TGT" } }) |p| {
        const z = std.mem.find(u8, up, p[0]) != null;
        if (z != hasAttr(e.attrs, p[1])) return try a.print("{s} {}, ifx {s}", .{ p[0], z, e.attrs });
    }
    for ([_][2][]const u8{ .{ "INTENT(INOUT)", "INOUT" }, .{ "INTENT(IN)", "IN" }, .{ "INTENT(OUT)", "OUT" } }) |p| {
        if (std.mem.find(u8, up, p[0]) == null) continue;
        if (!hasAttr(e.attrs, p[1])) return try a.print("{s}, ifx {s}", .{ p[0], e.attrs });
        break;
    }
    return null;
}

/// A fixture's ifx options, written as on Windows (`/real-size:64`): on
/// Linux `-real-size 64`
fn ifxArgs(a: Allocator, args: []const []const u8) ![]const []const u8 {
    if (is_windows) return args;
    var out: std.ArrayList([]const u8) = .empty;
    for (args) |x| {
        if (x.len < 2 or x[0] != '/') {
            try out.append(a, x);
            continue;
        }
        const colon = std.mem.findScalar(u8, x, ':');
        try out.append(a, try a.print("-{s}", .{x[1 .. colon orelse x.len]}));
        if (colon) |c| try out.append(a, x[c + 1 ..]);
    }
    return out.items;
}

test ifxArgs {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try ifxArgs(arena.allocator(), &.{ "/real-size:64", "/fpp" });
    if (is_windows) return;
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("-real-size", got[0]);
    try std.testing.expectEqualStrings("64", got[1]);
    try std.testing.expectEqualStrings("-fpp", got[2]);
}

fn findIfx(io: Io, a: Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("IFX")) |x| return x;
    return util.findOnPath(io, a, env, "ifx");
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var ifx_arg: ?[]const u8 = null;
    var zfls: []const u8 = "zig-out/bin/zfls";
    var verbose = false;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if ((std.mem.eql(u8, arg, "--ifx") or std.mem.eql(u8, arg, "--zfls")) and i + 1 < argv.len) {
            i += 1;
            if (arg[2] == 'i') ifx_arg = argv[i] else zfls = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("usage: ifx_oracle [--ifx EXE] [--zfls EXE] [-v] [PATH ...]\n", .{});
            return if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) 0 else 2;
        } else try paths.append(a, arg);
    }
    const env = init.environ_map;
    const ifx = ifx_arg orelse try findIfx(io, a, env) orelse {
        std.debug.print("ifx not found; skipping\n", .{});
        return 0;
    };
    var ifx_env = try util.envWithDirOf(io, a, env, ifx);
    const version = try util.run(io, a, &.{ ifx, "--version" }, null, &ifx_env);
    var first = std.mem.splitScalar(u8, version.stdout, '\n');
    std.debug.print("ifx: {s} ({s})\n", .{ ifx, std.mem.trim(u8, first.next() orelse "?", " \r") });
    const fixtures = paths.items.len == 0;
    if (fixtures) try paths.appendSlice(a, &.{ "tests/fortran", "tests/ifx" });
    const files = try util.collect(io, a, paths.items, isFortran);
    const workdir = try lsp.tempDir(io, a, env, "zfls_ifx_");
    defer Io.Dir.cwd().deleteTree(io, workdir) catch {};
    var checked: usize = 0;
    var failed: usize = 0;
    for (files) |src| {
        const abs = try Io.Dir.cwd().realPathFileAlloc(io, src, a);
        const text = try Io.Dir.cwd().readFileAlloc(io, src, a, .limited(1 << 24));
        const lst = try std.Io.Dir.path.join(a, &.{ workdir, "out.lst" });
        Io.Dir.cwd().deleteFile(io, lst) catch {};
        var cmd: std.ArrayList([]const u8) = .empty;
        if (is_windows) {
            try cmd.appendSlice(a, &.{ ifx, "/nologo", "/c", try a.print("/list:{s}", .{lst}), "/show:map", try a.print("/module:{s}", .{workdir}), try a.print("/object:{s}\\", .{workdir}) });
        } else {
            try cmd.appendSlice(a, &.{ ifx, "-c", try a.print("-list={s}", .{lst}), "-show", "map", "-module", workdir, "-o", try std.Io.Dir.path.join(a, &.{ workdir, "out.o" }) });
        }
        const ext = std.Io.Dir.path.extension(src);
        const ext_lower = try std.ascii.allocLowerString(a, ext);
        if (!std.mem.eql(u8, ext, ext_lower) or std.mem.eql(u8, ext_lower, ".fpp")) try cmd.append(a, if (is_windows) "/fpp" else "-fpp");
        try cmd.appendSlice(a, try ifxArgs(a, try util.headerArgs(a, text, "oracle-ifx-args:")));
        try cmd.append(a, abs);
        const r = try util.run(io, a, cmd.items, workdir, &ifx_env);
        if (!r.ok) {
            std.debug.print("FAIL {s}: rejected by ifx: {s}\n", .{ src, util.failure(r) });
            failed += 1;
            continue;
        }
        const listed = Io.Dir.cwd().readFileAlloc(io, lst, a, .limited(1 << 26)) catch {
            std.debug.print("FAIL {s}: ifx wrote no listing\n", .{src});
            failed += 1;
            continue;
        };
        const l = try listing.parse(a, listed);
        var zcmd: std.ArrayList([]const u8) = .empty;
        // ifx's predefined symbols, as zfls takes them of the compiler
        // check's compiler (#509)
        try zcmd.appendSlice(a, &.{ zfls, "--debug_parser", "--debug_filepath", abs, "--compiler_diagnostics", "ifx", "--compiler_path", ifx });
        try zcmd.appendSlice(a, try util.headerArgs(a, text, "oracle-zfls-args:"));
        const z = try util.run(io, a, zcmd.items, null, null);
        const objs = (try zfls_side.objects(a, z.stdout)) orelse {
            std.debug.print("FAIL {s}: zfls produced no object tree\n", .{src});
            failed += 1;
            continue;
        };
        checked += 1;
        const diffs = try compare(a, l, objs);
        const base = std.Io.Dir.path.basename(src);
        var unexpected: std.ArrayList([]const u8) = .empty;
        var expected: usize = 0;
        for (diffs.items) |d| {
            if (known.isKnown(base, d)) expected += 1 else try unexpected.append(a, d);
        }
        if (unexpected.items.len == 0) {
            std.debug.print("OK   {s}: {d} symbols, {d} known differences\n", .{ src, l.symbols.len, expected });
            if (verbose) for (diffs.items) |d| std.debug.print("   known: {s}\n", .{d});
            continue;
        }
        failed += 1;
        std.debug.print("FAIL {s}\n", .{src});
        for (unexpected.items) |d| std.debug.print("   {s}\n", .{d});
    }
    std.debug.print("\n{d} files checked, {d} failures\n", .{ checked, failed });
    return if (failed > 0) 1 else 0;
}
