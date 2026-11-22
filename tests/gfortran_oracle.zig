//! Cross-checks zfls's symbol extraction against gfortran's parse tree
//! (`zig build test-oracle`).
//!
//! Every Fortran file in the corpus that gfortran accepts is dumped with
//! `-fdump-fortran-original`. The user-declared scopes and entities found by
//! gfortran (modules, procedures, derived types and their components,
//! type-bound procedures, variables and parameters) are compared with the
//! object tree zfls prints with `--debug_parser`, and each variable's type
//! and kind, rank, ALLOCATABLE, POINTER, TARGET and INTENT with what zfls's
//! hover declares (gfortran_oracle/types.zig, #551); the associate names
//! of the blocks of SELECT TYPE and RANK each with its own block's
//! temporary (gfortran_oracle/guards.zig), and the names of ASSOCIATE
//! constructs each with its own construct's (gfortran_oracle/associates.zig).
//! gfortran serves as an
//! independent oracle for the Fortran semantics zfls approximates with
//! line-based parsing. The differences known, each with its reason, are in
//! gfortran_oracle/known.zig.
//!
//!     gfortran_oracle [--gfortran EXE] [--zfls EXE] [-v] [PATH ...]
//!
//! PATH defaults to tests/fortran (the zfls fixtures) and tests/gfortran
//! (gfortran's dialect); CI also runs it on fortls's corpus
//! (`_fortls/test/test_source`). Directories are searched recursively; files
//! gfortran rejects are skipped (and fail the run for the fixtures, which
//! are all valid Fortran). A fixture can give gfortran or zfls arguments on
//! an `oracle-gfortran-args:` / `oracle-zfls-args:` line among its first
//! ten (`! oracle-gfortran-args: -fdec-static`), and the oldest gfortran
//! that reads it on an `oracle-gfortran-min:` line (`16`): older ones skip
//! it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp_client");
const util = @import("oracle_util.zig");
const types = @import("gfortran_oracle/types.zig");
const known = @import("gfortran_oracle/known.zig");
const guards = @import("gfortran_oracle/guards.zig");
const associates = @import("gfortran_oracle/associates.zig");
const oz = @import("oracle_zfls.zig");

const fortran_exts = [_][]const u8{ ".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp" };

