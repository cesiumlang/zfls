//! LLVM IR's types as text, parsed, and their layout (sizes, alignments,
//! a structure's offsets), for the types of LFortran's variables
//! (lfortran_types.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An IR type, parsed
pub const Ty = union(enum) {
    int: u32,
    float,
    double,
    ptr,
    array: struct { count: u64, elem: *const Ty },
    structure: struct { fields: []const Ty, packed_: bool },
    named: []const u8,
    other,
};

pub const Layout = struct { size: u64, align_: u64 };

pub const Types = struct {
    a: Allocator,
    defs: std.StringHashMapUnmanaged(Ty) = .empty,

    pub fn parse(t: *Types, text_in: []const u8) Allocator.Error!Ty {
        var text = std.mem.trim(u8, text_in, " ");
        if (text.len == 0) return .other;
        if (text[0] == '%') return .{ .named = text };
        if (std.mem.eql(u8, text, "ptr")) return .ptr;
        if (std.mem.eql(u8, text, "float")) return .float;
        if (std.mem.eql(u8, text, "double")) return .double;
        if (text[0] == 'i') return .{ .int = std.fmt.parseInt(u32, text[1..], 10) catch return .other };
        if (text[0] == '[') {
            const x = std.mem.find(u8, text, " x ") orelse return .other;
            const elem = try t.a.create(Ty);
            elem.* = try t.parse(text[x + 3 .. text.len - 1]);
            return .{ .array = .{ .count = std.fmt.parseInt(u64, std.mem.trim(u8, text[1..x], " "), 10) catch return .other, .elem = elem } };
        }
        var packed_ = false;
        if (std.mem.startsWith(u8, text, "<{") and std.mem.endsWith(u8, text, "}>")) {
            packed_ = true;
            text = text[1 .. text.len - 1];
        }
        if (text[0] != '{' or text[text.len - 1] != '}') return .other;
        var fields: std.ArrayList(Ty) = .empty;
        for (try splitTop(t.a, text[1 .. text.len - 1])) |f| try fields.append(t.a, try t.parse(f));
        return .{ .structure = .{ .fields = fields.items, .packed_ = packed_ } };
    }

    pub fn resolve(t: *const Types, ty: Ty) Ty {
        return switch (ty) {
            .named => |n| t.defs.get(n) orelse .other,
            else => ty,
        };
    }

    pub fn layout(t: *const Types, ty: Ty) Layout {
        return switch (t.resolve(ty)) {
            .int => |bits| blk: {
                const n: u64 = @max(1, (bits + 7) / 8);
                break :blk .{ .size = n, .align_ = @min(n, 8) };
            },
            .float => .{ .size = 4, .align_ = 4 },
            .double, .ptr => .{ .size = 8, .align_ = 8 },
            .array => |arr| blk: {
                const e = t.layout(arr.elem.*);
                break :blk .{ .size = arr.count * e.size, .align_ = e.align_ };
            },
            .structure => |st| blk: {
                var off: u64 = 0;
                var al: u64 = 1;
                for (st.fields) |f| {
                    const l = t.layout(f);
                    if (!st.packed_) off = std.mem.alignForward(u64, off, l.align_);
                    off += l.size;
                    if (!st.packed_) al = @max(al, l.align_);
                }
                break :blk .{ .size = std.mem.alignForward(u64, off, al), .align_ = al };
            },
            .named, .other => .{ .size = 0, .align_ = 1 },
        };
    }

    /// The offsets of a structure's fields
    pub fn offsets(t: *const Types, a: Allocator, st: anytype) ![]u64 {
        const out = try a.alloc(u64, st.fields.len);
        var off: u64 = 0;
        for (st.fields, out) |f, *o| {
            const l = t.layout(f);
            if (!st.packed_) off = std.mem.alignForward(u64, off, l.align_);
            o.* = off;
            off += l.size;
        }
        return out;
    }
};

/// The fields of a struct type's text, split at its top-level commas
pub fn splitTop(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| switch (c) {
        '{', '[', '<', '(' => depth += 1,
        '}', ']', '>', ')' => depth -|= 1,
        ',' => if (depth == 0) {
            try out.append(a, text[start..i]);
            start = i + 1;
        },
        else => {},
    };
    if (std.mem.trim(u8, text[start..], " ").len > 0) try out.append(a, text[start..]);
    return out.items;
}

/// A type's text, as the IR writes it
pub fn writeType(a: Allocator, out: *std.ArrayList(u8), ty: Ty) Allocator.Error!void {
    switch (ty) {
        .int => |bits| try out.print(a, "i{d}", .{bits}),
        .float => try out.appendSlice(a, "float"),
        .double => try out.appendSlice(a, "double"),
        .ptr => try out.appendSlice(a, "ptr"),
        .array => |arr| {
            try out.print(a, "[{d} x ", .{arr.count});
            try writeType(a, out, arr.elem.*);
            try out.append(a, ']');
        },
        .structure => |st| {
            try out.appendSlice(a, if (st.packed_) "<{" else "{");
            for (st.fields, 0..) |f, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeType(a, out, f);
            }
            try out.appendSlice(a, if (st.packed_) "}>" else "}");
        },
        .named => |n| try out.appendSlice(a, n),
        .other => try out.appendSlice(a, "?"),
    }
}
