//! Part of linking (link.zig): the type of an ASSOCIATE selector that is
//! no variable, for the associate name (hover, the inlay hint): a literal
//! (`1.0`, `'abc'`, `7_8`), a call of an intrinsic function whose result
//! type is fixed or that of its first argument (`size(x)`, `abs(r)`), or
//! an expression of variables and literals with intrinsic operators
//! (`x(1) + 2`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Env = objects.Env;
const literals = @import("../literals.zig");
const argcheck = @import("../argcheck.zig");
const typing = @import("../argcheck/typing.zig");

/// A declared type: `INTEGER` and `(8)`
pub const Type = struct { desc: []const u8, kind: ?[]const u8 = null };

/// Whether `text` is a variable or a component of one (`x`, `t % c`), its
/// subscripts already removed: the selectors that are linked to what they
/// name
pub fn isDesignator(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '%');
    while (it.next()) |part| if (!typing.isName(std.mem.trim(u8, part, " \t"))) return false;
    return true;
}

/// The intrinsic functions whose result is a default integer, logical or
/// character, whatever their arguments
const fixed_results = [_]struct { []const u8, []const u8 }{
    .{ "INTEGER", "size len len_trim lbound ubound shape index scan verify count kind rank iachar ichar int nint floor ceiling maxloc minloc findloc popcnt poppar leadz trailz digits range precision radix maxexponent minexponent storage_size bit_size selected_int_kind selected_real_kind selected_char_kind command_argument_count num_images this_image exponent" },
    .{ "LOGICAL", "present allocated associated any all is_contiguous btest lge lgt lle llt is_iostat_end is_iostat_eor same_type_as extends_type_of" },
    .{ "CHARACTER", "trim adjustl adjustr repeat char achar new_line" },
    .{ "REAL", "real float sngl" },
    .{ "DOUBLE PRECISION", "dble dfloat" },
    .{ "COMPLEX", "cmplx" },
};

/// The intrinsic functions whose result has the type of their first
/// argument
const same_results = "abs sqrt exp log log10 sin cos tan asin acos atan atan2 sinh cosh tanh mod modulo sign max min sum product maxval minval dot_product matmul transpose merge huge tiny epsilon spacing nearest fraction aint anint dim iand ior ieor not ishft ishftc ibset ibclr ibits reshape pack unpack spread cshift eoshift";

fn inList(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |w| if (std.ascii.eqlIgnoreCase(w, name)) return true;
    return false;
}

/// The type of selector `text` in `scope` (1-based `line_no`), or null when
/// it cannot be told
pub fn typeOf(env: Env, scope: *Obj, text: []const u8, line_no: usize) Allocator.Error!?Type {
    return typeIn(env, scope, std.mem.trim(u8, text, " \t"), line_no, 0);
}

fn typeIn(env: Env, scope: *Obj, e: []const u8, line_no: usize, depth: usize) Allocator.Error!?Type {
    if (e.len == 0 or depth > 4) return null;
    const a = env.tmp;
    // a literal, its sign aside
    if (typing.literalCategory(e) != null) {
        const col: usize = if (e[0] == '-' or e[0] == '+') 1 else 0;
        const lit = (try literals.at(a, e, col)) orelse return null;
        if (std.mem.eql(u8, lit.type, "BOZ")) return null;
        const open = std.mem.findScalar(u8, lit.type, '(') orelse return .{ .desc = lit.type };
        return .{ .desc = lit.type[0..open], .kind = lit.type[open..] };
    }
    // a call of an intrinsic function, which no name of the scope hides
    if (std.mem.findScalar(u8, e, '(')) |open| if (e[e.len - 1] == ')' and typing.matching(e, open) == e.len - 1) {
        const name = std.mem.trim(u8, e[0..open], " \t");
        if (typing.isName(name)) {
            const lower = try std.ascii.allocLowerString(a, name);
            const hidden = if (try objects.findInScope(env, scope, lower, .{ .var_line_number = line_no })) |o| o.kind != .intrinsic else false;
            if (!hidden) {
                for (fixed_results) |r| if (inList(r[1], name)) return .{ .desc = r[0] };
                if (inList(same_results, name)) {
                    const args = e[open + 1 .. e.len - 1];
                    const first = std.mem.trim(u8, args[0 .. typing.topLevel(args, ',') orelse args.len], " \t");
                    if (typing.keywordOf(first) != null) return null;
                    const t = (try typeIn(env, scope, first, line_no, depth + 1)) orelse return null;
                    // the absolute value of a complex number is real
                    if (std.ascii.eqlIgnoreCase(name, "abs") and std.ascii.eqlIgnoreCase(t.desc, "COMPLEX")) return .{ .desc = "REAL", .kind = t.kind };
                    return t;
                }
                return null;
            }
        }
    };
    const typed = (try argcheck.expressionType(a, env, scope.file_ast, scope, e, line_no)) orelse return null;
    // a variable of derived type is linked, not typed here
    if (typed.obj) |o| if (typed.cat != .derived) {
        if (o.varDataConst().vkind) |k| return .{ .desc = o.descOf(), .kind = k };
        return .{ .desc = o.descOf() };
    };
    return switch (typed.cat) {
        .integer => .{ .desc = "INTEGER" },
        .real => .{ .desc = "REAL" },
        .complex => .{ .desc = "COMPLEX" },
        .logical => .{ .desc = "LOGICAL" },
        .character => .{ .desc = "CHARACTER" },
        .derived, .unknown => null,
    };
}

test "designators" {
    try std.testing.expect(isDesignator("x"));
    try std.testing.expect(isDesignator(" t % c "));
    try std.testing.expect(!isDesignator("x + 2"));
    try std.testing.expect(!isDesignator("1.0"));
    try std.testing.expect(!isDesignator(""));
}
