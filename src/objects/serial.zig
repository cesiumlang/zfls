//! A parsed file's AST as bytes and back, for the index cache: a start that
//! finds a file's AST there does not parse the file again. Only an AST just
//! parsed is saved, before linking, when none of its objects refers to
//! another file's. An object is written where it is first met, and a later
//! reference to it is its number.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const KeywordInfo = @import("../helpers.zig").KeywordInfo;
const FortranFile = @import("../parser.zig").FortranFile;

/// The fields of an AST that are not saved as they are: its memory and file
/// (set by `Ast.create`), the state of parsing (regular expressions), and
/// `global_dict`, saved by hand
fn byHand(comptime name: []const u8) bool {
    const names = [_][]const u8{ "arena", "file", "path", "end_stack", "end_scope_regex", "global_dict" };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// A hash of the types saved, their fields and enumerations: a cache written
/// by a zfls whose types differ is not read
pub const schema: u64 = typeHash(Ast);

fn typeHash(comptime T: type) u64 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var h = std.hash.Fnv1a_64.init();
        // a list is its items (its other fields differ by build mode)
        if (isList(T)) {
            h.update("list");
            h.update(&std.mem.toBytes(typeHash(ListItem(T))));
            return h.final();
        }
        h.update(@typeName(T));
        switch (@typeInfo(T)) {
            .@"struct" => |s| for (s.field_names, s.field_types) |name, F| {
                if (T == Ast and byHand(name)) continue;
                h.update(name);
                h.update(&std.mem.toBytes(typeHash(F)));
            },
            .@"union" => |u| for (u.field_names, u.field_types) |name, F| {
                h.update(name);
                h.update(&std.mem.toBytes(typeHash(F)));
            },
            .@"enum" => |e| for (e.field_names, e.field_values) |name, v| {
                h.update(name);
                h.update(&std.mem.toBytes(@as(i128, v)));
            },
            .optional => |o| h.update(&std.mem.toBytes(typeHash(o.child))),
            .array => |a| h.update(&std.mem.toBytes(typeHash(a.child))),
            .pointer => |p| if (p.child != Obj and p.child != Ast and p.child != FortranFile) {
                h.update(&std.mem.toBytes(typeHash(p.child)));
            },
            else => {},
        }
        return h.final();
    }
}

/// A `std.ArrayList`: saved as its items, loaded with no spare capacity
fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity") and @hasDecl(T, "Slice");
}

fn ListItem(comptime T: type) type {
    return @typeInfo(@FieldType(T, "items")).pointer.child;
}

fn isPtrTo(comptime T: type, comptime Child: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and p.child == Child,
        else => false,
    };
}

pub const SaveError = error{ OutOfMemory, Foreign };

/// `ast`, just parsed, as bytes owned by `gpa`; `error.Foreign` when an
/// object refers to another file's
pub fn save(gpa: Allocator, ast: *const Ast) SaveError![]u8 {
    var s: Saver = .{ .gpa = gpa, .ast = ast };
    defer s.ids.deinit(gpa);
    errdefer s.out.deinit(gpa);
    try s.uint(ast.global_dict.count());
    var it = ast.global_dict.iterator();
    while (it.next()) |e| {
        try s.value([]const u8, e.key_ptr.*);
        try s.ref(e.value_ptr.*);
    }
    const info = @typeInfo(Ast).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (comptime !byHand(name)) try s.value(F, @field(ast, name));
    }
    return s.out.toOwnedSlice(gpa);
}

const Saver = struct {
    gpa: Allocator,
    ast: *const Ast,
    out: std.ArrayList(u8) = .empty,
    ids: std.AutoHashMapUnmanaged(*const Obj, u32) = .empty,

    fn byte(s: *Saver, b: u8) !void {
        try s.out.append(s.gpa, b);
    }

    /// LEB128
    fn uint(s: *Saver, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try s.byte(@as(u8, @truncate(x)) | 0x80);
        try s.byte(@truncate(x));
    }

    /// 0 for null, 1 and the object where it is first met, else its number + 2
    fn ref(s: *Saver, o: ?*const Obj) SaveError!void {
        const obj = o orelse return s.uint(0);
        if (s.ids.get(obj)) |id| return s.uint(@as(u64, id) + 2);
        if (obj.file_ast != s.ast) return error.Foreign;
        try s.ids.put(s.gpa, obj, s.ids.count());
        try s.uint(1);
        try s.value(Obj, obj.*);
    }

    fn value(s: *Saver, comptime T: type, v: T) SaveError!void {
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try s.byte(@intFromBool(v)),
            .int => |i| if (comptime i.signedness == .signed) {
                const x: i64 = v;
                try s.uint(@bitCast((x << 1) ^ (x >> 63)));
            } else try s.uint(v),
            .@"enum" => |e| try s.value(e.tag_type, @backingInt(v)),
            .optional => |o| {
                if (comptime isPtrTo(o.child, Obj)) return s.ref(v);
                // a file's AST has only those of other files' includes, once linked
                if (comptime isPtrTo(o.child, FortranFile)) {
                    if (v != null) return error.Foreign;
                    return;
                }
                if (v) |x| {
                    try s.byte(1);
                    try s.value(o.child, x);
                } else try s.byte(0);
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    try s.uint(v.len);
                    if (p.child == u8) {
                        try s.out.appendSlice(s.gpa, v);
                    } else for (v) |x| try s.value(p.child, x);
                },
                .one => if (p.child == Obj) {
                    try s.ref(v);
                } else if (p.child == Ast) {
                    if (v != s.ast) return error.Foreign;
                } else if (p.child == KeywordInfo) {
                    if (v == &KeywordInfo.empty) return s.byte(0);
                    try s.byte(1);
                    try s.value(KeywordInfo, v.*);
                } else try s.value(p.child, v.*),
                else => @compileError("not saved: " ++ @typeName(T)),
            },
            .@"struct" => |st| if (comptime isList(T)) {
                try s.value([]const ListItem(T), v.items);
            } else inline for (st.field_names, st.field_types) |name, F| try s.value(F, @field(v, name)),
            .@"union" => |u| {
                const tag = std.meta.activeTag(v);
                try s.uint(@backingInt(tag));
                inline for (u.field_names, u.field_types) |name, F| {
                    if (tag == @field(std.meta.Tag(T), name)) try s.value(F, @field(v, name));
                }
            },
            .array => |a| for (v) |x| try s.value(a.child, x),
            else => @compileError("not saved: " ++ @typeName(T)),
        }
    }
};

