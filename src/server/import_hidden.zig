//! A name of the host that an IMPORT statement leaves out (#804): in a
//! BLOCK or a contained procedure, `import, only` and `import, none` make
//! the host's other names inaccessible, which gfortran, Flang and ifx report.

const std = @import("std");
const Allocator = std.mem.Allocator;
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const semantic = @import("../semantic.zig");

const Obj = objects.Obj;

/// The diagnostic for `u`, a name that stands for nothing in `scope`, when
/// it is that of the host and an IMPORT statement leaves it out; null when
/// the host has no such name either (not this diagnostic's)
pub fn diagnostic(env: objects.Env, a: Allocator, scope: *Obj, u: semantic.Unknown) !?objects.BuiltDiag {
    const lower = try std.ascii.allocLowerString(a, u.name);
    var s: ?*Obj = scope;
    while (s) |o| : (s = o.parent) {
        if (!objects.importHides(o, lower)) continue;
        if ((try objects.findInScope(env, o.parent, lower, .{})) == null) return null;
        return .{
            .sln = u.line,
            .sch = u.start,
            .eln = u.line,
            .ech = u.end,
            .message = try a.print("Name \"{s}\" of the host is not accessible ({s})", .{ u.name, if (isNone(o)) "IMPORT, NONE" else "not in the IMPORT list" }),
            .severity = C.Severity.err,
            .code = .import_excludes_name,
            .subject = u.name,
        };
    }
    return null;
}

fn isNone(scope: *const Obj) bool {
    for (scope.scopeDataConst().use.items) |u| if (u.is_import and u.import_type == .none) return true;
    return false;
}
