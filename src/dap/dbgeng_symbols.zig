//! dbghelp's lookups for the Debugger Engine (dbgeng.zig): the address of
//! a source line and the line of an address, the variables of a frame, the
//! globals of a name, and types with their members.
//! Part of `Engine` (dbgeng.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dbgeng = @import("dbgeng.zig");
const Engine = dbgeng.Engine;
const Variable = dbgeng.Variable;
const succeeded = dbgeng.succeeded;

// dbghelp (the engine's, by the same process handle)
pub const SymbolInfo = extern struct {
    SizeOfStruct: u32,
    TypeIndex: u32,
    Reserved: [2]u64,
    Index: u32,
    Size: u32,
    ModBase: u64,
    Flags: u32,
    Value: u64,
    Address: u64,
    Register: u32,
    Scope: u32,
    Tag: u32,
    NameLen: u32,
    MaxNameLen: u32,
    Name: [1]u8,
};
const ImagehlpStackFrame = extern struct {
    InstructionOffset: u64,
    ReturnOffset: u64,
    FrameOffset: u64,
    StackOffset: u64,
    BackingStoreOffset: u64,
    FuncTableEntry: u64,
    Params: [4]u64,
    Reserved: [5]u64,
    Virtual: i32,
    Reserved2: u32,
};
const EnumCallback = *const fn (*SymbolInfo, u32, ?*anyopaque) callconv(.winapi) i32;
extern "dbghelp" fn SymSetContext(h: usize, frame: *ImagehlpStackFrame, ctx: ?*anyopaque) callconv(.winapi) i32;
extern "dbghelp" fn SymEnumSymbols(h: usize, base: u64, mask: ?[*:0]const u8, cb: EnumCallback, ctx: ?*anyopaque) callconv(.winapi) i32;
extern "dbghelp" fn SymGetTypeInfo(h: usize, base: u64, type_id: u32, kind: u32, out: *anyopaque) callconv(.winapi) i32;
const SrcCodeInfoW = extern struct {
    SizeOfStruct: u32,
    Key: ?*anyopaque,
    ModBase: u64,
    Obj: [261]u16,
    FileName: [261]u16,
    LineNumber: u32,
    Address: u64,
};
extern "dbghelp" fn SymEnumLinesW(h: usize, base: u64, obj: ?[*:0]const u16, file: ?[*:0]const u16, cb: *const fn (*SrcCodeInfoW, ?*anyopaque) callconv(.winapi) i32, ctx: ?*anyopaque) callconv(.winapi) i32;
extern "dbghelp" fn SymFromName(h: usize, name: [*:0]const u8, info: *SymbolInfo) callconv(.winapi) i32;
const LineW64 = extern struct { SizeOfStruct: u32, Key: ?*anyopaque, LineNumber: u32, FileName: ?[*:0]u16, Address: u64 };
extern "dbghelp" fn SymGetLineFromAddrW64(h: usize, address: u64, displacement: *u32, line: *LineW64) callconv(.winapi) i32;
extern "dbghelp" fn SymEnumTypesByName(h: usize, base: u64, mask: [*:0]const u8, cb: EnumCallback, ctx: ?*anyopaque) callconv(.winapi) i32;
extern "dbghelp" fn SymEnumerateModulesW64(h: usize, cb: *const fn ([*:0]const u16, u64, ?*anyopaque) callconv(.winapi) i32, ctx: ?*anyopaque) callconv(.winapi) i32;

const SYMFLAG_REGISTER = 0x8;
const SYMFLAG_REGREL = 0x10;
const SYMFLAG_PARAMETER = 0x40;
const SYMFLAG_LOCAL = 0x80;
/// The variable's address is at the register plus the offset (LLVM's
/// `S_DEFRANGE_REGISTER_REL_INDIR`: LLVM Flang's dummy arguments)
const SYMFLAG_REGREL_ALIASINDIR = 0x800000;

