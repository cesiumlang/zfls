//! Windows's Debugger Engine's instructions, modules and sources, for
//! `zfls dap`'s `disassemble`, `modules` and `loadedSources` (#745): the
//! instructions from an address (also before it), the program's modules,
//! and the source files of a module's line tables.
//! Part of `Engine` (dbgeng.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const win32 = @import("win32");
const dbg = win32.system.diagnostics.debug;
const dbgeng = @import("dbgeng.zig");
const Engine = dbgeng.Engine;
const succeeded = dbgeng.succeeded;

pub const Instruction = struct {
    address: u64,
    /// The bytes, in hex (`4883ec28`)
    bytes: []const u8,
    /// The mnemonic and operands (`sub rsp,28h`)
    text: []const u8,
};

/// The address `delta` instructions from `address` (before it, when
/// negative); null where there is no code
pub fn nearInstruction(self: *Engine, address: u64, delta: i32) ?u64 {
    var near: u64 = 0;
    return if (succeeded(self.control.GetNearInstruction(address, delta, &near))) near else null;
}

/// The instruction at `address`, and the next one's address; null where
/// there is none
pub fn disassemble(self: *Engine, a: Allocator, address: u64) !?struct { Instruction, u64 } {
    var buf: [512:0]u8 = undefined;
    var size: u32 = 0;
    var next: u64 = 0;
    if (!succeeded(self.control.Disassemble(address, dbg.DEBUG_DISASM_EFFECTIVE_ADDRESS, &buf, buf.len, &size, &next)) or next <= address) return null;
    const line = std.mem.trimEnd(u8, buf[0..size -| 1], "\r\n ");
    return .{ try parseLine(a, address, line), next };
}

/// The engine's line of an instruction (`00007ff6`12341000 4883ec28
/// sub     rsp,28h`): its bytes and text
fn parseLine(a: Allocator, address: u64, line: []const u8) !Instruction {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next(); // the address
    const bytes = it.next() orelse "";
    const rest = std.mem.trim(u8, it.rest(), " \t");
    // one blank between the mnemonic and its operands
    const gap = std.mem.findAny(u8, rest, " \t");
    const text = if (gap) |g| try a.print("{s} {s}", .{ rest[0..g], std.mem.trimStart(u8, rest[g..], " \t") }) else try a.dupe(u8, rest);
    return .{ .address = address, .bytes = try a.dupe(u8, bytes), .text = text };
}

pub const Module = struct { name: []const u8, path: []const u8, base: u64, size: u32 };

/// The program's modules, loaded
pub fn modules(self: *Engine, a: Allocator) ![]Module {
    var loaded: u32 = 0;
    var unloaded: u32 = 0;
    if (!succeeded(self.symbols.GetNumberModules(&loaded, &unloaded))) return &.{};
    var out: std.ArrayList(Module) = .empty;
    for (0..loaded) |i| {
        var base: u64 = 0;
        if (!succeeded(self.symbols.GetModuleByIndex(@intCast(i), &base))) continue;
        var params: [1]dbg.DEBUG_MODULE_PARAMETERS = undefined;
        const size: u32 = if (succeeded(self.symbols.GetModuleParameters(1, @ptrCast(&base), 0, &params))) params[0].Size else 0;
        try out.append(a, .{
            .name = try nameOf(self, a, dbg.DEBUG_MODNAME_MODULE, @intCast(i)),
            .path = try nameOf(self, a, dbg.DEBUG_MODNAME_IMAGE, @intCast(i)),
            .base = base,
            .size = size,
        });
    }
    return out.items;
}

fn nameOf(self: *Engine, a: Allocator, which: u32, index: u32) ![]const u8 {
    var buf: [1024:0]u16 = undefined;
    var len: u32 = 0;
    if (!succeeded(self.symbols.GetModuleNameStringWide(which, index, 0, &buf, buf.len, &len)) or len < 1) return "";
    return std.unicode.utf16LeToUtf8Alloc(a, buf[0 .. len - 1]);
}

const SourceFileW = extern struct { mod_base: u64, file_name: [*:0]const u16 };
extern "dbghelp" fn SymEnumSourceFilesW(h: usize, base: u64, mask: ?[*:0]const u16, cb: *const fn (*const SourceFileW, ?*anyopaque) callconv(.winapi) i32, ctx: ?*anyopaque) callconv(.winapi) i32;

/// The source files of the line tables of the module at `base`
pub fn sources(self: *Engine, a: Allocator, base: u64) ![]const []const u8 {
    const Ctx = struct {
        a: Allocator,
        out: std.ArrayList([]const u8) = .empty,
        failed: bool = false,

        fn onFile(f: *const SourceFileW, ctx: ?*anyopaque) callconv(.winapi) i32 {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            const name = std.unicode.utf16LeToUtf8Alloc(c.a, std.mem.span(f.file_name)) catch {
                c.failed = true;
                return 0;
            };
            c.out.append(c.a, name) catch {
                c.failed = true;
                return 0;
            };
            return 1;
        }
    };
    var ctx: Ctx = .{ .a = a };
    _ = SymEnumSourceFilesW(self.process, base, null, &Ctx.onFile, &ctx);
    if (ctx.failed) return error.OutOfMemory;
    return ctx.out.items;
}

test parseLine {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const i = try parseLine(arena.allocator(), 0x140001000, "00000001`40001000 4883ec28        sub     rsp,28h");
    try std.testing.expectEqualStrings("4883ec28", i.bytes);
    try std.testing.expectEqualStrings("sub rsp,28h", i.text);
}
