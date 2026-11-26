//! C-style preprocessor used for Fortran sources (port of `preprocess_file`)
//!
//! `#if` expressions are rewritten exactly like fortls does and then
//! evaluated with a small evaluator implementing the Python expression
//! semantics fortls relied on (`eval`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const patterns = @import("patterns.zig");
const regex = @import("regex.zig");
const paths = @import("paths.zig");
const helpers = @import("helpers.zig");
const parser = @import("parser.zig");
const macro = @import("preprocessor/macro.zig");
const intel = @import("preprocessor/intel.zig");
const predefined = @import("preprocessor/predefined.zig");
const PyEval = @import("preprocessor/py_eval.zig").PyEval;
const dialects = @import("preprocessor/dialect.zig");
const fsio = @import("fsio.zig");
pub const Dialect = dialects.Dialect;

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// A macro definition: object-like (`args == null`) or function-like
pub const Def = struct {
    args: ?[]const u8 = null,
    value: []const u8,
};

/// Ordered macro table (insertion order matters for substitution)
pub const Defs = std.array_hash_map.String(Def);

/// A range of lines (1-based, inclusive) that a conditional excludes
pub const Skip = struct { start: usize, end: usize };

/// An `#include` directive of the file itself (not of an included file) that
/// names a file that exists
pub const Include = struct {
    /// 1-based line of the directive
    line: usize,
    /// Absolute path of the included file
    path: []const u8,
};

/// An `#include` directive of the file itself whose file is found nowhere
pub const Missing = struct {
    /// 1-based line of the directive
    line: usize,
    /// The file's name, as written
    name: []const u8,
    /// Byte columns of the name (with its quotes or angle brackets)
    start: usize,
    end: usize,
};

/// A condition of the file itself that its compiler's preprocessor
/// rejects (preprocessor/dialect.zig)
pub const Rejected = struct {
    /// 1-based line of the `#if` or `#elif`
    line: usize,
    message: []const u8,
    /// Byte columns of the condition
    start: usize,
    end: usize,
};

pub const Output = struct {
    lines: [][]const u8,
    /// 1-based line ranges excluded by conditionals
    skips: []Skip,
    /// 1-based line numbers of #define/#undef statements
    defines: []usize,
    includes: []Include,
    /// `#include` directives (of the file itself) whose file is not found
    missing: []Missing,
    defs: Defs,
    rejected: []const Rejected = &.{},
};

/// Copy a macro table into `a`
pub fn cloneDefs(a: Allocator, defs: *const Defs) !Defs {
    var out: Defs = .empty;
    var it = defs.iterator();
    while (it.next()) |e| {
        try out.put(a, try a.dupe(u8, e.key_ptr.*), .{
            .args = try str.dupeOpt(a, e.value_ptr.args),
            .value = try a.dupe(u8, e.value_ptr.value),
        });
    }
    return out;
}

// --------------------------------------------------------------------------
// #if evaluation

const ReplaceCtx = struct { defs: *const Defs };

fn replDefined(ctx: ReplaceCtx, a: Allocator, out: *std.ArrayList(u8), m: regex.Match) Allocator.Error!void {
    if (ctx.defs.contains(m.group(1).?)) {
        try out.appendSlice(a, "(@$@)");
    } else {
        try out.appendSlice(a, "(%$%)");
    }
}

const VarErr = error{TupleValue} || Allocator.Error;

fn replaceVars(a: Allocator, line: []const u8, defs: *const Defs) VarErr![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = helpers.words(line);
    var i_0: usize = 0;
    while (it.next()) |m| {
        try out.appendSlice(a, line[i_0..m.start]);
        if (defs.get(m.str)) |d| {
            // fortls fails on function-like macros here
            if (d.args != null) return error.TupleValue;
            try out.appendSlice(a, d.value);
        } else {
            try out.appendSlice(a, "False");
        }
        i_0 = m.end;
    }
    if (i_0 < line.len) try out.appendSlice(a, line[i_0..]);
    var res = try std.mem.replaceOwned(u8, a, out.items, "@$@", "True");
    res = try std.mem.replaceOwned(u8, a, res, "%$%", "False");
    return res;
}

fn replaceOps(a: Allocator, expr: []const u8) ![]const u8 {
    var e = try std.mem.replaceOwned(u8, a, expr, "&&", " and ");
    e = try std.mem.replaceOwned(u8, a, e, "||", " or ");
    e = try std.mem.replaceOwned(u8, a, e, "!=", " <> ");
    e = try std.mem.replaceOwned(u8, a, e, "!", " not ");
    e = try std.mem.replaceOwned(u8, a, e, " <> ", " != ");
    return e;
}