/// dbghelp's questions about a type (`IMAGEHLP_SYMBOL_TYPE_INFO`)
pub const TypeQuery = enum(u32) {
    symtag = 0,
    symname = 1,
    length = 2,
    type = 4,
    basetype = 6,
    childrencount = 13,
    count = 12,
    findchildren = 7,
    offset = 10,
};

/// dbghelp's kinds of types (`SymTagEnum`)
pub const SymTag = enum(u32) {
    udt = 11,
    enumeration = 12,
    function_type = 13,
    pointer = 14,
    array = 15,
    base = 16,
    typedef = 17,
    data = 7,
    base_class = 18,
    custom = 28,
    _,
};

/// The address of the code of `file`:`line` in the loaded modules
pub fn lineOffset(self: *Engine, a: Allocator, file: []const u8, line: u32) !?u64 {
    if (try lineFromRecords(self, a, file, line)) |at| return at;
    for ([_][]const u8{ file, std.Io.Dir.path.basename(file) }) |name| {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
        var off: u64 = 0;
        const hr = self.symbols.GetOffsetByLineWide(line, w.ptr, &off);
        if (succeeded(hr) and off != 0) return off;
        dbgeng.last_failure = @bitCast(hr);
        dbgeng.line_lookups[if (std.mem.eql(u8, name, file)) 0 else 1] = @bitCast(hr);
    }
    return null;
}

/// The address of `file`:`line` from the line records of the loaded
/// modules, matched here (dbghelp's own lookup by a file's name fails
/// on some Windows): the file by its path, else by its name; the line,
/// else the next one with code
fn lineFromRecords(self: *Engine, a: Allocator, file: []const u8, line: u32) !?u64 {
    var want: Lines = .{ .a = a, .line = line, .path = try normalized(a, file), .name = try normalized(a, std.Io.Dir.path.basename(file)) };
    var loaded: u32 = 0;
    var unloaded: u32 = 0;
    if (!succeeded(self.symbols.GetNumberModules(&loaded, &unloaded))) return null;
    for (0..loaded) |i| {
        var base: u64 = 0;
        if (!succeeded(self.symbols.GetModuleByIndex(@intCast(i), &base))) continue;
        _ = SymEnumLinesW(self.process, base, null, null, &Lines.onLine, &want);
    }
    const best = if (want.by_path.found) want.by_path else want.by_name;
    return if (best.found) best.address else null;
}

const Pick = struct { found: bool = false, line: u32 = 0, address: u64 = 0 };

const Lines = struct {
    a: Allocator,
    line: u32,
    path: []const u8,
    name: []const u8,
    by_path: Pick = .{},
    by_name: Pick = .{},

    fn onLine(info: *SrcCodeInfoW, raw: ?*anyopaque) callconv(.winapi) i32 {
        const w: *Lines = @ptrCast(@alignCast(raw.?));
        if (info.LineNumber < w.line) return 1;
        const n = std.mem.findScalar(u16, &info.FileName, 0) orelse info.FileName.len;
        const name = std.unicode.utf16LeToUtf8Alloc(w.a, info.FileName[0..n]) catch return 1;
        const path = normalized(w.a, name) catch return 1;
        if (std.mem.eql(u8, path, w.path)) {
            keep(&w.by_path, info);
        } else if (std.mem.endsWith(u8, path, w.name) and (path.len == w.name.len or path[path.len - w.name.len - 1] == '\\')) {
            keep(&w.by_name, info);
        }
        return 1;
    }

    /// The line asked for, else the nearest after it; its lowest address
    fn keep(p: *Pick, info: *const SrcCodeInfoW) void {
        if (!p.found or info.LineNumber < p.line or (info.LineNumber == p.line and info.Address < p.address)) {
            p.* = .{ .found = true, .line = info.LineNumber, .address = info.Address };
        }
    }
};

/// A path for comparing: lowercase, backslashes
fn normalized(a: Allocator, p: []const u8) ![]const u8 {
    const out = try std.ascii.allocLowerString(a, p);
    for (out) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    return out;
}

