//! Cross-checks zfls's symbol extraction against gfortran's parse tree
//! (`zig build test-oracle`).
//!
//! Every Fortran file in the corpus that gfortran accepts is dumped with
//! `-fdump-fortran-original`. The user-declared scopes and entities found by
//! gfortran (modules, procedures, derived types and their components,
//! type-bound procedures, variables and parameters) are compared with the
//! object tree zfls prints with `--debug_parser`. gfortran serves as an
//! independent oracle for the Fortran semantics zfls approximates with
//! line-based parsing.
//!
//!     gfortran_oracle [--gfortran EXE] [--zfls EXE] [-v] [PATH ...]
//!
//! PATH defaults to tests/fortran (the zfls fixtures). Directories are
//! searched recursively; files gfortran rejects are skipped (and fail the
//! run for the fixtures, which are all valid Fortran).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp_client");

const fortran_exts = [_][]const u8{ ".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp" };

/// gfortran symbol attributes of entities zfls does not report
const skip_attrs = [_][]const u8{ "ARTIFICIAL", "INTRINSIC-PROC", "USE-ASSOC", "MODULE", "PROGRAM", "IFSRC-IFBODY" };
/// Attributes of procedures declared in the file (as opposed to procedures
/// that are only called)
const declared_proc_attrs = [_][]const u8{ "IFSRC-DECL", "CONTAINED", "MODULE-PROC", "GENERIC", "DUMMY", "EXTERNAL" };

// Known limitation (see `main`): dummy arguments of "MODULE PROCEDURE"
// bodies.

/// Entity categories compared between the two trees
const Kind = enum { variable, procedure, type, scope, other };

/// The category of an object kind of zfls's tree
fn zflsKind(code: i64) Kind {
    return switch (code) {
        // -1: MODULE PROCEDURE body in a submodule (plain scope until linked)
        -1, 2, 3, 5, 7 => .procedure,
        1, 8 => .scope,
        4 => .type,
        6 => .variable,
        else => .other,
    };
}

/// Procedure pointer components: gfortran variable, zfls type-bound method
fn sameKind(gfortran: Kind, zfls: Kind) bool {
    return gfortran == zfls or (gfortran == .variable and zfls == .procedure);
}

const Entities = std.array_hash_map.String(Kind);
const Names = std.StringHashMapUnmanaged(void);

fn has(set: []const []const u8, tokens: *const Names) bool {
    for (set) |t| if (tokens.contains(t)) return true;
    return false;
}

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    return i;
}

/// `procedure name = NAME`: its indent and name
fn procName(line: []const u8) ?struct { indent: usize, name: []const u8 } {
    const indent = indentOf(line);
    const rest = line[indent..];
    const key = "procedure name = ";
    if (!std.mem.startsWith(u8, rest, key)) return null;
    var words = std.mem.tokenizeAny(u8, rest[key.len..], " \t\r");
    return .{ .indent = indent, .name = words.next() orelse return null };
}

/// `symtree: 'X' || symbol: 'NAME' REST`: NAME and REST
fn symtree(line: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    const rest = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, rest, "symtree: '")) return null;
    const close = std.mem.findScalarPos(u8, rest, "symtree: '".len, '\'') orelse return null;
    var after = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    if (!std.mem.startsWith(u8, after, "|| symbol: '")) return null;
    after = after["|| symbol: '".len..];
    const end = std.mem.findScalar(u8, after, '\'') orelse return null;
    return .{ .name = after[0..end], .rest = after[end + 1 ..] };
}