/// Evaluate a preprocessor `#if` condition
pub fn evalPpIf(a: Allocator, text: []const u8, defs: *const Defs) bool {
    // Fortran's operators too, as Intel's fpp takes them
    const c_text = intel.cOperators(a, text) catch return false;
    const step1 = R().DEFINED.subFn(a, c_text, ReplaceCtx{ .defs = defs }, replDefined) catch return false;
    const step2 = replaceVars(a, step1, defs) catch return false;
    const expr = replaceOps(a, step2) catch return false;
    var ev: PyEval = .{ .a = a, .src = expr };
    const v = ev.evaluate() catch return false;
    return v.truthy();
}

// --------------------------------------------------------------------------
// Preprocessing

fn appendMultilineMacro(a: Allocator, d: Def, line: []const u8) !Def {
    return .{ .args = d.args, .value = try std.mem.concat(a, u8, &.{ d.value, line }) };
}

/// An open conditional. `start` is the first line of its excluded part, null
/// while the branch is included; `end` the last one, null until known.
/// The conditional directives that `PP_REGEX` matches
const Directive = enum { if_, ifdef, ifndef, else_, elif, endif };

const directives = std.StaticStringMap(Directive).initComptime(.{
    .{ "if ", .if_ },
    .{ "ifdef", .ifdef },
    .{ "ifndef", .ifndef },
    .{ "else", .else_ },
    .{ "elif", .elif },
    .{ "endif", .endif },
});

const StackEntry = struct { start: ?usize = null, end: ?usize = null };

fn skipOf(e: StackEntry) Skip {
    return .{ .start = e.start.?, .end = e.end.? };
}

/// Preprocess `contents`; all results are allocated in `a`.
pub fn preprocessFile(
    a: Allocator,
    io: Io,
    contents: []const []const u8,
    file_path: ?[]const u8,
    pp_defs: ?*const Defs,
    include_dirs_in: []const []const u8,
    dialect: Dialect,
    trace: ?parser.Trace,
) !Output {
    var include_dirs: std.ArrayList([]const u8) = .empty;
    if (file_path) |fp| {
        try include_dirs.append(a, try paths.abspath(a, paths.dirname(fp)));
    }
    for (include_dirs_in) |d| {
        var dup = false;
        for (include_dirs.items) |e| if (std.mem.eql(u8, e, d)) {
            dup = true;
        };
        if (!dup) try include_dirs.append(a, d);
    }
    const name = if (file_path) |fp| std.Io.Dir.path.basename(fp) else "";
    return preprocessInner(a, io, contents, name, pp_defs, &include_dirs, 0, dialect, trace);
}