/// The line of the last of the line records at `address` exactly: LLVM
/// Flang's line tables have empty ones before a statement's (an END
/// statement's code after rows of the declarations), of which the
/// engine gives the first
pub fn lastLineAt(self: *Engine, address: u64, file: [*:0]const u16) ?u32 {
    var line = std.mem.zeroes(LineW64);
    line.SizeOfStruct = @sizeOf(LineW64);
    var displacement: u32 = 0;
    if (SymGetLineFromAddrW64(self.process, address, &displacement, &line) == 0 or displacement != 0) return null;
    // (dbghelp's next record of one at the address is not the next
    // one there: all of the file's, in order)
    var last: LastAt = .{ .address = address };
    _ = SymEnumLinesW(self.process, self.moduleBase(address) orelse return null, null, file, &LastAt.onLine, &last);
    return last.line;
}

const LastAt = struct {
    address: u64,
    line: ?u32 = null,

    fn onLine(info: *SrcCodeInfoW, raw: ?*anyopaque) callconv(.winapi) i32 {
        const w: *LastAt = @ptrCast(@alignCast(raw.?));
        if (info.Address == w.address) w.line = info.LineNumber;
        return 1;
    }
};

/// The variables of frame `index` of `thread`: its arguments and locals
/// (dbghelp's, with their places), statics too
pub fn variables(self: *Engine, a: Allocator, thread: u32, index: u32) ![]Variable {
    const frames = try self.stack(a, thread, index + 1);
    if (index >= frames.len) return &.{};
    const f = frames[index];
    _ = self.symbols.SetScopeFrameByIndex(index);
    var sf = std.mem.zeroes(ImagehlpStackFrame);
    sf.InstructionOffset = f.instruction;
    sf.FrameOffset = f.frame_offset;
    sf.StackOffset = f.stack_offset;
    _ = SymSetContext(self.process, &sf, null);
    var ctx: Collect = .{ .a = a, .engine = self };
    _ = SymEnumSymbols(self.process, 0, null, &Collect.onSymbol, &ctx);
    if (ctx.failed) return error.OutOfMemory;
    return ctx.out.items;
}

const Collect = struct {
    a: Allocator,
    engine: *Engine,
    out: std.ArrayList(Variable) = .empty,
    failed: bool = false,

    fn onSymbol(s: *SymbolInfo, _: u32, raw: ?*anyopaque) callconv(.winapi) i32 {
        const c: *Collect = @ptrCast(@alignCast(raw.?));
        const name_ptr: [*]const u8 = @ptrCast(&s.Name);
        const name = name_ptr[0..s.NameLen];
        var address = s.Address;
        if (s.Flags & SYMFLAG_REGREL != 0) {
            const base = frameRegister(c.engine, s.Register) orelse return 1;
            address = base +% s.Address;
        } else if (s.Flags & SYMFLAG_REGREL_ALIASINDIR != 0) {
            // the address is in the frame: at the register plus the offset
            const base = frameRegister(c.engine, s.Register) orelse return 1;
            var p: [8]u8 = undefined;
            address = if (c.engine.read(base +% s.Address, &p) == 8) std.mem.readInt(u64, &p, .little) else 0;
        } else if (s.Flags & SYMFLAG_REGISTER != 0) {
            return 1; // in a register: not addressable (optimized code)
        }
        c.out.append(c.a, .{
            .name = c.a.dupe(u8, name) catch {
                c.failed = true;
                return 0;
            },
            .address = address,
            .size = s.Size,
            .type_index = s.TypeIndex,
            .mod_base = s.ModBase,
            .parameter = s.Flags & SYMFLAG_PARAMETER != 0,
        }) catch {
            c.failed = true;
            return 0;
        };
        return 1;
    }
};

/// A register of the scope's frame, by CodeView's number
fn frameRegister(self: *Engine, cv: u32) ?u64 {
    return self.register(switch (cv) {
        334 => "rbp",
        335 => "rsp",
        else => return null,
    });
}