fn trimmed(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// The name after `PREFIX...:: ` of a binding line, or null
fn bindingName(line: []const u8, prefix: []const u8) ?[]const u8 {
    const rest = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    const colons = std.mem.find(u8, rest, ":: ") orelse return null;
    if (std.mem.findScalar(u8, rest[prefix.len..colons], ':') != null) return null;
    const name = rest[colons + 3 ..];
    var n: usize = 0;
    while (n < name.len and (std.ascii.isAlphanumeric(name[n]) or name[n] == '_')) n += 1;
    return if (n > 0) name[0..n] else null;
}

/// `(NAME ` at the start of a component line
fn componentName(line: []const u8) ?[]const u8 {
    const rest = std.mem.trimStart(u8, line, " \t");
    if (rest.len == 0 or rest[0] != '(') return null;
    var n: usize = 1;
    while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
    if (n == 1 or n >= rest.len or rest[n] != ' ') return null;
    return rest[1..n];
}

fn lower(a: Allocator, s: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(a, s);
}

fn lastPart(s: []const u8, sep: []const u8) []const u8 {
    const i = std.mem.findLast(u8, s, sep) orelse return s;
    return s[i + sep.len ..];
}

const Gfortran = struct {
    entities: Entities = .empty,
    dummies: Names = .empty,
};

/// The entities in gfortran's dump of `text` (`-fdump-fortran-original`)
fn gfortranEntities(a: Allocator, dump: []const u8) !Gfortran {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    var out: Gfortran = .{};
    // submodule namespace -> its parent's
    var parents: std.StringHashMapUnmanaged([]const u8) = .empty;
    const Ns = struct { indent: usize, path: []const u8 };
    var stack: std.ArrayList(Ns) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (procName(line)) |p| {
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= p.indent) _ = stack.pop();
            var name = try lower(a, p.name);
            // submodules are named "ancestor.submodule"
            if (std.mem.findScalarLast(u8, name, '.')) |dot| if (stack.items.len == 0) {
                try parents.put(a, name[dot + 1 ..], lastPart(name[0..dot], "."));
            };
            name = lastPart(name, ".");
            const path = if (stack.items.len > 0)
                try a.print("{s}::{s}", .{ stack.items[stack.items.len - 1].path, name })
            else
                name;
            try stack.append(a, .{ .indent = p.indent, .path = path });
            i += 1;
            continue;
        }
        const sym = symtree(line) orelse {
            i += 1;
            continue;
        };
        if (stack.items.len == 0) {
            i += 1;
            continue;
        }
        const name = try lower(a, sym.name);
        const from_host = std.mem.find(u8, sym.rest, "from namespace") != null;
        // this symbol's detail lines
        i += 1;
        const block_start = i;
        while (i < lines.items.len and symtree(lines.items[i]) == null and procName(lines.items[i]) == null and
            std.mem.find(u8, lines.items[i], "Namespace:") == null) i += 1;
        const block = lines.items[block_start..i];
        var tokens: Names = .empty;
        for (block) |b| {
            const rest = std.mem.trimStart(u8, b, " \t");
            if (!std.mem.startsWith(u8, rest, "attributes: (")) continue;
            const close = std.mem.findScalarLast(u8, rest, ')') orelse continue;
            if (close < "attributes: (".len) continue;
            var words = std.mem.tokenizeAny(u8, rest["attributes: (".len..close], " \t");
            // e.g. "USE-ASSOC(shapes)" -> "USE-ASSOC"
            while (words.next()) |w| try tokens.put(a, w[0 .. std.mem.findScalar(u8, w, '(') orelse w.len], {});
            break;
        }
        const ns = stack.items[stack.items.len - 1].path;
        // Attributes gfortran 13 does not print, from what every version
        // does: generic interfaces list their procedures; the interface of a
        // separate module procedure is an external module procedure; a
        // submodule sees what its parent declares unless it contains it
        for (block) |b| if (std.mem.startsWith(u8, trimmed(b), "Generic interfaces:")) {
            try tokens.put(a, "GENERIC", {});
            break;
        };
        if (tokens.contains("MODULE-PROCEDURE") and tokens.contains("EXTERNAL") and !tokens.contains("CONTAINED"))
            try tokens.put(a, "IFSRC-IFBODY", {});
        if (parents.get(ns)) |parent| {
            const in_parent = try a.print("{s}::{s}", .{ parent, name });
            if (out.entities.contains(in_parent) and !tokens.contains("CONTAINED")) try tokens.put(a, "USED-IN-SUBMODULE", {});
        }
        const skip = from_host or
            std.mem.startsWith(u8, name, "_") or
            std.mem.eql(u8, name, lastPart(ns, "::")) or
            has(&skip_attrs, &tokens) or
            // parent-module entities seen from a submodule
            (tokens.contains("USED-IN-SUBMODULE") and !tokens.contains("MODULE-PROCEDURE"));
        if (skip) continue;
        const fq = try a.print("{s}::{s}", .{ ns, name });
        if (tokens.contains("DERIVED")) {
            try out.entities.put(a, fq, .type);
            var in_components = false;
            for (block) |b| {
                const t = trimmed(b);
                if (std.mem.startsWith(u8, t, "components:")) {
                    in_components = true;
                    continue;
                }
                if (std.mem.startsWith(u8, t, "hash:") or std.mem.startsWith(u8, t, "Procedure bindings")) in_components = false;
                if (if (in_components) componentName(b) else null) |c| {
                    // the parent type of an extension is a component too
                    const parent_type = try a.print("(derived {s})", .{try lower(a, c)});
                    if (std.mem.find(u8, try lower(a, b), parent_type) == null)
                        try out.entities.put(a, try a.print("{s}::{s}", .{ fq, try lower(a, c) }), .variable);
                }
                if (bindingName(b, "PROCEDURE") orelse bindingName(b, "GENERIC")) |m|
                    try out.entities.put(a, try a.print("{s}::{s}", .{ fq, try lower(a, m) }), .procedure);
            }
        } else if (tokens.contains("PROCEDURE")) {
            if (tokens.contains("ABSTRACT")) continue; // abstract interface
            if (!has(&declared_proc_attrs, &tokens)) continue; // only referenced (implicit external procedure)
            // structure constructors are generics named like their type
            const gop = try out.entities.getOrPut(a, fq);
            if (!gop.found_existing) gop.value_ptr.* = .procedure;
        } else if (tokens.contains("VARIABLE") or tokens.contains("PARAMETER")) {
            try out.entities.put(a, fq, .variable);
            if (tokens.contains("DUMMY")) try out.dummies.put(a, fq, {});
        }
    }
    return out;
}