fn preprocessInner(
    a: Allocator,
    io: Io,
    contents: []const []const u8,
    /// the file's name, for `__FILE__`
    file_name: []const u8,
    pp_defs: ?*const Defs,
    include_dirs: *std.ArrayList([]const u8),
    depth: usize,
    dialect: Dialect,
    trace: ?parser.Trace,
) !Output {
    var pp_skips: std.ArrayList(Skip) = .empty;
    var pp_defines: std.ArrayList(usize) = .empty;
    var pp_includes: std.ArrayList(Include) = .empty;
    var pp_missing: std.ArrayList(Missing) = .empty;
    var pp_rejected: std.ArrayList(Rejected) = .empty;
    var pp_stack: std.ArrayList(StackEntry) = .empty;
    var pp_stack_group: std.ArrayList(struct { usize, bool }) = .empty;
    var defs_tmp: Defs = if (pp_defs) |d| try cloneDefs(a, d) else .empty;
    var def_regexes = std.array_hash_map.String(?macro.Compiled).empty;
    defer {
        var it = def_regexes.iterator();
        while (it.next()) |e| if (e.value_ptr.*) |*c| c.deinit();
    }
    var output: std.ArrayList([]const u8) = .empty;
    var def_cont_name: ?[]const u8 = null;

    for (contents, 0..) |line_in, i| {
        var line = line_in;
        // Handle multiline macro continuation
        if (def_cont_name) |dcn| {
            try output.append(a, "");
            const stripped = str.strip(line);
            const is_multiline = stripped.len == 0 or stripped[stripped.len - 1] != '\\';
            const to_append = if (is_multiline) stripped else str.strip(line[0..line.len -| 1]);
            if (defs_tmp.get(dcn)) |d| try defs_tmp.put(a, dcn, try appendMultilineMacro(a, d, to_append));
            if (is_multiline) def_cont_name = null;
            continue;
        }
        // Handle conditional statements
        if (R().PP_REGEX.match(line)) |m| {
            try output.append(a, line);
            var kw_buf: [8]u8 = undefined;
            const kw = directives.get(std.ascii.lowerString(&kw_buf, m.group(1).?)).?;
            var if_start = false;
            var is_path = false;
            if (kw == .if_) {
                const r = if (active(pp_stack.items)) try rejectedAt(a, dialect, line, m.end(1), i, depth, &pp_rejected) else null;
                is_path = if (r) |taken| taken else evalPpIf(a, line[m.end(1)..], &defs_tmp);
                if_start = true;
            } else if (kw == .ifdef) {
                if_start = true;
                is_path = defs_tmp.contains(str.strip(line[m.end(0)..]));
            } else if (kw == .ifndef) {
                if_start = true;
                is_path = !defs_tmp.contains(str.strip(line[m.end(0)..]));
            }
            if (if_start) {
                if (is_path) {
                    try pp_stack.append(a, .{});
                    parser.Trace.print(trace, "{s} !!! Conditional TRUE({d})", .{ str.strip(line), i + 1 });
                } else {
                    try pp_stack.append(a, .{ .start = i + 1 });
                    parser.Trace.print(trace, "{s} !!! Conditional FALSE({d})", .{ str.strip(line), i + 1 });
                }
                continue;
            }
            if (pp_stack.items.len == 0) continue;
            const depth_now = pp_stack.items.len;
            const top = &pp_stack.items[pp_stack.items.len - 1];
            var cond: enum { none, included, excluded_start, excluded } = .none;
            if (kw == .elif) {
                if (pp_stack_group.items.len == 0 or pp_stack_group.items[pp_stack_group.items.len - 1][0] != depth_now) {
                    try pp_stack_group.append(a, .{ depth_now, top.start == null });
                }
                const grp = &pp_stack_group.items[pp_stack_group.items.len - 1];
                if (grp[1]) {
                    // An earlier if or elif in this group has been true
                    if (top.start == null) top.start = i + 1;
                    cond = .excluded;
                } else if (if (active(pp_stack.items[0 .. pp_stack.items.len - 1])) try rejectedAt(a, dialect, line, m.end(1), i, depth, &pp_rejected) else null) |taken| {
                    if (taken) {
                        top.end = i + 1;
                        try pp_skips.append(a, skipOf(pp_stack.pop().?));
                        grp[1] = true;
                        try pp_stack.append(a, .{});
                        cond = .included;
                    } else cond = .excluded_start;
                } else if (evalPpIf(a, line[m.end(1)..], &defs_tmp)) {
                    top.end = i + 1;
                    try pp_skips.append(a, skipOf(pp_stack.pop().?));
                    grp[1] = true;
                    try pp_stack.append(a, .{});
                    cond = .included;
                } else cond = .excluded_start;
            } else if (kw == .else_) {
                if (top.start == null) {
                    top.start = i + 1;
                    cond = .excluded_start;
                } else if (pp_stack_group.items.len > 0 and
                    pp_stack_group.items[pp_stack_group.items.len - 1][0] == depth_now and
                    pp_stack_group.items[pp_stack_group.items.len - 1][1])
                {
                    // An earlier if or elif in this group has been true
                    cond = .excluded;
                } else {
                    top.end = i + 1;
                    try pp_skips.append(a, skipOf(pp_stack.pop().?));
                    try pp_stack.append(a, .{});
                    cond = .included;
                }
            } else if (kw == .endif) {
                if (pp_stack_group.items.len > 0 and pp_stack_group.items[pp_stack_group.items.len - 1][0] == depth_now) {
                    _ = pp_stack_group.pop();
                }
                if (top.start == null) {
                    _ = pp_stack.pop();
                    parser.Trace.print(trace, "{s} !!! Conditional TRUE/END({d})", .{ str.strip(line), i + 1 });
                    continue;
                }
                if (top.end == null) {
                    top.end = i + 1;
                    parser.Trace.print(trace, "{s} !!! Conditional FALSE/END({d})", .{ str.strip(line), i + 1 });
                }
                try pp_skips.append(a, skipOf(pp_stack.pop().?));
            }
            switch (cond) {
                .none => {},
                .included => parser.Trace.print(trace, "{s} !!! Conditional TRUE({d})", .{ str.strip(line), i + 1 }),
                .excluded_start => parser.Trace.print(trace, "{s} !!! Conditional FALSE({d})", .{ str.strip(line), i + 1 }),
                .excluded => parser.Trace.print(trace, "{s} !!! Conditional EXCLUDED({d})", .{ str.strip(line), i + 1 }),
            }
            continue;
        }
        var stack_is_true = true;
        for (pp_stack.items) |s| if (s.start != null) {
            stack_is_true = false;
        };
        // Handle variable/macro definitions
        if (R().PP_DEF.match(line)) |m| if (stack_is_true) {
            try output.append(a, line);
            try pp_defines.append(a, i + 1);
            const def_name = m.group(2).?;
            const directive = m.group(1).?;
            // a macro defined again gets its pattern again
            if (def_regexes.fetchOrderedRemove(def_name)) |kv| {
                var compiled = kv.value;
                if (compiled) |*c| c.deinit();
            }
            if (std.mem.eql(u8, directive, "define") and !defs_tmp.contains(def_name)) {
                var def_value: []const u8 = undefined;
                const rest = line[m.end(0)..];
                if (std.mem.findScalar(u8, rest, ' ')) |eq_ind| {
                    const rs = str.rstrip(line);
                    if (rs.len > 0 and rs[rs.len - 1] == '\\') {
                        def_value = str.strip(line[m.end(0) + eq_ind .. @max(line.len -| 1, m.end(0) + eq_ind)]);
                        def_cont_name = try a.dupe(u8, def_name);
                    } else {
                        def_value = str.strip(line[m.end(0) + eq_ind ..]);
                    }
                } else {
                    def_value = "True";
                }
                var d: Def = .{ .value = try a.dupe(u8, def_value) };
                if (m.group(3) != null) d.args = try a.dupe(u8, m.group(4) orelse "");
                try defs_tmp.put(a, try a.dupe(u8, def_name), d);
            } else if (std.mem.eql(u8, directive, "undef") and defs_tmp.contains(def_name)) {
                _ = defs_tmp.orderedRemove(def_name);
            }
            parser.Trace.print(trace, "{s} !!! Define statement({d})", .{ str.strip(line), i + 1 });
            continue;
        };
        // Handle include files
        if (R().PP_INCLUDE.match(line)) |m| if (stack_is_true) {
            parser.Trace.print(trace, "{s} !!! Include statement({d})", .{ str.strip(line), i + 1 });
            // `"file"` or `<file>`, both searched in the file's directory
            // and in the include directories
            const include_filename = std.mem.trim(u8, m.group(1).?, "\"<>");
            var include_path: ?[]const u8 = null;
            for (include_dirs.items) |dir| {
                const candidate = try paths.join(a, &.{ dir, include_filename });
                if (paths.isFile(io, candidate)) {
                    include_path = try paths.abspath(a, candidate);
                    break;
                }
            }
            if (include_path) |ip| {
                if (depth == 0) try pp_includes.append(a, .{ .line = i + 1, .path = ip });
                // guard against include cycles
                if (depth >= 32) {} else if (fsio.readFile(io, a, ip, .limited(1 << 28))) |data| {
                    const text = try std.mem.replaceOwned(u8, a, data, "\t", " ");
                    const inc_lines = try parser.splitLines(a, text);
                    const dir = try paths.abspath(a, paths.dirname(ip));
                    var dup = false;
                    for (include_dirs.items) |e| if (std.mem.eql(u8, e, dir)) {
                        dup = true;
                    };
                    if (!dup) try include_dirs.append(a, dir);
                    parser.Trace.print(trace, "\n!!! Parsing include file '{s}'", .{ip});
                    const res = try preprocessInner(a, io, inc_lines, std.Io.Dir.path.basename(ip), &defs_tmp, include_dirs, depth + 1, dialect, trace);
                    defs_tmp = res.defs;
                    parser.Trace.print(trace, "!!! Completed parsing include file\n", .{});
                } else |_| {
                    parser.Trace.print(trace, "!!! Failed to parse include file: {s}", .{ip});
                }
            } else {
                parser.Trace.print(trace, "{s} !!! Could not locate include file ({d})", .{ str.strip(line), i + 1 });
                if (depth == 0 and include_filename.len > 0) try pp_missing.append(a, .{ .line = i + 1, .name = try a.dupe(u8, include_filename), .start = m.start(1), .end = m.end(1) });
            }
        };
        line = try macro.removeEmptyComments(a, line);
        // Substitute (if any) read in preprocessor macros
        var it = defs_tmp.iterator();
        while (it.next()) |e| {
            const def_tmp = e.key_ptr.*;
            const value = e.value_ptr.*;
            if (std.mem.find(u8, line, def_tmp) == null) continue;
            const gop = try def_regexes.getOrPut(a, def_tmp);
            if (!gop.found_existing) {
                gop.key_ptr.* = def_tmp;
                gop.value_ptr.* = macro.compile(a, def_tmp, value.args) catch |err| blk: {
                    parser.Trace.print(trace, "!!! bad macro {s}: {s}", .{ def_tmp, @errorName(err) });
                    break :blk null;
                };
            }
            const c = &(gop.value_ptr.* orelse continue);
            const res = try macro.substitute(a, c, value.value, line);
            if (res.count > 0) {
                parser.Trace.print(trace, "{s} !!! Macro sub({d}) '{s}' -> '{s}'", .{ str.strip(line), i + 1, def_tmp, value.value });
                line = res.out;
            }
        }
        if (try predefined.expand(a, line, .{ .io = io, .file = file_name, .line = i + 1 }, &defs_tmp)) |l| line = l;
        try output.append(a, line);
    }
    return .{
        .lines = output.items,
        .skips = pp_skips.items,
        .defines = pp_defines.items,
        .includes = pp_includes.items,
        .missing = pp_missing.items,
        .defs = defs_tmp,
        .rejected = pp_rejected.items,
    };
}