/// A global (a module variable: `GRID_mp_CELLS`, `_QMgridEcells`; a
/// function: `_QQmain`, `for__issue_diagnostic`), by the name the
/// compiler wrote. dbghelp, with the engine's options, drops the leading
/// `_` of C's names (`_QQmain` is `QQmain`), and finds a name without
/// its module's name (`grid!QQmain`) only in the modules whose symbols
/// are loaded already: so both names, unqualified, then in each module.
/// A public symbol (LLVM Flang's `_QMgridEcells`) has no type: see
/// `dataAt`
pub fn global(self: *Engine, a: Allocator, name: []const u8) !?Variable {
    var buf: [@sizeOf(SymbolInfo) + 512]u8 align(8) = undefined;
    const info: *SymbolInfo = @ptrCast(&buf);
    const plain = withoutUnderscore(name);
    const names: []const []const u8 = if (plain.len < name.len) &.{ name, plain } else &.{name};
    const found = found: {
        for (names) |n| if (fromName(self.process, info, try a.dupeSentinel(u8, n, 0))) break :found true;
        for (try moduleNames(self, a)) |m| {
            for (names) |n| if (fromName(self.process, info, try a.printSentinel("{s}!{s}", .{ m, n }, 0))) break :found true;
        }
        break :found false;
    };
    if (!found) return null;
    return .{ .name = try a.dupe(u8, name), .address = info.Address, .size = info.Size, .type_index = info.TypeIndex, .mod_base = info.ModBase, .parameter = false };
}

fn fromName(process: usize, info: *SymbolInfo, name: [:0]const u8) bool {
    info.SizeOfStruct = @sizeOf(SymbolInfo);
    info.MaxNameLen = 512;
    return SymFromName(process, name.ptr, info) != 0;
}

/// dbghelp's names of the loaded modules (`grid`, `ntdll`), which are
/// not always the engine's (`grid_exe`)
fn moduleNames(self: *Engine, a: Allocator) ![]const []const u8 {
    var names: Names = .{ .a = a };
    _ = SymEnumerateModulesW64(self.process, &Names.onModule, &names);
    if (names.failed) return error.OutOfMemory;
    return names.out.items;
}

const Names = struct {
    a: Allocator,
    out: std.ArrayList([]const u8) = .empty,
    failed: bool = false,

    fn onModule(name: [*:0]const u16, _: u64, raw: ?*anyopaque) callconv(.winapi) i32 {
        const n: *Names = @ptrCast(@alignCast(raw.?));
        const utf8 = std.unicode.utf16LeToUtf8Alloc(n.a, std.mem.span(name)) catch {
            n.failed = true;
            return 0;
        };
        n.out.append(n.a, utf8) catch {
            n.failed = true;
            return 0;
        };
        return 1;
    }
};

/// The variable `name` of the module at `mod_base` with a type, at
/// `address`: LLVM Flang's module variable (CodeView's `S_GDATA32`,
/// `ncells`) at its public symbol's (`_QMgridEncells`), which keeps two
/// modules' variables of one name apart
pub fn dataAt(self: *Engine, a: Allocator, mod_base: u64, name: []const u8, address: u64) !?Variable {
    for (try self.globalsNamed(a, mod_base, name)) |v| if (v.address == address and v.type_index != 0) return v;
    return null;
}

/// The global symbols of the module at `mod_base` whose names match
/// `mask` (dbghelp's, with `*`): variables with their types, and public
/// symbols without
pub fn globalsNamed(self: *Engine, a: Allocator, mod_base: u64, mask: []const u8) ![]Variable {
    var ctx: Collect = .{ .a = a, .engine = self };
    _ = SymEnumSymbols(self.process, mod_base, try a.dupeSentinel(u8, mask, 0), &Collect.onSymbol, &ctx);
    if (ctx.failed) return error.OutOfMemory;
    return ctx.out.items;
}

/// The symbol at an address exactly (`grid!QMgridEXdtXtagged`)
pub fn symbolAt(self: *Engine, a: Allocator, address: u64) ?[]const u8 {
    var name: [512:0]u16 = undefined;
    var len: u32 = 0;
    var displacement: u64 = 0;
    if (!succeeded(self.symbols.GetNameByOffsetWide(address, &name, name.len, &len, &displacement)) or displacement != 0 or len < 2) return null;
    return std.unicode.utf16LeToUtf8Alloc(a, name[0 .. len - 1]) catch null;
}