const Zfls = struct {
    entities: Entities = .empty,
    /// MODULE PROCEDURE bodies
    bodies: Names = .empty,
};

/// The entities of zfls's object tree (`--debug_parser` output), null when
/// it printed none
fn zflsEntities(a: Allocator, out: []const u8) !?Zfls {
    const start = std.mem.find(u8, out, "Object Tree") orelse return null;
    var tree = out[start + "Object Tree".len ..];
    if (std.mem.find(u8, tree, "Exportable Objects")) |end| tree = tree[0..end];
    const Row = struct { kind: i64, fqsn: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.find(u8, line, ": ") orelse continue;
        const kind = std.fmt.parseInt(i64, line[0..colon], 10) catch continue;
        const fqsn = line[colon + 2 ..];
        if (fqsn.len == 0 or std.mem.findAny(u8, fqsn, " \t") != null) continue;
        try rows.append(a, .{ .kind = kind, .fqsn = fqsn });
    }
    // block, select, do, where, if, associate and enum scopes
    var constructs: Names = .empty;
    for (rows.items) |r| if (r.kind >= 9 and r.kind <= 15) try constructs.put(a, r.fqsn, {});
    var res: Zfls = .{};
    for (rows.items) |r| {
        if (std.mem.find(u8, try lower(a, r.fqsn), "#gen_int") != null) continue; // interface bodies (not listed by the oracle)
        if (constructs.contains(r.fqsn)) continue;
        // entities of construct scopes belong to the enclosing procedure in
        // gfortran
        var kept: std.ArrayList(u8) = .empty;
        var parts = std.mem.splitSequence(u8, r.fqsn, "::");
        var prefix_end: usize = 0;
        while (parts.next()) |p| {
            prefix_end += p.len;
            if (!constructs.contains(r.fqsn[0..prefix_end])) {
                if (kept.items.len > 0) try kept.appendSlice(a, "::");
                try kept.appendSlice(a, p);
            }
            prefix_end += 2;
        }
        if (r.kind == -1) try res.bodies.put(a, kept.items, {});
        try res.entities.put(a, kept.items, zflsKind(r.kind));
    }
    // scopes found by gfortran as namespaces, not entities
    var i: usize = 0;
    while (i < res.entities.count()) {
        if (std.mem.find(u8, res.entities.keys()[i], "::") == null) {
            res.entities.swapRemoveAt(i);
        } else i += 1;
    }
    return res;
}