pub const LoadError = error{ OutOfMemory, Format };

/// Fills `ast`, created for its file (`Ast.create`), with the AST saved in
/// `data`; `gpa` is for the time of loading
pub fn load(gpa: Allocator, ast: *Ast, data: []const u8) LoadError!void {
    var l: Loader = .{ .a = ast.allocator(), .gpa = gpa, .ast = ast, .data = data };
    defer l.objs.deinit(gpa);
    const n = try l.len();
    try ast.global_dict.ensureTotalCapacity(l.a, n);
    for (0..n) |_| {
        const key = try l.value([]const u8);
        ast.global_dict.putAssumeCapacity(key, try l.ref() orelse return error.Format);
    }
    const info = @typeInfo(Ast).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (comptime !byHand(name)) @field(ast, name) = try l.value(F);
    }
    if (l.at != data.len) return error.Format;
}

const Loader = struct {
    /// the AST's
    a: Allocator,
    gpa: Allocator,
    ast: *Ast,
    data: []const u8,
    at: usize = 0,
    objs: std.ArrayList(*Obj) = .empty,

    fn byte(l: *Loader) !u8 {
        if (l.at >= l.data.len) return error.Format;
        defer l.at += 1;
        return l.data[l.at];
    }

    fn uint(l: *Loader) !u64 {
        var x: u64 = 0;
        var shift: u32 = 0;
        while (true) : (shift += 7) {
            const b = try l.byte();
            if (shift > 63) return error.Format;
            x |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b < 0x80) return x;
        }
    }

    /// A count of things of at least a byte each
    fn len(l: *Loader) !usize {
        const n = try l.uint();
        if (n > l.data.len - l.at) return error.Format;
        return @intCast(n);
    }

    fn ref(l: *Loader) LoadError!?*Obj {
        const id = try l.uint();
        switch (id) {
            0 => return null,
            1 => {
                const o = try l.a.create(Obj);
                // numbered before its fields, which may refer to it
                try l.objs.append(l.gpa, o);
                o.* = try l.value(Obj);
                return o;
            },
            else => return if (id - 2 < l.objs.items.len) l.objs.items[@intCast(id - 2)] else error.Format,
        }
    }

    fn value(l: *Loader, comptime T: type) LoadError!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return switch (try l.byte()) {
                0 => false,
                1 => true,
                else => error.Format,
            },
            .int => |i| {
                const u = try l.uint();
                if (comptime i.signedness == .signed) {
                    const x: i64 = @as(i64, @bitCast(u >> 1)) ^ -@as(i64, @intCast(u & 1));
                    return std.math.cast(T, x) orelse error.Format;
                }
                return std.math.cast(T, u) orelse error.Format;
            },
            .@"enum" => |e| return std.enums.fromInt(T, try l.value(e.tag_type)) orelse error.Format,
            .optional => |o| {
                if (comptime isPtrTo(o.child, Obj)) return l.ref();
                if (comptime isPtrTo(o.child, FortranFile)) return null;
                return switch (try l.byte()) {
                    0 => null,
                    1 => try l.value(o.child),
                    else => error.Format,
                };
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    const n = try l.len();
                    if (p.child == u8) {
                        defer l.at += n;
                        return l.a.dupe(u8, l.data[l.at .. l.at + n]);
                    }
                    const out = try l.a.alloc(p.child, n);
                    for (out) |*x| x.* = try l.value(p.child);
                    return out;
                },
                .one => if (p.child == Obj) {
                    return try l.ref() orelse error.Format;
                } else if (p.child == Ast) {
                    return l.ast;
                } else if (p.child == KeywordInfo) {
                    if (try l.byte() == 0) return &KeywordInfo.empty;
                    const k = try l.a.create(KeywordInfo);
                    k.* = try l.value(KeywordInfo);
                    return k;
                } else {
                    const x = try l.a.create(p.child);
                    x.* = try l.value(p.child);
                    return x;
                },
                else => @compileError("not saved: " ++ @typeName(T)),
            },
            .@"struct" => |st| {
                if (comptime isList(T)) {
                    const items = try l.value([]ListItem(T));
                    var list: T = .empty;
                    list.items = items;
                    list.capacity = items.len;
                    return list;
                }
                var v: T = undefined;
                inline for (st.field_names, st.field_types) |name, F| @field(v, name) = try l.value(F);
                return v;
            },
            .@"union" => |u| {
                const tag = try l.uint();
                inline for (u.field_names, u.field_types) |name, F| {
                    if (tag == @backingInt(@field(std.meta.Tag(T), name))) return @unionInit(T, name, try l.value(F));
                }
                return error.Format;
            },
            .array => |a| {
                var v: T = undefined;
                for (&v) |*x| x.* = try l.value(a.child);
                return v;
            },
            else => @compileError("not saved: " ++ @typeName(T)),
        }
    }
};