/// gfortran symbol attributes of entities zfls does not report
const skip_attrs = [_][]const u8{ "ARTIFICIAL", "INTRINSIC-PROC", "USE-ASSOC", "MODULE", "PROGRAM", "IFSRC-IFBODY", "UNLIMITED-POLYMORPHIC" };
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
    /// what the dump says of each variable
    vars: std.StringHashMapUnmanaged(types.Var) = .empty,
    /// the temporaries of the blocks of SELECT TYPE and RANK
    temps: guards.Temps = .{},
    /// the names of ASSOCIATE constructs
    assocs: associates.Reader = .{},
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
    // the components of each DEC structure, union and map (by the dump's
    // name), and the structures to give fields
    var records: std.StringHashMapUnmanaged([]const types.Component) = .empty;
    const Pending = struct { fq: []const u8, name: []const u8 };
    var structures: std.ArrayList(Pending) = .empty;
    var listings: guards.Reader = .{};
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (procName(line)) |p| {
            out.assocs.open = null;
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
            if (stack.items.len > 0) out.assocs.line(stack.items[stack.items.len - 1].path, line);
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
        // gfortran 13 and 14 print no IFSRC-IFBODY (16 does), which these
        // are (14.4): an interface body (`MODULE-PROC EXTERNAL`) or a
        // procedure declaration (`IMPLICIT-SAVE EXTERNAL`), not an EXTERNAL
        // statement (`EXTERNAL-PROC EXTERNAL`); a dummy procedure of an
        // interface body (`DUMMY` without EXTERNAL; one of `procedure(i)`
        // is `EXTERNAL DUMMY`, as an EXTERNAL statement's is); a submodule's
        // copy of a separate module procedure it does not implement
        if (tokens.contains("PROCEDURE") and !tokens.contains("CONTAINED") and !tokens.contains("IFSRC-DECL")) {
            const body = (tokens.contains("EXTERNAL") and !tokens.contains("EXTERNAL-PROC") and !tokens.contains("DUMMY")) or
                (tokens.contains("DUMMY") and !tokens.contains("EXTERNAL")) or
                tokens.contains("MODULE-PROCEDURE");
            if (body) try tokens.put(a, "IFSRC-IFBODY", {});
        }
        if (parents.get(ns)) |parent| {
            const in_parent = try a.print("{s}::{s}", .{ parent, name });
            if (out.entities.contains(in_parent) and !tokens.contains("CONTAINED")) try tokens.put(a, "USED-IN-SUBMODULE", {});
        }
        // an associate name is ASSOCIATE-VAR (gfortran 13 and 14: and not
        // SELECT-TYPE-TEMPORARY), a temporary SELECT-TYPE-TEMPORARY too
        const temp = guards.isTemp(name) and tokens.contains("SELECT-TYPE-TEMPORARY");
        const assoc = !temp and (tokens.contains("ASSOCIATE-VAR") or tokens.contains("SELECT-TYPE-TEMPORARY"));
        try listings.symbol(a, &out.temps, ns, indentOf(line), name, block, temp, assoc);
        const in_assoc = try out.assocs.symbol(a, indentOf(line), name, block, assoc);
        // the code after the symbols: a construct's ASSOCIATE or CHANGE
        // TEAM line
        for (block) |b| if (indentOf(b) <= indentOf(line)) out.assocs.line(ns, b);
        if (temp) continue;
        const skip = from_host or
            std.mem.startsWith(u8, name, "_") or
            // gfortran's own procedures (`__copy_character_1`)
            std.mem.startsWith(u8, lastPart(ns, "::"), "_") or
            std.mem.eql(u8, name, lastPart(ns, "::")) or
            has(&skip_attrs, &tokens) or
            // parent-module entities seen from a submodule
            (tokens.contains("USED-IN-SUBMODULE") and !tokens.contains("MODULE-PROCEDURE"));
        if (skip) continue;
        const fq = try a.print("{s}::{s}", .{ ns, name });
        if (tokens.contains("STRUCTURE") or tokens.contains("UNION")) {
            // DEC's: a structure is a type, whose unions' maps' fields are
            // its own
            try records.put(a, sym.name, try types.components(a, block));
            if (types.isArtificial(sym.name)) continue;
            try out.entities.put(a, fq, .type);
            try structures.append(a, .{ .fq = fq, .name = sym.name });
        } else if (tokens.contains("DERIVED")) {
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
            // those of ASSOCIATE constructs each with its own construct's
            if (!in_assoc) try out.vars.put(a, fq, types.varOf(block));
            if (tokens.contains("DUMMY")) try out.dummies.put(a, fq, {});
        }
    }
    for (structures.items) |s| {
        var names: std.ArrayList([]const u8) = .empty;
        try types.fields(a, &records, s.name, &names);
        for (names.items) |f| try out.entities.put(a, try a.print("{s}::{s}", .{ s.fq, try lower(a, f) }), .variable);
    }
    return out;
}