/// zfls lists a function's implicit result variable as a child
fn isFunctionResult(fq: []const u8) bool {
    const sep = std.mem.findLast(u8, fq, "::") orelse return false;
    return std.mem.eql(u8, lastPart(fq[0..sep], "::"), fq[sep + 2 ..]);
}

fn findOnPath(io: Io, a: Allocator, env: *const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const path = env.get("PATH") orelse env.get("Path") orelse return null;
    const exe = if (builtin.target.os.tag == .windows) try a.print("{s}.exe", .{name}) else name;
    var dirs = std.mem.tokenizeScalar(u8, path, if (builtin.target.os.tag == .windows) ';' else ':');
    while (dirs.next()) |d| {
        const candidate = try std.Io.Dir.path.join(a, &.{ d, exe });
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
    }
    return null;
}

fn findGfortran(io: Io, a: Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("GFORTRAN")) |g| return g;
    if (try findOnPath(io, a, env, "gfortran")) |g| return g;
    if (builtin.target.os.tag == .windows) {
        const msys = "C:\\msys64\\ucrt64\\bin\\gfortran.exe";
        if (Io.Dir.cwd().access(io, msys, .{})) |_| return msys else |_| {}
    }
    return null;
}

const Run = struct { stdout: []const u8, stderr: []const u8, ok: bool, code: []const u8 };