/// Whether the lines are in no excluded branch of `stack`
fn active(stack: []const StackEntry) bool {
    for (stack) |e| if (e.start != null) return false;
    return true;
}

/// Whether the branch of the condition of `line` (from byte `at`) is
/// taken, when `dialect`'s preprocessor rejects the condition: then the
/// file's own (`depth` 0) is recorded in `out`
fn rejectedAt(a: Allocator, dialect: Dialect, line: []const u8, at: usize, i: usize, depth: usize, out: *std.ArrayList(Rejected)) !?bool {
    const r = dialects.rejection(dialect, line[at..]) orelse return null;
    if (depth == 0) try out.append(a, .{ .line = i + 1, .message = r.message, .start = line.len - str.lstrip(line[at..]).len, .end = str.rstrip(line).len });
    return r.taken;
}

const testing = std.testing;

test "pp if evaluation" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var defs: Defs = .empty;
    try defs.put(a, "A", .{ .value = "1" });
    try defs.put(a, "VER", .{ .value = "3" });
    try testing.expect(evalPpIf(a, " defined(A)", &defs));
    try testing.expect(!evalPpIf(a, " defined(B)", &defs));
    try testing.expect(evalPpIf(a, " !defined(B) && defined(A)", &defs));
    try testing.expect(evalPpIf(a, " VER >= 2", &defs));
    try testing.expect(!evalPpIf(a, " VER > 3 || 0", &defs));
    try testing.expect(evalPpIf(a, " 1", &defs));
    try testing.expect(!evalPpIf(a, " 0", &defs));
    try testing.expect(evalPpIf(a, " defined PETSC_ERR || defined A", &defs));
    try testing.expect(evalPpIf(a, " (VER - 1) * 2 == 4", &defs));
}

