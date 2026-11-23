//! A name in a USE ONLY list that its module does not export (#847): not
//! declared there, or PRIVATE. Checked only against modules of the
//! workspace's sources whose own USE chain is all of the workspace too; a
//! library, intrinsic or module-file module is not known in full.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const resolve = @import("../objects/resolve.zig");
const unused = @import("../unused.zig");
const C = @import("../constants.zig");
const diagnostics = @import("diagnostics.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Server = @import("../server.zig").Server;

/// The names of the ONLY lists in `file` that their modules do not give
pub fn check(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    if (file.nLines() == 0) return out.items;
    var words: unused.Words = .empty;
    var known: std.AutoHashMapUnmanaged(*Obj, bool) = .empty;
    const env = self.env(a);
    for (ast.scope_list.items) |scope| {
        if (scope.file_ast != ast or scope.data != .scope) continue;
        for (scope.scopeDataConst().use.items) |u| {
            if (u.is_import or u.included or u.line_number == 0 or u.only_list.len() == 0) continue;
            const mod = env.global(ast, u.mod_name) orelse continue;
            if (mod.data != .scope or !try fullyKnown(self, a, mod, &known)) continue;
            for (u.only_list.items.items) |local| {
                if (!isName(local)) continue;
                const there = u.nameThere(local) orelse continue;
                const private = try privateIn(env, mod, there) orelse continue;
                const at = (try unused.findName(a, file, &words, u.line_number - 1, there)) orelse continue;
                try out.append(a, .{
                    .sln = at.line,
                    .sch = at.start,
                    .eln = at.line,
                    .ech = at.end,
                    .message = try a.print("\"{s}\" {s} module \"{s}\"", .{ at.text, if (private) "is PRIVATE in" else "not found in", u.mod_name }),
                    .severity = C.Severity.err,
                    .code = .use_name_not_found,
                    .subject = at.text,
                });
            }
        }
    }
    return out.items;
}

/// Null when module `mod` gives its users `name`; else whether it has the
/// name but PRIVATE (false: it has no such name)
fn privateIn(env: objects.Env, mod: *Obj, name: []const u8) !?bool {
    if (try resolve.checkScope(env, mod, name, true, null) != null) return null;
    if (try resolve.findThroughUse(env, mod, name, true) != null) return null;
    return try resolve.checkScope(env, mod, name, false, null) != null;
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

/// Whether module `mod` is a source of the workspace, with no fypp or
/// unread include, and every module it uses is too
fn fullyKnown(self: *Server, a: Allocator, mod: *Obj, memo: *std.AutoHashMapUnmanaged(*Obj, bool)) Allocator.Error!bool {
    if (memo.get(mod)) |v| return v;
    // a cycle counts as known: the rest of the chain decides
    try memo.put(a, mod, true);
    const ok = try isKnown(self, a, mod, memo);
    try memo.put(a, mod, ok);
    return ok;
}

fn isKnown(self: *Server, a: Allocator, mod: *Obj, memo: *std.AutoHashMapUnmanaged(*Obj, bool)) Allocator.Error!bool {
    const path = mod.file_ast.path orelse return false;
    const f = self.workspace.get(path) orelse return false;
    if (f.included or f.ast == null or diagnostics.usesFypp(f)) return false;
    for (f.ast.?.include_statements.items) |inc| if (inc.file == null) return false;
    // a submodule or a module that a separate procedure body needs
    if (mod.kind != .module) return false;
    for (mod.scopeDataConst().use.items) |u| {
        if (u.is_import) continue;
        if (diagnostics.isExternalModule(self, u.mod_name)) return false;
        const m = self.env(a).global(mod.file_ast, u.mod_name) orelse return false;
        if (m.data != .scope or !try fullyKnown(self, a, m, memo)) return false;
    }
    return true;
}