test "an AST saved, loaded and saved again is the same" {
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    const src =
        \\!> A module
        \\module shapes
        \\  use iso_fortran_env, only: dp => real64, int32
        \\  implicit real(dp) (a-h, o-z)
        \\  private
        \\  public :: circle, area, make
        \\  integer, parameter :: n = 3
        \\  type, abstract :: shape
        \\    real(dp), allocatable :: x(:)
        \\  contains
        \\    procedure(area_if), deferred, pass(self) :: area
        \\  end type
        \\  type, extends(shape) :: circle
        \\    real(dp) :: r = 1
        \\  contains
        \\    procedure :: area => circle_area
        \\  end type
        \\  abstract interface
        \\    function area_if(self) result(a)
        \\      import :: shape, dp
        \\      class(shape), intent(in) :: self
        \\      real(dp) :: a
        \\    end function
        \\  end interface
        \\  interface make
        \\    module procedure make_circle
        \\  end interface
        \\contains
        \\  !> The area
        \\  real(dp) function circle_area(self)
        \\    class(circle), intent(in) :: self
        \\    circle_area = 3.14_dp * self%r**2
        \\  end function
        \\  function make_circle(r) result(c)
        \\    real(dp), intent(in) :: r
        \\    type(circle) :: c
        \\    c%r = r
        \\    associate (q => c%r, z => c%x(1))
        \\      select type (s => c)
        \\      type is (circle)
        \\        block
        \\          integer :: i
        \\          do i = 1, n
        \\            if (i > 2) exit
        \\          end do
        \\        end block
        \\      end select
        \\    end associate
        \\  end function
        \\end module
        \\submodule (shapes) impl
        \\end submodule
        \\program main
        \\  use shapes
        \\  include 'consts.inc'
        \\  external :: ext_sub
        \\  call ext_sub()
        \\end program
        \\end subroutine stray
    ;
    const f = try FortranFile.create(gpa, "/w/shapes.f90", null);
    defer f.destroy();
    _ = try f.setTextOwned(try gpa.dupe(u8, src));
    const ast = try f.parse(std.testing.io, null, &.{}, .{});
    defer ast.destroy();
    try std.testing.expect(ast.scope_list.items.len > 10);
    const bytes = try save(gpa, ast);
    defer gpa.free(bytes);
    const back = try Ast.create(gpa, f);
    defer back.destroy();
    try load(gpa, back, bytes);
    const again = try save(gpa, back);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    // the objects are linked as they were
    try std.testing.expectEqual(ast.scope_list.items.len, back.scope_list.items.len);
    try std.testing.expectEqual(ast.variable_list.items.len, back.variable_list.items.len);
    for (back.scope_list.items) |s| {
        try std.testing.expect(s.file_ast == back);
        for (s.childList()) |c| try std.testing.expect(c.parent == s or c.parent == null or c.parent.?.file_ast == back);
    }
    const mod = back.global_dict.get("shapes").?;
    try std.testing.expectEqualStrings("shapes", mod.name);
    // a loaded list has no spare capacity, and grows as any other (as
    // linking adds the objects of an INCLUDE)
    const first = mod.childList()[0];
    for (mod.scopeData().children.items) |c| try std.testing.expect(c.parent == mod);
    try std.testing.expectEqual(mod.childList().len, mod.scopeData().children.capacity);
    for (0..20) |_| try mod.addChild(try Obj.newScope(back, .scope, 1, "extra", &.{}));
    try std.testing.expect(mod.childList()[0] == first);
    try std.testing.expectEqualStrings(ast.global_dict.get("shapes").?.childList()[0].name, first.name);
    // a truncated or damaged AST is not loaded
    for ([_]usize{ 1, bytes.len / 2, bytes.len - 1 }) |cut| {
        const broken = try Ast.create(gpa, f);
        defer broken.destroy();
        try std.testing.expectError(error.Format, load(gpa, broken, bytes[0..cut]));
    }
}
