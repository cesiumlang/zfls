//! User-defined operators (`.ord.`, hansec #95): go to definition goes to
//! their `interface operator (.ord.)`, hover shows its procedures, and
//! references are their uses in the workspace.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const paths = @import("../paths.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;

const intrinsic_ops = [_][]const u8{ "eq", "ne", "lt", "le", "gt", "ge", "and", "or", "not", "eqv", "neqv", "true", "false" };

/// The name (lowercase) of the user-defined operator at byte column `col`
/// of 0-based `line`, written `.name.`
pub fn at(a: Allocator, file: *const FortranFile, line: usize, col: usize) !?[]const u8 {
    const text = file.getLine(line, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    const code = try helpers.stripStrings(a, text, true);
    var c = @min(col, code.len);
    // on one of its dots
    if (c < code.len and code[c] == '.' and c + 1 < code.len and std.ascii.isAlphabetic(code[c + 1])) c += 1;
    var s = c;
    while (s > 0 and std.ascii.isAlphabetic(code[s - 1])) s -= 1;
    var e = c;
    while (e < code.len and std.ascii.isAlphabetic(code[e])) e += 1;
    if (e == s or s == 0 or e >= code.len or code[s - 1] != '.' or code[e] != '.') return null;
    const name = try std.ascii.allocLowerString(a, code[s..e]);
    for (intrinsic_ops) |op| if (std.mem.eql(u8, op, name)) return null;
    return name;
}

/// Whether the line opening interface `iface` is `interface operator (.name.)`
fn defines(iface: *const Obj, name: []const u8) bool {
    if (iface.kind != .interface or iface.sline == 0) return false;
    const f = iface.file_ast.file orelse return false;
    const text = f.getLine(iface.sline - 1, false) orelse return false;
    const op = std.ascii.findIgnoreCase(text, "operator") orelse return false;
    var buf: [80]u8 = undefined;
    const dotted = std.fmt.bufPrint(&buf, ".{s}.", .{name}) catch return false;
    return std.ascii.findIgnoreCase(text[op..], dotted) != null;
}

/// The interfaces that define operator `name`
fn interfaces(self: *Server, a: Allocator, name: []const u8) ![]const *Obj {
    var out: std.ArrayList(*Obj) = .empty;
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.scope_list.items) |sc| if (defines(sc, name)) try out.append(a, sc);
    }
    return out.items;
}

/// Where `.name.` is written on 0-based `line` of `file`, from byte `from`
fn find(a: Allocator, file: *const FortranFile, line: usize, name: []const u8, from: usize) !?struct { start: usize, end: usize } {
    const text = file.getLine(line, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    var code = try helpers.stripStrings(a, text, true);
    if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
    var i = from;
    while (i < code.len) : (i += 1) {
        if (code[i] != '.' or i + name.len + 1 >= code.len) continue;
        if (code[i + name.len + 1] != '.' or !std.ascii.eqlIgnoreCase(code[i + 1 .. i + 1 + name.len], name)) continue;
        // not the end of a longer word (`.order.` for `.ord.`)
        return .{ .start = i, .end = i + name.len + 2 };
    }
    return null;
}

pub fn definition(self: *Server, a: Allocator, name: []const u8) !Value {
    for (try interfaces(self, a, name)) |iface| {
        const f = iface.file_ast.file orelse continue;
        const line = iface.sline - 1;
        const span = (try find(a, f, line, name, 0)) orelse continue;
        return json.from(a, Server.locationOf(try paths.pathToUri(a, f.path), f, line, span.start, line, span.end));
    }
    return .null;
}

pub fn hover(self: *Server, a: Allocator, name: []const u8) !Value {
    var parts: std.ArrayList([]const u8) = .empty;
    for (try interfaces(self, a, name)) |iface| {
        for (iface.memList()) |member| {
            const h = try member.getHover(a, true, null);
            if (h.msg != null) try parts.append(a, try helpers.fortranMd(a, h.msg, h.docs));
        }
    }
    if (parts.items.len == 0) return .null;
    const md = try std.mem.join(a, "\n", parts.items);
    return json.from(a, lsp.Hover{ .contents = .{ .value = try srv.pyFormatLangid(a, md, self.s.hover_language) } });
}

pub fn references(self: *Server, a: Allocator, name: []const u8) !Value {
    if ((try interfaces(self, a, name)).len == 0) return .null;
    var out: std.ArrayList(lsp.Location) = .empty;
    for (self.workspace.values()) |f| {
        if (f.ast == null) continue;
        const uri = try paths.pathToUri(a, f.path);
        for (0..f.nLines()) |ln| {
            var from: usize = 0;
            while (try find(a, f, ln, name, from)) |span| {
                try out.append(a, Server.locationOf(uri, f, ln, span.start, ln, span.end));
                from = span.end;
            }
        }
    }
    return json.from(a, out.items);
}
