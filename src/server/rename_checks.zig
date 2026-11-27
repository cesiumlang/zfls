//! What a rename must check before its edits (#953): that the new name is
//! not one its references would then mean instead, and that a type-bound
//! procedure is renamed from the binding its overrides override.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const objects_link = @import("../objects/link.zig");

const Obj = objects.Obj;
const srv = @import("../server.zig");
const Server = srv.Server;

const max_extensions = objects_link.max_extensions;

/// The binding at the root of the overrides of type-bound procedure `obj`,
/// in the type furthest up that has one of its name; `obj` itself when it
/// is no binding or overrides none
pub fn rootBinding(obj: *Obj) *Obj {
    const t = obj.parent orelse return obj;
    if (obj.kind != .method or t.kind != .type) return obj;
    var root = obj;
    var cur = t.typeDataConst().inherit_var;
    var hops: usize = 0;
    while (cur) |ty| : (cur = ty.typeDataConst().inherit_var) {
        hops += 1;
        if (hops > max_extensions) break;
        for (ty.childList()) |c| if (c.kind == .method and std.ascii.eqlIgnoreCase(c.name, obj.name)) {
            root = c;
            break;
        };
    }
    return root;
}

/// What `new_name` already names where renaming `obj` would put it: in a
/// derived type, a component or binding of the type or of one it extends;
/// elsewhere, a name the scope of a reference (`all`) reaches. Null when
/// the rename leaves every name meaning what it did, as a change of case does.
pub fn clash(self: *Server, a: Allocator, obj: *Obj, all: []const Server.FileRefs, new_name: []const u8) !?*Obj {
    if (std.ascii.eqlIgnoreCase(new_name, obj.name)) return null;
    if (obj.parent) |p| if (p.kind == .type) {
        var cur: ?*Obj = p;
        var hops: usize = 0;
        while (cur) |ty| : (cur = ty.typeDataConst().inherit_var) {
            hops += 1;
            if (hops > max_extensions) break;
            for (ty.childList()) |c| if (c != obj and std.ascii.eqlIgnoreCase(c.name, new_name)) return c;
        }
        return null;
    };
    for (all) |fr| {
        const ast = fr.file.ast orelse continue;
        for (fr.refs.items) |r| {
            const scope = ast.getInnerScope(r.line + 1) orelse continue;
            const found = (try objects.findInScope(self.env(a), scope, new_name, .{ .var_line_number = r.line + 1 })) orelse continue;
            if (found != obj) return found;
        }
    }
    return null;
}