fn run(io: Io, a: Allocator, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) !Run {
    const r = try std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .create_no_window = true,
    });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .ok = r.term.success(), .code = try lsp.termText(a, r.term) };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn collect(io: Io, a: Allocator, paths: []const []const u8) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (Io.Dir.cwd().openDir(io, p, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(io);
            var found: std.ArrayList([]const u8) = .empty;
            var walker = try dir.walk(a);
            defer walker.deinit();
            while (try walker.next(io)) |e| {
                if (e.kind != .file) continue;
                const ext = std.Io.Dir.path.extension(e.basename);
                for (fortran_exts) |x| {
                    if (std.ascii.eqlIgnoreCase(ext, x)) break;
                } else continue;
                try found.append(a, try std.Io.Dir.path.join(a, &.{ p, e.path }));
            }
            std.mem.sort([]const u8, found.items, {}, lessThan);
            try files.appendSlice(a, found.items);
        } else |_| try files.append(a, p);
    }
    return files.items;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var gfortran_arg: ?[]const u8 = null;
    var zfls: []const u8 = "zig-out/bin/zfls";
    var verbose = false;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if ((std.mem.eql(u8, arg, "--gfortran") or std.mem.eql(u8, arg, "--zfls")) and i + 1 < argv.len) {
            i += 1;
            if (arg[2] == 'g') gfortran_arg = argv[i] else zfls = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("usage: gfortran_oracle [--gfortran EXE] [--zfls EXE] [-v] [PATH ...]\n", .{});
            return if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) 0 else 2;
        } else try paths.append(a, arg);
    }
    const env = init.environ_map;
    const gfortran = gfortran_arg orelse try findGfortran(io, a, env) orelse {
        std.debug.print("gfortran not found; skipping\n", .{});
        return 0;
    };
    // gfortran's own directory first on PATH, so that on Windows its
    // compiler loads the DLLs it was built with rather than other copies
    // (Git for Windows' bash puts its own first)
    var gf_env = try env.clone(a);
    const gf_exe = if (std.Io.Dir.path.dirname(gfortran) == null) (try findOnPath(io, a, env, gfortran)) orelse gfortran else gfortran;
    if (std.Io.Dir.path.dirname(gf_exe)) |dir| {
        const key = if (env.get("PATH") == null and env.get("Path") != null) "Path" else "PATH";
        const old = env.get(key) orelse "";
        try gf_env.put(key, try a.print("{s}{c}{s}", .{ dir, if (builtin.target.os.tag == .windows) @as(u8, ';') else ':', old }));
    }
    const version = try run(io, a, &.{ gfortran, "--version" }, null, &gf_env);
    var first = std.mem.splitScalar(u8, version.stdout, '\n');
    std.debug.print("gfortran: {s} ({s})\n", .{ gfortran, std.mem.trim(u8, first.next() orelse "?", " \r") });
    // every fixture is valid Fortran; other corpora may contain files that
    // are not
    const fixtures = paths.items.len == 0;
    if (fixtures) try paths.append(a, "tests/fortran");
    const files = try collect(io, a, paths.items);
    const workdir = try lsp.tempDir(io, a, env, "zfls_gfortran_");
    defer Io.Dir.cwd().deleteTree(io, workdir) catch {};
    var checked: usize = 0;
    var mismatched: usize = 0;
    for (files) |src| {
        const abs = try Io.Dir.cwd().realPathFileAlloc(io, src, a);
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(a, &.{ gfortran, "-fsyntax-only", "-fdump-fortran-original", "-J", workdir, "-I", workdir });
        const ext = std.Io.Dir.path.extension(src);
        const ext_lower = try lower(a, ext);
        if (!std.mem.eql(u8, ext, ext_lower) or std.mem.eql(u8, ext_lower, ".fpp")) try cmd.append(a, "-cpp");
        if (std.mem.eql(u8, ext_lower, ".f") or std.mem.eql(u8, ext_lower, ".for")) try cmd.append(a, "-ffixed-form");
        try cmd.append(a, abs);
        const g = try run(io, a, cmd.items, workdir, &gf_env);
        if (!g.ok) {
            var why: []const u8 = g.code;
            var lines = std.mem.splitScalar(u8, g.stderr, '\n');
            var first_line: ?[]const u8 = null;
            while (lines.next()) |l| {
                const t = std.mem.trim(u8, l, " \r\t");
                if (t.len == 0) continue;
                if (first_line == null) first_line = t;
                if (std.mem.find(u8, t, "rror") != null) {
                    why = t;
                    break;
                }
            } else if (first_line) |f| why = f;
            if (fixtures) {
                std.debug.print("FAIL {s}: rejected by gfortran: {s}\n", .{ src, why });
                mismatched += 1;
            } else if (verbose) std.debug.print("SKIP {s} (rejected by gfortran: {s})\n", .{ src, why });
            continue;
        }
        var ref = try gfortranEntities(a, g.stdout);
        const z = try run(io, a, &.{ zfls, "--debug_parser", "--debug_filepath", abs }, null, null);
        var got = (try zflsEntities(a, z.stdout)) orelse {
            std.debug.print("FAIL {s}: zfls produced no object tree\n", .{src});
            mismatched += 1;
            continue;
        };
        var k: usize = 0;
        while (k < got.entities.count()) {
            if (isFunctionResult(got.entities.keys()[k])) got.entities.swapRemoveAt(k) else k += 1;
        }
        // Arguments of "MODULE PROCEDURE name" bodies come from the
        // interface in the ancestor module; zfls only attaches them when
        // linking a workspace, which --debug_parser does not do
        var dummies = ref.dummies.keyIterator();
        while (dummies.next()) |d| {
            const scope = d.*[0 .. std.mem.findLast(u8, d.*, "::") orelse d.len];
            if (got.bodies.contains(scope)) _ = ref.entities.swapRemove(d.*);
        }
        checked += 1;
        var missing: std.ArrayList([]const u8) = .empty;
        var extra: std.ArrayList([]const u8) = .empty;
        var kinds: std.ArrayList([]const u8) = .empty;
        for (ref.entities.keys(), ref.entities.values()) |name, kind| {
            if (got.entities.get(name)) |zk| {
                if (!sameKind(kind, zk)) try kinds.append(a, name);
            } else try missing.append(a, name);
        }
        for (got.entities.keys()) |name| if (!ref.entities.contains(name)) try extra.append(a, name);
        for ([_]*std.ArrayList([]const u8){ &missing, &extra, &kinds }) |l| std.mem.sort([]const u8, l.items, {}, lessThan);
        if (missing.items.len + extra.items.len + kinds.items.len == 0) {
            std.debug.print("OK   {s}: {d} entities\n", .{ src, ref.entities.count() });
            continue;
        }
        mismatched += 1;
        std.debug.print("FAIL {s}\n", .{src});
        for (missing.items) |n| std.debug.print("   missing in zfls: {s} ({s})\n", .{ n, @tagName(ref.entities.get(n).?) });
        for (extra.items) |n| std.debug.print("   only in zfls:    {s} ({s})\n", .{ n, @tagName(got.entities.get(n).?) });
        for (kinds.items) |n| std.debug.print("   kind differs:    {s} gfortran={s} zfls={s}\n", .{ n, @tagName(ref.entities.get(n).?), @tagName(got.entities.get(n).?) });
    }
    std.debug.print("\n{d} files checked, {d} with differences\n", .{ checked, mismatched });
    return if (mismatched > 0) 1 else 0;
}