/// dbghelp's structure of a derived type, by its name: `tagged`, which
/// LLVM Flang's CodeView calls by its scope (`MAIN::tagged`,
/// `grid::point`); the one with members, not its forward declaration
pub fn typeNamed(self: *Engine, a: Allocator, mod_base: u64, name: []const u8) !?u32 {
    var ctx: Collect = .{ .a = a, .engine = self };
    _ = SymEnumTypesByName(self.process, mod_base, try a.printSentinel("*::{s}", .{name}, 0), &Collect.onSymbol, &ctx);
    _ = SymEnumTypesByName(self.process, mod_base, try a.dupeSentinel(u8, name, 0), &Collect.onSymbol, &ctx);
    if (ctx.failed) return error.OutOfMemory;
    for (ctx.out.items) |t| {
        if ((self.typeInfo(u32, mod_base, t.type_index, .childrencount) orelse 0) > 0) return t.type_index;
    }
    return null;
}

/// dbghelp's answer about a type (`u32` and `u64` ones)
pub fn typeInfo(self: *Engine, comptime T: type, mod_base: u64, type_index: u32, q: TypeQuery) ?T {
    var v: T = 0;
    return if (SymGetTypeInfo(self.process, mod_base, type_index, @backingInt(q), @ptrCast(&v)) != 0) v else null;
}

pub fn typeName(self: *Engine, a: Allocator, mod_base: u64, type_index: u32) ?[]const u8 {
    var name: ?[*:0]u16 = null;
    if (SymGetTypeInfo(self.process, mod_base, type_index, @backingInt(TypeQuery.symname), @ptrCast(&name)) == 0) return null;
    const n = name orelse return null;
    const s = n[0..std.mem.findSentinel(u16, 0, n)];
    return std.unicode.utf16LeToUtf8Alloc(a, s) catch null;
}

pub const Member = struct { name: []const u8, offset: u32, type_index: u32 };

/// The members of a structure (a derived type), from dbghelp
pub fn members(self: *Engine, a: Allocator, mod_base: u64, type_index: u32) ![]Member {
    const n = self.typeInfo(u32, mod_base, type_index, .childrencount) orelse return &.{};
    if (n == 0) return &.{};
    // TI_FINDCHILDREN_PARAMS: Count, Start, then the ids
    const params = try a.alignedAlloc(u32, .@"4", n + 2);
    params[0] = n;
    params[1] = 0;
    if (SymGetTypeInfo(self.process, mod_base, type_index, @backingInt(TypeQuery.findchildren), @ptrCast(params.ptr)) == 0) return &.{};
    var out: std.ArrayList(Member) = .empty;
    for (params[2..]) |child| {
        const tag = self.typeInfo(u32, mod_base, child, .symtag) orelse continue;
        if (tag == @backingInt(SymTag.base_class)) {
            // the parent of an extended type: its component of its type's name
            const t = self.typeInfo(u32, mod_base, child, .type) orelse continue;
            const full = self.typeName(a, mod_base, t) orelse continue;
            try out.append(a, .{
                .name = if (std.mem.findLast(u8, full, "::")) |i| full[i + 2 ..] else full,
                .offset = self.typeInfo(u32, mod_base, child, .offset) orelse 0,
                .type_index = t,
            });
            continue;
        }
        if (tag != @backingInt(SymTag.data)) continue;
        try out.append(a, .{
            .name = self.typeName(a, mod_base, child) orelse continue,
            .offset = self.typeInfo(u32, mod_base, child, .offset) orelse 0,
            .type_index = self.typeInfo(u32, mod_base, child, .type) orelse continue,
        });
    }
    return out.items;
}

/// A C name as dbghelp gives it, with the engine's options (SYMOPT_UNDNAME):
/// without its leading `_` (`_QQmain` -> `QQmain`)
pub fn withoutUnderscore(name: []const u8) []const u8 {
    return if (name.len > 1 and name[0] == '_') name[1..] else name;
}