const Zfls = struct {
    entities: Entities = .empty,
    /// MODULE PROCEDURE bodies
    bodies: Names = .empty,
    /// the first line of each variable's hover (its Declarations), but of
    /// the associate names of blocks of SELECT TYPE and RANK
    decls: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// those, in the order of the source
    blocks: std.ArrayList(guards.Block) = .empty,
    /// and of the names of ASSOCIATE constructs
    assocs: std.ArrayList(associates.Zname) = .empty,
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
    var declared: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (std.mem.find(u8, out, "\nDeclarations")) |d| {
        var lines = std.mem.splitScalar(u8, out[d..], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const sep = std.mem.find(u8, line, ": ") orelse continue;
            try declared.put(a, line[0..sep], line[sep + 2 ..]);
        }
    }
    const select_blocks = try oz.selectBlocks(a, out);
    const assoc_lines = try oz.associates(a, out);
    var block_seen: Names = .empty;
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
        if (declared.get(r.fqsn)) |d| {
            const parent = r.fqsn[0 .. std.mem.findLast(u8, r.fqsn, "::") orelse 0];
            if (select_blocks.get(try lower(a, parent))) |b| {
                // the tree lists an object under each scope it is in
                if ((try block_seen.getOrPut(a, r.fqsn)).found_existing) continue;
                const select = parent[0 .. std.mem.findLast(u8, parent, "::") orelse 0];
                try res.blocks.append(a, .{ .key = kept.items, .select = select, .select_line = b.select_line, .line = b.line, .decl = d });
            } else if (assoc_lines.get(try lower(a, parent))) |l| {
                if ((try block_seen.getOrPut(a, r.fqsn)).found_existing) continue;
                const ns = kept.items[0 .. std.mem.findLast(u8, kept.items, "::") orelse 0];
                try res.assocs.append(a, .{ .key = kept.items, .ns = ns, .construct = try lower(a, parent), .line = l, .decl = d });
            } else try res.decls.put(a, kept.items, d);
        }
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

fn sourceLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    return out.items;
}

/// zfls lists a function's implicit result variable as a child
fn isFunctionResult(fq: []const u8) bool {
    const sep = std.mem.findLast(u8, fq, "::") orelse return false;
    return std.mem.eql(u8, lastPart(fq[0..sep], "::"), fq[sep + 2 ..]);
}

fn findGfortran(io: Io, a: Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("GFORTRAN")) |g| return g;
    if (try util.findOnPath(io, a, env, "gfortran")) |g| return g;
    if (builtin.target.os.tag == .windows) {
        const msys = "C:\\msys64\\ucrt64\\bin\\gfortran.exe";
        if (Io.Dir.cwd().access(io, msys, .{})) |_| return msys else |_| {}
    }
    return null;
}

