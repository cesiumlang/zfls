//! USE and IMPORT statements, and the ordered sets and maps of names
//! that their ONLY lists and renames are

const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("../objects.zig").Obj;

pub const ImportType = enum(i8) { default = -1, none = 0, all = 1, only = 2 };

/// USE or IMPORT statement
pub const UseStmt = struct {
    mod_name: []const u8,
    only_list: StrSet = .{},
    rename_map: StrMap = .{},
    line_number: usize = 0,
    is_import: bool = false,
    import_type: ImportType = .default,
    /// Parent scope of IMPORT statement i.e. parent of the interface
    scope: ?*Obj = null,
    /// A copy of a USE statement of an included file, in the including
    /// scope at the include line (`Ast.linkIncludeScope`)
    included: bool = false,

    /// Construct (lowercasing names like the Python `Use` initializer)
    pub fn init(a: Allocator, mod_name: []const u8, only: []const []const u8, renames: []const [2][]const u8) !*UseStmt {
        const u = try a.create(UseStmt);
        u.* = .{ .mod_name = try std.ascii.allocLowerString(a, mod_name) };
        for (only) |o| try u.only_list.add(a, try std.ascii.allocLowerString(a, o));
        for (renames) |r| try u.rename_map.put(a, try std.ascii.allocLowerString(a, r[0]), try std.ascii.allocLowerString(a, r[1]));
        return u;
    }

    /// The name in the used module of what this statement makes `local`
    /// (lowercase) in the scope that has it, or null when it does not make
    /// `local` a name there
    pub fn nameThere(self: *const UseStmt, local: []const u8) ?[]const u8 {
        if (self.only_list.len() > 0 and !self.only_list.contains(local)) return null;
        if (self.rename_map.get(local)) |name| return name;
        // without ONLY, a renamed entity is not accessible under its own name
        if (self.only_list.len() == 0 and self.rename_map.hasValue(local)) return null;
        return local;
    }

    /// Rename ONLY:, statements
    pub fn rename(self: *const UseStmt, a: Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.only_list.items.items) |name| {
            try out.append(a, self.rename_map.get(name) orelse name);
        }
        return out.items;
    }
};

/// Ordered string set (stand-in for Python `set[str]`)
pub const StrSet = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn contains(self: *const StrSet, s: []const u8) bool {
        for (self.items.items) |it| if (std.mem.eql(u8, it, s)) return true;
        return false;
    }

    pub fn add(self: *StrSet, a: Allocator, s: []const u8) !void {
        if (!self.contains(s)) try self.items.append(a, s);
    }

    pub fn len(self: *const StrSet) usize {
        return self.items.items.len;
    }

    pub fn clone(self: *const StrSet, a: Allocator) !StrSet {
        return .{ .items = try self.items.clone(a) };
    }
};

/// Ordered string map (stand-in for Python `dict[str, str]`)
pub const StrMap = struct {
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn hasValue(self: *const StrMap, v: []const u8) bool {
        for (self.values.items) |value| if (std.mem.eql(u8, value, v)) return true;
        return false;
    }

    pub fn get(self: *const StrMap, k: []const u8) ?[]const u8 {
        for (self.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) return self.values.items[i];
        return null;
    }

    pub fn put(self: *StrMap, a: Allocator, k: []const u8, v: []const u8) !void {
        for (self.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) {
            self.values.items[i] = v;
            return;
        };
        try self.keys.append(a, k);
        try self.values.append(a, v);
    }

    pub fn remove(self: *StrMap, k: []const u8) void {
        for (self.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) {
            _ = self.keys.orderedRemove(i);
            _ = self.values.orderedRemove(i);
            return;
        };
    }

    pub fn count(self: *const StrMap) usize {
        return self.keys.items.len;
    }

    pub fn clone(self: *const StrMap, a: Allocator) !StrMap {
        return .{ .keys = try self.keys.clone(a), .values = try self.values.clone(a) };
    }
};
