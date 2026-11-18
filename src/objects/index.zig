//! An index of a scope's children by name (#209), for `checkScope`: for
//! each name, ignoring case, the positions in the child list where the
//! name can be found. A position holds a name when the child has it, when
//! the child is an `ENUM` with an enumerator of that name, or when the
//! child is a generic interface (`#GEN_INT`) that holds it. `checkScope`
//! visits those positions in order and applies the same rules as it does
//! when it walks every child, so a lookup finds what the walk would.
//!
//! The index is built at a scope's first lookup and built again after its
//! children change (`changed`). Only scopes with many children get one:
//! for a few, walking them is as fast.

const std = @import("std");
const objects = @import("../objects.zig");
const Obj = objects.Obj;

/// The fewest children a scope has for its lookups to use an index
pub const min_children = 32;

const none = std.math.maxInt(u32);

/// Hashes and compares names ignoring ASCII case, so that the keys are the
/// children's own names, not lowercased copies
const NameContext = struct {
    pub fn hash(_: NameContext, s: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        var buf: [64]u8 = undefined;
        var i: usize = 0;
        while (i < s.len) {
            const n = @min(buf.len, s.len - i);
            for (buf[0..n], s[i .. i + n]) |*d, c| d.* = std.ascii.toLower(c);
            h.update(buf[0..n]);
            i += n;
        }
        return h.final();
    }
    pub fn eql(_: NameContext, x: []const u8, y: []const u8) bool {
        return std.ascii.eqlIgnoreCase(x, y);
    }
};

/// The first and last of a name's entries
const Span = struct { first: u32, last: u32 };

pub const ChildIndex = struct {
    /// Rebuilt from the children, not saved in the index cache
    pub const not_saved = {};

    valid: bool = false,
    names: std.HashMapUnmanaged([]const u8, Span, NameContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Of each entry: the position in the child list, and the next entry of
    /// the same name (`none` after the last)
    pos: std.ArrayList(u32) = .empty,
    next: std.ArrayList(u32) = .empty,

    /// The positions where `name` can be found, in order
    pub const Iterator = struct {
        index: *const ChildIndex,
        entry: u32,

        pub fn next(it: *Iterator) ?u32 {
            if (it.entry == none) return null;
            defer it.entry = it.index.next.items[it.entry];
            return it.index.pos.items[it.entry];
        }
    };

    pub fn find(self: *const ChildIndex, name: []const u8) Iterator {
        return .{ .index = self, .entry = if (self.names.get(name)) |s| s.first else none };
    }
};

/// The index of `scope`'s children, built if it is not; null when the scope
/// has too few children for one
pub fn of(scope: *Obj) std.mem.Allocator.Error!?*const ChildIndex {
    if (scope.data != .scope) return null;
    const children = scope.childList();
    if (children.len < min_children) return null;
    const index = &scope.scopeData().index;
    if (index.valid) return index;
    // in the scope's own memory, which is freed with its file's AST; built
    // again into the same lists, so that rebuilding does not grow it
    const a = scope.al();
    index.names.clearRetainingCapacity();
    index.pos.clearRetainingCapacity();
    index.next.clearRetainingCapacity();
    for (children, 0..) |child, i| try addNames(a, index, child, @intCast(i));
    index.valid = true;
    return index;
}

/// Add the names that `checkScope` can find at position `pos` through `obj`
fn addNames(a: std.mem.Allocator, index: *ChildIndex, obj: *const Obj, pos: u32) std.mem.Allocator.Error!void {
    try add(a, index, obj.name, pos);
    if (obj.kind == .enum_) for (obj.childList()) |e| try add(a, index, e.name, pos);
    if (std.mem.startsWith(u8, obj.name, "#GEN_INT")) for (obj.childList()) |c| try addNames(a, index, c, pos);
}

fn add(a: std.mem.Allocator, index: *ChildIndex, name: []const u8, pos: u32) std.mem.Allocator.Error!void {
    const entry: u32 = @intCast(index.pos.items.len);
    const gop = try index.names.getOrPut(a, name);
    if (gop.found_existing) {
        // once per position
        if (index.pos.items[gop.value_ptr.last] == pos) return;
        index.next.items[gop.value_ptr.last] = entry;
        gop.value_ptr.last = entry;
    } else gop.value_ptr.* = .{ .first = entry, .last = entry };
    try index.pos.append(a, pos);
    try index.next.append(a, none);
}

/// Mark the index of `scope` out of date after its children changed, and
/// those of the scopes whose index holds its children's names: the scope
/// is an `ENUM` or a generic interface there
pub fn changed(scope: *Obj) void {
    var s: ?*Obj = scope;
    while (s) |o| : (s = o.parent) {
        if (o.data == .scope) o.scopeData().index.valid = false;
        if (o.kind != .enum_ and !std.mem.startsWith(u8, o.name, "#GEN_INT")) return;
    }
}