fn isFortran(name: []const u8) bool {
    const ext = std.Io.Dir.path.extension(name);
    for (fortran_exts) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

/// The major version of the first line of `gfortran --version`, `GNU
/// Fortran (...) 16.1.0`
fn majorVersion(line: []const u8) ?u32 {
    const last = line[(std.mem.findScalarLast(u8, line, ' ') orelse return null) + 1 ..];
    return std.fmt.parseInt(u32, last[0 .. std.mem.findScalar(u8, last, '.') orelse last.len], 10) catch null;
}

test majorVersion {
    try std.testing.expectEqual(@as(?u32, 13), majorVersion("GNU Fortran (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0"));
    try std.testing.expectEqual(@as(?u32, 16), majorVersion("GNU Fortran (Rev5, Built by MSYS2 project) 16.1.0"));
    try std.testing.expectEqual(@as(?u32, null), majorVersion("?"));
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
    // gfortran's own directory first on PATH
    var gf_env = try util.envWithDirOf(io, a, env, gfortran);
    const version = try util.run(io, a, &.{ gfortran, "--version" }, null, &gf_env);
    var first = std.mem.splitScalar(u8, version.stdout, '\n');
    const first_line = std.mem.trim(u8, first.next() orelse "?", " \r");
    std.debug.print("gfortran: {s} ({s})\n", .{ gfortran, first_line });
    const major = majorVersion(first_line);
    // every fixture is valid Fortran; other corpora may contain files that
    // are not
    const fixtures = paths.items.len == 0;
    if (fixtures) try paths.appendSlice(a, &.{ "tests/fortran", "tests/gfortran" });
    const files = try util.collect(io, a, paths.items, isFortran);
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
        const text = try Io.Dir.cwd().readFileAlloc(io, src, a, .limited(1 << 24));
        // F2018 that only gfortran 16 reads (CRITICAL with STAT=, #722)
        const min = try util.headerArgs(a, text, "oracle-gfortran-min:");
        const want: ?u32 = if (min.len > 0) std.fmt.parseInt(u32, min[0], 10) catch null else null;
        if (want) |m| if (major) |have| if (have < m) {
            std.debug.print("SKIP {s} (gfortran {d} is older than its {d})\n", .{ src, have, m });
            continue;
        };
        const own_args = try util.headerArgs(a, text, "oracle-gfortran-args:");
        try cmd.appendSlice(a, own_args);
        try cmd.append(a, abs);
        const g = try util.run(io, a, cmd.items, workdir, &gf_env);
        if (!g.ok) {
            const why = util.failure(g);
            // an option of the fixture's that this gfortran has not
            // (`-funsigned` before GCC 15)
            if (own_args.len > 0 and std.mem.find(u8, why, "unrecognized command-line option") != null) {
                std.debug.print("SKIP {s} (this gfortran has not its options: {s})\n", .{ src, why });
                continue;
            }
            if (fixtures) {
                std.debug.print("FAIL {s}: rejected by gfortran: {s}\n", .{ src, why });
                mismatched += 1;
            } else if (verbose) std.debug.print("SKIP {s} (rejected by gfortran: {s})\n", .{ src, why });
            continue;
        }
        var ref = try gfortranEntities(a, g.stdout);
        var zcmd: std.ArrayList([]const u8) = .empty;
        // gfortran's predefined macros, as zfls takes them of the compiler
        // check's compiler (#541)
        try zcmd.appendSlice(a, &.{ zfls, "--debug_parser", "--debug_filepath", abs, "--compiler_diagnostics", "gfortran", "--compiler_path", gfortran });
        try zcmd.appendSlice(a, try util.headerArgs(a, text, "oracle-zfls-args:"));
        const z = try util.run(io, a, zcmd.items, null, null);
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
        var diffs: std.ArrayList([]const u8) = .empty;
        for (ref.entities.keys(), ref.entities.values()) |name, kind| {
            if (got.entities.get(name)) |zk| {
                if (!sameKind(kind, zk)) try diffs.append(a, try a.print("kind differs: {s} gfortran={s} zfls={s}", .{ name, @tagName(kind), @tagName(zk) }));
            } else try diffs.append(a, try a.print("missing in zfls: {s} ({s})", .{ name, @tagName(kind) }));
        }
        for (got.entities.keys(), got.entities.values()) |name, zk| if (!ref.entities.contains(name))
            try diffs.append(a, try a.print("only in zfls: {s} ({s})", .{ name, @tagName(zk) }));
        // the associate names of blocks of SELECT TYPE and RANK, each with
        // its block's temporary
        try guards.check(a, &diffs, &ref.vars, &ref.temps, got.blocks.items, try sourceLines(a, text));
        try associates.check(a, &diffs, ref.assocs.names.items, got.assocs.items);
        var vit = ref.vars.iterator();
        while (vit.next()) |e| {
            const decl = got.decls.get(e.key_ptr.*) orelse continue;
            if (try types.mismatch(a, e.value_ptr.*, decl)) |why| try diffs.append(a, try a.print("differs: {s}: {s}", .{ e.key_ptr.*, why }));
        }
        std.mem.sort([]const u8, diffs.items, {}, util.lessThan);
        const base = std.Io.Dir.path.basename(src);
        var unexpected: std.ArrayList([]const u8) = .empty;
        var expected: usize = 0;
        for (diffs.items) |d| {
            if (known.isKnown(base, d)) expected += 1 else try unexpected.append(a, d);
        }
        if (unexpected.items.len == 0) {
            std.debug.print("OK   {s}: {d} entities, {d} known differences\n", .{ src, ref.entities.count(), expected });
            if (verbose) for (diffs.items) |d| std.debug.print("   known: {s}\n", .{d});
            continue;
        }
        mismatched += 1;
        std.debug.print("FAIL {s}\n", .{src});
        for (unexpected.items) |d| std.debug.print("   {s}\n", .{d});
    }
    std.debug.print("\n{d} files checked, {d} with differences\n", .{ checked, mismatched });
    return if (mismatched > 0) 1 else 0;
}