test "dump parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dump =
        \\Namespace: A-Z: (UNKNOWN 0)
        \\procedure name = shapes
        \\  symtree: 'circle'      || symbol: 'circle'
        \\    type spec : (UNKNOWN 0)
        \\    attributes: (DERIVED  PUBLIC)
        \\    components:
        \\      (r (REAL 8) () PRIVATE)
        \\    Procedure bindings:
        \\      PROCEDURE  area => circle_area :: area
        \\  symtree: 'circle_area' || symbol: 'circle_area'
        \\    attributes: (PROCEDURE MODULE-PROC  DECL FUNCTION IMPLICIT-SAVE)
        \\  symtree: 'pi'          || symbol: 'pi'
        \\    attributes: (PARAMETER IMPLICIT-SAVE)
        \\  symtree: 'shapes'      || symbol: 'shapes'
        \\    attributes: (MODULE)
    ;
    const g = try gfortranEntities(a, dump);
    try std.testing.expectEqual(.type, g.entities.get("shapes::circle").?);
    try std.testing.expectEqual(.variable, g.entities.get("shapes::circle::r").?);
    try std.testing.expectEqual(.procedure, g.entities.get("shapes::circle::area").?);
    try std.testing.expectEqual(.procedure, g.entities.get("shapes::circle_area").?);
    try std.testing.expectEqual(.variable, g.entities.get("shapes::pi").?);
    try std.testing.expectEqual(5, g.entities.count());

    const z = (try zflsEntities(a,
        \\=== Object Tree ===
        \\1: shapes
        \\4: shapes::circle
        \\9: shapes::f::block1
        \\6: shapes::f::block1::x
        \\2: shapes::f
        \\6: shapes::f::f
        \\=== Exportable Objects ===
        \\6: ignored::x
    )).?;
    try std.testing.expectEqual(4, z.entities.count());
    try std.testing.expectEqual(.variable, z.entities.get("shapes::f::x").?);
    try std.testing.expect(isFunctionResult("shapes::f::f"));
    try std.testing.expect(!isFunctionResult("shapes::f::x"));
}