test "pp macro expansion" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{
        "#define N 10",
        "#define SQ(x) ((x)*(x))",
        "#if N > 5",
        "integer :: a(N)",
        "#else",
        "integer :: b",
        "#endif",
        "y = SQ(z)",
    };
    const out = try preprocessFile(a, undefined, &lines, null, null, &.{}, .any, null);
    try testing.expectEqualStrings("integer :: a(10)", out.lines[3]);
    try testing.expectEqualStrings("y = ((z)*(z))", out.lines[7]);
    try testing.expectEqual(@as(usize, 1), out.skips.len);
    try testing.expectEqual(@as(usize, 5), out.skips[0].start);
    try testing.expectEqual(@as(usize, 7), out.skips[0].end);
}

test "pp function-like macro without arguments (#225)" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{
        "#define NOARG() 42",
        "#define CHECK() if (ie /= 0) return",
        "#define ONE(x) (x + 1)",
        "i = NOARG()",
        "i = ONE(i)",
        "CHECK()",
        "i = NOARG( )",
    };
    const out = try preprocessFile(a, undefined, &lines, null, null, &.{}, .any, null);
    try testing.expectEqualStrings("i = 42", out.lines[3]);
    try testing.expectEqualStrings("i = (i + 1)", out.lines[4]);
    try testing.expectEqualStrings("if (ie /= 0) return", out.lines[5]);
    try testing.expectEqualStrings("i = 42", out.lines[6]);
}