test {
    _ = guards;
    _ = associates;
}

test "the temporaries of type guards take the associate name listed after them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // gfortran 13 and 14: the temporaries' names have no associate name,
    // nor is the associate name SELECT-TYPE-TEMPORARY
    const g = try gfortranEntities(arena.allocator(),
        \\Namespace: A-Z: (UNKNOWN 0)
        \\procedure name = m
        \\  procedure name = s
        \\    symtree: 'items'       || symbol: 'items'
        \\      type spec : (CLASS __class_m_Base_t_1_0t)
        \\      attributes: (VARIABLE  DUMMY(IN) CLASS-OK)
        \\    code:
        \\    SELECT TYPE  it = s:items % _data(FULL)
        \\      symtree: '__tmp_type_base_t'|| symbol: '__tmp_type_base_t'
        \\        type spec : (DERIVED base_t)
        \\        attributes: (VARIABLE  DIMENSION POINTER TARGET SELECT-TYPE-TEMPORARY ASSOCIATE-VAR HOST-ASSOC)
        \\        Array spec:(1 [0] AS_DEFERRED () () )
        \\      symtree: 'it'          || symbol: 'it'
        \\        type spec : (CLASS __class_m_Base_t_1_0p)
        \\        attributes: (VARIABLE  ASSOCIATE-VAR)
        \\      SELECT CASE x
        \\    SELECT TYPE
        \\      symtree: '__tmp_REAL_8'|| symbol: '__tmp_REAL_8'
        \\        type spec : (REAL 8)
        \\        attributes: (VARIABLE  SELECT-TYPE-TEMPORARY ASSOCIATE-VAR HOST-ASSOC)
        \\      symtree: 'size'        || symbol: 'size'
        \\        attributes: (PROCEDURE INTRINSIC-PROC)
        \\      SELECT CASE y
    );
    try std.testing.expectEqual(2, g.temps.temps.items.len);
    try std.testing.expectEqual(2, g.temps.groups.items.len);
    try std.testing.expectEqualStrings("it", g.temps.groups.items[0].assoc);
    try std.testing.expectEqual(1, g.temps.temps.items[0].v.rank);
    try std.testing.expectEqualStrings("", g.temps.groups.items[1].assoc);
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

