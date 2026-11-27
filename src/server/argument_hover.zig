//! Hover on an actual argument, with `hover_signature` (#281): the dummy
//! argument it is passed to, under the usual hover.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const regex = @import("../regex.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const srv = @import("../server.zig");
const Server = srv.Server;
const signature = @import("signature.zig");

/// The Markdown to add under the hover at `params` when it is on an actual
/// argument of a call zfls resolves: the procedure's signature and the
/// declaration and documentation of the dummy argument the actual one is
/// passed to (by position, by keyword, past the passed-object argument of
/// a type-bound procedure, to the specific of a generic that the arguments
/// fit). Null on the procedure's name, for a procedure without dummy
/// declarations (intrinsics) and for calls zfls does not resolve.
pub fn dummyBlock(self: *Server, a: Allocator, params: lsp.PositionParams) !?[]const u8 {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const ast = file.ast orelse return null;
    const line = params.position.line;
    const text = file.getLine(line, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    const col = @min(Server.toByteCol(file, line, params.position.character), text.len);
    const call = (try signature.callAt(self, a, file, ast, line, col)) orelse return null;
    if (call.args.len == 0) return null;
    // on the keyword of a keyword argument, `second` of `second=k`: the
    // dummy of that name
    var e = col;
    while (e < text.len and regex.isWordChar(text[e])) e += 1;
    var args = call.args;
    if (keywordAt(file, line, text, col)) |kw| {
        const copy = try a.dupe([]const u8, args);
        copy[copy.len - 1] = try a.print("{s}=", .{text[kw[0]..kw[1]]});
        args = copy;
    }
    // a generic's specific is chosen by all the arguments, also those after
    const full = try std.mem.concat(a, []const u8, &.{ args, try argumentsAfter(a, text, e) });
    const proc = (try chosen(self, a, call.obj, full)) orelse return null;
    const sig = (try signature.signatureOf(self, a, proc, args)) orelse return null;
    if (sig.param < 0 or sig.param >= sig.info.parameters.len) return null;
    const dummy = sig.info.parameters[@intCast(sig.param)];
    const md = (dummy.documentation orelse return null).value;
    return try a.print("Argument of `{s}`:\n{s}", .{ sig.info.label, md });
}

/// The arguments after the one that ends at byte `from` of `text`, up to
/// the `)` that closes the call (on this line)
fn argumentsAfter(a: Allocator, text: []const u8, from: usize) ![]const []const u8 {
    const code = try helpers.stripStrings(a, text, true);
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: ?usize = null;
    var i = from;
    while (i < code.len) : (i += 1) {
        switch (code[i]) {
            '(', '[' => depth += 1,
            ')', ']' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ',' => if (depth == 0) {
                if (start) |st| try out.append(a, text[st..i]);
                start = i + 1;
            },
            '!' => break,
            else => {},
        }
    }
    if (start) |st| try out.append(a, text[st..@min(i, text.len)]);
    return out.items;
}

/// The procedure a call of `obj` with arguments `args` reaches: a
/// procedure itself, or of a generic interface the one with the fewest
/// parameters that takes them (as signature help makes active)
fn chosen(self: *Server, a: Allocator, obj: *Obj, args: []const []const u8) !?*Obj {
    if (obj.kind != .interface) return obj;
    var best: ?*Obj = null;
    var best_size: usize = std.math.maxInt(usize);
    for (obj.memList()) |member| {
        const s = (try signature.signatureOf(self, a, member, args)) orelse continue;
        if (s.fits and s.size < best_size) {
            best = member;
            best_size = s.size;
        }
    }
    return best;
}

/// The bytes of the keyword of a keyword argument at byte `col` of `text`,
/// line `line` of `file`, `second` of `second=k`; null when `col` is on no
/// such name
fn keywordAt(file: *const FortranFile, line: usize, text: []const u8, col: usize) ?[2]usize {
    var s = @min(col, text.len);
    while (s > 0 and regex.isWordChar(text[s - 1])) s -= 1;
    var e = @min(col, text.len);
    while (e < text.len and regex.isWordChar(text[e])) e += 1;
    var k = e;
    while (k < text.len and text[k] == ' ') k += 1;
    if (e == s or k >= text.len or text[k] != '=') return null;
    if (k + 1 < text.len and (text[k + 1] == '=' or text[k + 1] == '>')) return null;
    // after the opening parenthesis or a comma, or first on a continuation line
    var b = s;
    while (b > 0 and (text[b - 1] == ' ' or text[b - 1] == '\t')) b -= 1;
    const first = if (file.fixed) b == 6 and helpers.fixedContMark(text) != null else b == 0 and file.continuesInto(line);
    if (!first and (b == 0 or (text[b - 1] != '(' and text[b - 1] != ',' and text[b - 1] != '&'))) return null;
    return .{ s, e };
}

/// The dummy argument (or the component, in a structure constructor) that
/// the keyword at byte `col` of 0-based `line` names, `x` of
/// `call f(x=1.0)` (#952); null elsewhere and for calls zfls does not
/// resolve
pub fn keywordDummy(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !?*Obj {
    const ast = file.ast orelse return null;
    const text = file.getLine(line, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    const kw = keywordAt(file, line, text, col) orelse return null;
    const call = (try signature.callAt(self, a, file, ast, line, kw[0])) orelse return null;
    const name = text[kw[0]..kw[1]];
    const args = try std.mem.concat(a, []const u8, &.{ call.args[0..call.args.len -| 1], &.{try a.print("{s}=", .{name})}, try argumentsAfter(a, text, kw[1]) });
    // a generic: the specific the arguments fit, else the first with the keyword
    var one = [1]*Obj{call.obj};
    var procs: []const *Obj = &one;
    if (call.obj.kind == .interface) {
        if (try chosen(self, a, call.obj, args)) |p| one[0] = p else procs = call.obj.memList();
    }
    for (procs) |p| if (dummyNamed(p, name)) |d| return d;
    return null;
}

/// The dummy argument `name` of procedure `p`, through a type-bound
/// procedure's or a procedure pointer's interface; of a derived type, its
/// component `name`
fn dummyNamed(p: *const Obj, name: []const u8) ?*Obj {
    var proc = p;
    var hops: usize = 0;
    while (proc.kind == .method or proc.kind == .variable) : (hops += 1) {
        if (hops == 8) return null;
        proc = proc.linkObj() orelse return null;
    }
    switch (proc.kind) {
        .subroutine, .function => for (proc.procDataConst().arg_objs.items) |o| {
            if (o) |d| if (std.ascii.eqlIgnoreCase(d.name, name)) return d;
        },
        .type => for (proc.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) return c,
        else => {},
    }
    return null;
}
