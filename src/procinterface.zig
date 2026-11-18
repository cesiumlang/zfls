//! The interface body of an external procedure, written from its source:
//! its first statement, its USE and IMPLICIT statements, the declarations
//! of its dummy arguments and result (with the named constants those use)
//! and an END statement. Copying the statements keeps their kinds,
//! dimensions and attributes as written, which hover's summary of each
//! argument does not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const FortranFile = @import("parser.zig").FortranFile;
const statement = @import("statement.zig");
const unused = @import("unused.zig");

/// The statements of the interface body of `proc` (a subroutine or
/// function), each on one line without indentation: the first statement,
/// then the others, then the END statement. Null when its source is not
/// read or a statement cannot be taken apart.
pub fn body(a: Allocator, proc: *const Obj) !?[]const []const u8 {
    if (proc.kind != .subroutine and proc.kind != .function) return null;
    if (proc.data != .scope or proc.sline == 0) return null;
    const file = proc.file_ast.file orelse return null;
    const sd = proc.scopeDataConst();
    const pd = proc.procDataConst();
    // the 0-based lines of the statements to copy
    var lines: std.array_hash_map.Auto(usize, void) = .empty;
    for (sd.use.items) |u| if (u.line_number > 0) try lines.put(a, u.line_number - 1, {});
    if (sd.implicit_line) |il| if (il > 0) try lines.put(a, il - 1, {});
    // the names whose declarations are needed: the arguments, the result
    var needed: std.StringHashMapUnmanaged(void) = .empty;
    var args = std.mem.splitScalar(u8, pd.args, ',');
    while (args.next()) |arg| {
        const n = std.mem.trim(u8, arg, " \t");
        if (n.len > 0 and !std.mem.eql(u8, n, "*")) try needed.put(a, try std.ascii.allocLowerString(a, n), {});
    }
    if (proc.kind == .function) try needed.put(a, try std.ascii.allocLowerString(a, pd.result_name orelse proc.name), {});
    // the variables declared on each line, by name
    var locals: std.StringHashMapUnmanaged(*const Obj) = .empty;
    for (proc.childList()) |c| {
        if (c.kind != .variable or c.sline <= proc.sline) continue;
        if (sd.contains_start) |cs| if (c.sline >= cs) continue;
        try locals.put(a, try std.ascii.allocLowerString(a, c.name), c);
    }
    // the declarations of the needed names, and of the named constants
    // those use
    var decls: std.array_hash_map.Auto(usize, void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    var it = needed.keyIterator();
    while (it.next()) |k| try queue.append(a, k.*);
    while (queue.pop()) |name| {
        const c = locals.get(name) orelse continue;
        const line = c.sline - 1;
        if ((try decls.getOrPut(a, line)).found_existing) continue;
        const st = (try statement.linesOf(a, file, line)) orelse return null;
        const code = (try statement.of(a, st.lines, file.fixed)) orelse return null;
        var words = helpers.words(code.text);
        while (words.next()) |w| {
            const lower = try std.ascii.allocLowerString(a, w.str);
            const o = locals.get(lower) orelse continue;
            if (needed.contains(lower)) continue;
            // on this line, a name of the statement itself; elsewhere, a
            // named constant its declaration uses
            if (o.sline - 1 == line or !o.isParameter()) continue;
            try needed.put(a, lower, {});
            try queue.append(a, lower);
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, (try joinedStatement(a, file, proc.sline - 1, &.{})) orelse return null);
    for (decls.keys()) |l| try lines.put(a, l, {});
    lines.sort(struct {
        keys: []const usize,
        pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
            return ctx.keys[x] < ctx.keys[y];
        }
    }{ .keys = lines.keys() });
    for (lines.keys()) |l| {
        // the names declared on the line that are not needed
        var others: std.ArrayList([]const u8) = .empty;
        if (decls.contains(l)) {
            var lit = locals.iterator();
            while (lit.next()) |e| if (e.value_ptr.*.sline - 1 == l and !needed.contains(e.key_ptr.*)) try others.append(a, e.key_ptr.*);
        }
        try out.append(a, (try joinedStatement(a, file, l, others.items)) orelse return null);
    }
    try out.append(a, try a.print("end {s} {s}", .{ if (proc.kind == .function) "function" else "subroutine", proc.name }));
    return out.items;
}

/// The statement on 0-based line `line` of `file` on one line, without
/// the names `drop` declares
fn joinedStatement(a: Allocator, file: *const FortranFile, line: usize, drop: []const []const u8) !?[]const u8 {
    const st = (try statement.linesOf(a, file, line)) orelse return null;
    const code = (try statement.of(a, st.lines, file.fixed)) orelse return null;
    var skip: std.ArrayList([2]statement.Pos) = .empty;
    if (drop.len > 0) {
        const cuts = (try unused.removal(a, file, line, drop)) orelse return null;
        for (cuts) |c| try skip.append(a, .{
            .{ .line = c.sl - st.first, .col = c.sc },
            .{ .line = c.el - st.first, .col = c.ec },
        });
    }
    return try code.joined(a, skip.items);
}