test "each ASSOCIATE construct's names with their own construct's (#754)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // gfortran 16.1, fortls's test/test_source/hover/associate_block.f90
    // (an excerpt): two constructs name `x`
    const g = try gfortranEntities(a,
        \\Namespace: A-Z: (UNKNOWN 0)
        \\procedure name = test_associate_block
        \\  symtree: 'a'           || symbol: 'a'
        \\    type spec : (REAL 4)
        \\    attributes: (VARIABLE  DIMENSION IMPLICIT-SAVE)
        \\    Array spec:(1 [0] AS_EXPLICIT 1 5 )
        \\
        \\  code:
        \\
        \\  ASSOCIATE  x = test_associate_block:a(FULL)
        \\    symtree: 'block@1'     || symbol: 'block@1'
        \\      type spec : (UNKNOWN 0)
        \\      attributes: (LABEL  ARRAY-OUTER-DEPENDENCY)
        \\    symtree: 'x'           || symbol: 'x'
        \\      type spec : (REAL 4)
        \\      attributes: (VARIABLE  DIMENSION ASSOCIATE-VAR)
        \\      Array spec:(1 [0] AS_DEFERRED () () )
        \\    WRITE UNIT=6 FMT=-1
        \\    TRANSFER block@1:x(FULL)
        \\    DT_END
        \\  END ASSOCIATE
        \\
        \\  ASSOCIATE  x = 1
        \\    symtree: 'block@2'     || symbol: 'block@2'
        \\      type spec : (UNKNOWN 0)
        \\      attributes: (LABEL )
        \\    symtree: 'x'           || symbol: 'x'
        \\      type spec : (INTEGER 4)
        \\      attributes: (VARIABLE  ASSOCIATE-VAR)
        \\    WRITE UNIT=6 FMT=-1
        \\    TRANSFER block@2:x
        \\    DT_END
        \\  END ASSOCIATE
    );
    try std.testing.expectEqual(2, g.assocs.names.items.len);
    try std.testing.expectEqual(2, g.assocs.names.items[1].n);
    // not compared by name alone
    try std.testing.expect(!g.vars.contains("test_associate_block::x"));
    const tree =
        \\Object Tree
        \\1: test_associate_block
        \\  6: test_associate_block::a
        \\  14: test_associate_block::#assoc1
        \\    6: test_associate_block::#assoc1::x
        \\  14: test_associate_block::#assoc2
        \\    6: test_associate_block::#assoc2::x
        \\Exportable Objects
        \\1: test_associate_block
        \\================================================================================
        \\Associate Constructs
        \\================================================================================
        \\
        \\test_associate_block::#assoc1: 4
        \\test_associate_block::#assoc2: 7
        \\
        \\================================================================================
        \\Declarations
        \\================================================================================
        \\
        \\test_associate_block::a: REAL, DIMENSION(5) :: A
        \\
    ;
    const right = (try zflsEntities(a, tree ++
        \\test_associate_block::#assoc1::x: REAL, DIMENSION(5) :: X
        \\test_associate_block::#assoc2::x: INTEGER :: X
    )).?;
    var diffs: std.ArrayList([]const u8) = .empty;
    try associates.check(a, &diffs, g.assocs.names.items, right.assocs.items);
    try std.testing.expectEqual(0, diffs.items.len);
    // the first `x` with the second's type: before #754, compared with
    // gfortran's last `x`, it passed
    const wrong = (try zflsEntities(a, tree ++
        \\test_associate_block::#assoc1::x: INTEGER :: X
        \\test_associate_block::#assoc2::x: INTEGER :: X
    )).?;
    try associates.check(a, &diffs, g.assocs.names.items, wrong.assocs.items);
    try std.testing.expectEqual(1, diffs.items.len);
    try std.testing.expectEqualStrings("differs: test_associate_block::x (ASSOCIATE on line 4): type INTEGER, gfortran (REAL 4)", diffs.items[0]);
}

test "a CHANGE TEAM's coarray names, numbered among the constructs with names (#754)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // gfortran 16.1, tests/fortran/f2018.f90 (an excerpt): a CHANGE TEAM
    // without names, then one naming `x`
    const g = try gfortranEntities(a,
        \\Namespace: A-Z: (UNKNOWN 0)
        \\procedure name = f2018
        \\  procedure name = teams
        \\    code:
        \\
        \\    CHANGE TEAM teams:t
        \\      symtree: 'block@1'     || symbol: 'block@1'
        \\        type spec : (UNKNOWN 0)
        \\        attributes: (LABEL )
        \\      ASSIGN teams:k 1
        \\      END TEAM
        \\
        \\    CHANGE TEAM teams:t x = teams:y()[THIS_IMAGE] stat=teams:st errmsg=teams:msg
        \\      symtree: 'x'           || symbol: 'x'
        \\        type spec : (REAL 4)
        \\        attributes: (VARIABLE  CODIMENSION ASSOCIATE-VAR)
        \\        Array spec:(0 [1] AS_DEFERRED 1 () )
        \\      ASSIGN named:x()[THIS_IMAGE] 1.00000000e0
        \\      END TEAM stat=teams:st
    );
    try std.testing.expectEqual(1, g.assocs.names.items.len);
    try std.testing.expectEqualStrings("f2018::teams", g.assocs.names.items[0].ns);
    try std.testing.expectEqual(1, g.assocs.names.items[0].n);
}
