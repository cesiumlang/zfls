//! The Debugger Engine of Windows (`dbgeng.dll` of System32, which every
//! Windows 10 and later has), for `zfls dap`: programs with Microsoft's
//! debug information (PDB), as Intel's ifx and LLVM Flang make them on
//! Windows. The engine runs the program, stops it at breakpoints of source
//! lines, steps by lines and lists the stack; dbghelp (which the engine
//! loads) gives every variable of a frame with its place, whatever its type
//! (the engine's own typed view leaves out Intel's Fortran types), and the
//! program's memory is read here. All calls but `interrupt` must come from
//! the thread that made the engine.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32 = @import("win32");
const dbg = win32.system.diagnostics.debug;
const HRESULT = win32.zig.HRESULT;
const GUID = win32.zig.Guid;

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetExitCodeProcess(process: usize, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(h: usize) callconv(.winapi) i32;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

const DebugCreateFn = *const fn (iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

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
extern "dbghelp" fn SymFromName(h: usize, name: [*:0]const u8, info: *SymbolInfo) callconv(.winapi) i32;

const SYMFLAG_REGISTER = 0x8;
const SYMFLAG_REGREL = 0x10;
const SYMFLAG_PARAMETER = 0x40;
const SYMFLAG_LOCAL = 0x80;

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

const DEBUG_ONLY_THIS_PROCESS: u32 = 0x2;
const CREATE_NEW_CONSOLE: u32 = 0x10;
const CREATE_NO_WINDOW: u32 = 0x08000000;
const DEBUG_ENGOPT_INITIAL_BREAK: u32 = 0x20;
const DEBUG_ENGOPT_FINAL_BREAK: u32 = 0x40;
const DEBUG_ANY_ID: u32 = 0xffffffff;
const DEBUG_BREAKPOINT_CODE: u32 = 0;
const DEBUG_BREAKPOINT_ENABLED: u32 = 4;
const DEBUG_BREAKPOINT_ONE_SHOT: u32 = 0x10;
const DEBUG_STATUS_GO: u32 = 1;

pub const Error = error{ Engine, NoDbgeng, OutOfMemory };

/// The HRESULT of the engine's last failed call, for messages
pub var last_failure: u32 = 0;
/// What it was doing
pub var last_step: []const u8 = "";

fn ok(hr: HRESULT) Error!void {
    if (@as(i32, @bitCast(hr)) < 0) {
        last_failure = @bitCast(hr);
        return error.Engine;
    }
}

fn succeeded(hr: HRESULT) bool {
    return @as(i32, @bitCast(hr)) >= 0;
}

pub const Breakpoint = struct {
    id: u32,
    /// Its address, when the line has code of a loaded module
    offset: ?u64,
};

pub const Thread = struct {
    /// The engine's id
    id: u32,
    /// Windows's
    system_id: u32,
};

pub const Frame = struct {
    name: []const u8,
    file: ?[]const u8,
    line: u32,
    instruction: u64,
    frame_offset: u64,
    stack_offset: u64,
};

/// A variable of a frame, or a static one, where it is
pub const Variable = struct {
    name: []const u8,
    /// Its address in the program
    address: u64,
    size: u32,
    type_index: u32,
    mod_base: u64,
    parameter: bool,
};

pub const Stop = union(enum) {
    /// Still running when the wait ended
    running,
    breakpoint: struct { id: u32, thread: u32 },
    step: u32,
    exception: struct { code: u32, thread: u32, description: []const u8 },
    pause: u32,
    exited: u32,
};

pub const Engine = struct {
    client: *dbg.IDebugClient5,
    control: *dbg.IDebugControl4,
    symbols: *dbg.IDebugSymbols3,
    system: *dbg.IDebugSystemObjects4,
    registers: *dbg.IDebugRegisters2,
    data: *dbg.IDebugDataSpaces4,
    /// The process's handle, which dbghelp knows it by
    process: usize = 0,
    /// A handle of zfls's own to the process, for its exit code (the
    /// engine's is closed by then)
    own_handle: usize = 0,
    /// Waiting for a step to end, rather than a breakpoint
    stepping: bool = false,
    interrupted: std.atomic.Value(bool) = .init(false),

    pub fn init() !Engine {
        const lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("C:\\Windows\\System32\\dbgeng.dll")) orelse
            LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dbgeng.dll")) orelse return error.NoDbgeng;
        const create: DebugCreateFn = @ptrCast(@alignCast(GetProcAddress(lib, "DebugCreate") orelse return error.NoDbgeng));
        var raw: ?*anyopaque = null;
        try ok(create(dbg.IID_IDebugClient5, &raw));
        const client: *dbg.IDebugClient5 = @ptrCast(@alignCast(raw.?));
        return .{
            .client = client,
            .control = try query(client, dbg.IDebugControl4, dbg.IID_IDebugControl4),
            .symbols = try query(client, dbg.IDebugSymbols3, dbg.IID_IDebugSymbols3),
            .system = try query(client, dbg.IDebugSystemObjects4, dbg.IID_IDebugSystemObjects4),
            .registers = try query(client, dbg.IDebugRegisters2, dbg.IID_IDebugRegisters2),
            .data = try query(client, dbg.IDebugDataSpaces4, dbg.IID_IDebugDataSpaces4),
        };
    }

    fn query(client: *dbg.IDebugClient5, comptime T: type, iid: *const GUID) !*T {
        var raw: ?*anyopaque = null;
        try ok(client.vtable.base.QueryInterface(@ptrCast(client), iid, @ptrCast(&raw)));
        return @ptrCast(@alignCast(raw.?));
    }

    pub fn deinit(self: *Engine) void {
        if (self.own_handle != 0) _ = CloseHandle(self.own_handle);
        _ = self.client.EndSession(dbg.DEBUG_END_ACTIVE_TERMINATE);
        _ = self.data.vtable.base.Release(@ptrCast(self.data));
        _ = self.registers.vtable.base.Release(@ptrCast(self.registers));
        _ = self.system.vtable.base.Release(@ptrCast(self.system));
        _ = self.symbols.vtable.base.Release(@ptrCast(self.symbols));
        _ = self.control.vtable.base.Release(@ptrCast(self.control));
        _ = self.client.vtable.base.Release(@ptrCast(self.client));
    }

    fn setup(self: *Engine) !void {
        last_step = "options";
        try ok(self.control.AddEngineOptions(DEBUG_ENGOPT_INITIAL_BREAK | DEBUG_ENGOPT_FINAL_BREAK));
    }

    /// Starts `command_line` (the program and its arguments, quoted), in a
    /// console of its own unless not `window`, in `cwd`, with zfls's
    /// environment, and stops at its first instruction
    pub fn launch(self: *Engine, a: Allocator, command_line: []const u8, cwd: ?[]const u8, window: bool) !void {
        try self.setup();
        const cmd = try std.unicode.utf8ToUtf16LeAllocZ(a, command_line);
        const dir = if (cwd) |d| try std.unicode.utf8ToUtf16LeAllocZ(a, d) else null;
        var options: dbg.DEBUG_CREATE_PROCESS_OPTIONS = .{
            .CreateFlags = DEBUG_ONLY_THIS_PROCESS | if (window) CREATE_NEW_CONSOLE else CREATE_NO_WINDOW,
            .EngCreateFlags = dbg.DEBUG_ECREATE_PROCESS_DEFAULT,
            .VerifierFlags = 0,
            .Reserved = 0,
        };
        last_step = "create";
        try ok(self.client.CreateProcess2Wide(0, cmd.ptr, &options, @sizeOf(dbg.DEBUG_CREATE_PROCESS_OPTIONS), if (dir) |d| d.ptr else null, null));
        last_step = "wait";
        try ok(self.control.WaitForEvent(0, 0xffffffff));
        last_step = "process";
        try self.afterStart();
    }

    pub fn attach(self: *Engine, pid: u32) !void {
        try self.setup();
        try ok(self.client.AttachProcess(0, pid, dbg.DEBUG_ATTACH_DEFAULT));
        try ok(self.control.WaitForEvent(0, 0xffffffff));
        try self.afterStart();
    }

    fn afterStart(self: *Engine) !void {
        var pid: u32 = 0;
        if (succeeded(self.system.GetCurrentProcessSystemId(&pid))) self.own_handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        // steps by source lines (once there is a target)
        _ = self.control.SetCodeLevel(dbg.DEBUG_LEVEL_SOURCE);
        var h: u64 = 0;
        try ok(self.system.GetCurrentProcessHandle(&h));
        self.process = @intCast(h);
    }

    /// A breakpoint at `file`:`line` (deferred until its module loads)
    pub fn addBreakpoint(self: *Engine, a: Allocator, file: []const u8, line: u32, condition: ?[]const u8) !Breakpoint {
        _ = condition;
        var bp: ?*dbg.IDebugBreakpoint2 = null;
        try ok(self.control.AddBreakpoint2(DEBUG_BREAKPOINT_CODE, DEBUG_ANY_ID, &bp));
        const b = bp.?;
        const expr = try a.print("`{s}:{d}`", .{ file, line });
        const wexpr = try std.unicode.utf8ToUtf16LeAllocZ(a, expr);
        _ = b.SetOffsetExpressionWide(wexpr.ptr);
        try ok(b.AddFlags(DEBUG_BREAKPOINT_ENABLED));
        var id: u32 = 0;
        try ok(b.GetId(&id));
        var offset: u64 = 0;
        return .{ .id = id, .offset = if (succeeded(b.GetOffset(&offset))) offset else null };
    }

    /// A breakpoint at a symbol (`MAIN__`, a runtime's function), maybe once
    pub fn addSymbolBreakpoint(self: *Engine, a: Allocator, symbol: []const u8, one_shot: bool) !Breakpoint {
        var bp: ?*dbg.IDebugBreakpoint2 = null;
        try ok(self.control.AddBreakpoint2(DEBUG_BREAKPOINT_CODE, DEBUG_ANY_ID, &bp));
        const b = bp.?;
        const wexpr = try std.unicode.utf8ToUtf16LeAllocZ(a, symbol);
        _ = b.SetOffsetExpressionWide(wexpr.ptr);
        try ok(b.AddFlags(DEBUG_BREAKPOINT_ENABLED | if (one_shot) DEBUG_BREAKPOINT_ONE_SHOT else 0));
        var id: u32 = 0;
        try ok(b.GetId(&id));
        var offset: u64 = 0;
        return .{ .id = id, .offset = if (succeeded(b.GetOffset(&offset))) offset else null };
    }

    pub fn breakpointOffset(self: *Engine, id: u32) ?u64 {
        var bp: ?*dbg.IDebugBreakpoint2 = null;
        if (!succeeded(self.control.GetBreakpointById2(id, &bp))) return null;
        var offset: u64 = 0;
        return if (succeeded(bp.?.GetOffset(&offset))) offset else null;
    }

    pub fn removeBreakpoint(self: *Engine, id: u32) void {
        var bp: ?*dbg.IDebugBreakpoint2 = null;
        if (succeeded(self.control.GetBreakpointById2(id, &bp))) _ = self.control.RemoveBreakpoint2(bp);
    }

    pub const Resume = enum { go, over, into, out };

    pub fn resumeThread(self: *Engine, how: Resume, thread: ?u32) !void {
        if (thread) |t| _ = self.system.SetCurrentThreadId(t);
        self.stepping = how != .go;
        switch (how) {
            .go => try ok(self.control.SetExecutionStatus(DEBUG_STATUS_GO)),
            .over => try ok(self.control.SetExecutionStatus(dbg.DEBUG_STATUS_STEP_OVER)),
            .into => try ok(self.control.SetExecutionStatus(dbg.DEBUG_STATUS_STEP_INTO)),
            // the engine's "go up": to the caller's line
            .out => try ok(self.control.ExecuteWide(dbg.DEBUG_OUTCTL_IGNORE, std.unicode.utf8ToUtf16LeStringLiteral("gu"), dbg.DEBUG_EXECUTE_NOT_LOGGED)),
        }
    }

    /// Breaks into a running program; from any thread
    pub fn interrupt(self: *Engine) void {
        self.interrupted.store(true, .release);
        _ = self.control.SetInterrupt(dbg.DEBUG_INTERRUPT_ACTIVE);
    }

    /// Waits `ms` for the program to stop: why it did
    pub fn wait(self: *Engine, a: Allocator, ms: u32) !Stop {
        const hr: u32 = @bitCast(self.control.WaitForEvent(0, ms));
        if (hr == 1) return .running; // S_FALSE: the time is up
        var status: u32 = 0;
        _ = self.control.GetExecutionStatus(&status);
        var event: u32 = 0;
        var pid: u32 = 0;
        var tid: u32 = 0;
        var extra: [64]u8 align(8) = undefined;
        var extra_len: u32 = 0;
        var desc: [512:0]u8 = undefined;
        var desc_len: u32 = 0;
        _ = self.control.GetLastEventInformation(&event, &pid, &tid, &extra, extra.len, &extra_len, &desc, desc.len, &desc_len);
        if (status == dbg.DEBUG_STATUS_NO_DEBUGGEE or event == dbg.DEBUG_EVENT_EXIT_PROCESS) {
            var code: u32 = 0;
            if (event == dbg.DEBUG_EVENT_EXIT_PROCESS and extra_len >= 4) {
                code = std.mem.readInt(u32, extra[0..4], .little);
            } else if (self.own_handle != 0) {
                _ = GetExitCodeProcess(self.own_handle, &code);
            }
            return .{ .exited = code };
        }
        var thread: u32 = 0;
        _ = self.system.GetCurrentThreadId(&thread);
        if (self.interrupted.swap(false, .acq_rel)) return .{ .pause = thread };
        if (event == dbg.DEBUG_EVENT_BREAKPOINT and extra_len >= 4) {
            self.stepping = false;
            return .{ .breakpoint = .{ .id = std.mem.readInt(u32, extra[0..4], .little), .thread = thread } };
        }
        if (event == dbg.DEBUG_EVENT_EXCEPTION and extra_len >= 4) {
            const code = std.mem.readInt(u32, extra[0..4], .little);
            // the initial breakpoint, and a step's own trap, are not the program's
            if (code != 0x80000003 and code != 0x80000004 and code != 0x4000001f) {
                return .{ .exception = .{ .code = code, .thread = thread, .description = try a.dupe(u8, desc[0..@min(desc_len -| 1, desc.len)]) } };
            }
        }
        self.stepping = false;
        return .{ .step = thread };
    }

    pub fn threads(self: *Engine, a: Allocator) ![]Thread {
        var n: u32 = 0;
        try ok(self.system.GetNumberThreads(&n));
        const ids = try a.alloc(u32, n);
        const sys = try a.alloc(u32, n);
        try ok(self.system.GetThreadIdsByIndex(0, n, ids.ptr, sys.ptr));
        const out = try a.alloc(Thread, n);
        for (out, ids, sys) |*t, id, s| t.* = .{ .id = id, .system_id = s };
        return out;
    }

    pub fn stack(self: *Engine, a: Allocator, thread: u32, max: u32) ![]Frame {
        _ = self.system.SetCurrentThreadId(thread);
        const raw = try a.alloc(dbg.DEBUG_STACK_FRAME, max);
        var filled: u32 = 0;
        try ok(self.control.GetStackTrace(0, 0, 0, raw.ptr, max, &filled));
        const out = try a.alloc(Frame, filled);
        for (raw[0..filled], out) |f, *o| {
            o.* = .{ .name = "?", .file = null, .line = 0, .instruction = f.InstructionOffset, .frame_offset = f.FrameOffset, .stack_offset = f.StackOffset };
            var name: [512:0]u16 = undefined;
            var name_len: u32 = 0;
            if (succeeded(self.symbols.GetNameByOffsetWide(f.InstructionOffset, &name, name.len, &name_len, null))) {
                o.name = try std.unicode.utf16LeToUtf8Alloc(a, name[0..@min(name_len -| 1, name.len)]);
            }
            var file: [1024:0]u16 = undefined;
            var file_len: u32 = 0;
            var line: u32 = 0;
            if (succeeded(self.symbols.GetLineByOffsetWide(f.InstructionOffset, &line, &file, file.len, &file_len, null))) {
                o.file = try std.unicode.utf16LeToUtf8Alloc(a, file[0..@min(file_len -| 1, file.len)]);
                o.line = line;
            }
        }
        return out;
    }

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
                const base = c.engine.frameRegister(s.Register) orelse return 1;
                address = base +% s.Address;
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
        const name: [:0]const u8 = switch (cv) {
            334 => "rbp",
            335 => "rsp",
            else => return null,
        };
        var index: u32 = 0;
        if (!succeeded(self.registers.GetIndexByName(name.ptr, &index))) return null;
        var v: [1]dbg.DEBUG_VALUE = undefined;
        if (!succeeded(self.registers.GetValues2(dbg.DEBUG_REGSRC_FRAME, 1, @ptrCast(&index), 0, &v))) return null;
        return v[0].Anonymous.Anonymous.I64;
    }

    /// A global (a module variable: `GRID_mp_CELLS`, `_QMgridEcells`)
    pub fn global(self: *Engine, a: Allocator, name: []const u8) !?Variable {
        var buf: [@sizeOf(SymbolInfo) + 512]u8 align(8) = undefined;
        const info: *SymbolInfo = @ptrCast(&buf);
        info.SizeOfStruct = @sizeOf(SymbolInfo);
        info.MaxNameLen = 512;
        const z = try a.dupeSentinel(u8, name, 0);
        if (SymFromName(self.process, z.ptr, info) == 0) return null;
        return .{ .name = try a.dupe(u8, name), .address = info.Address, .size = info.Size, .type_index = info.TypeIndex, .mod_base = info.ModBase, .parameter = false };
    }

    /// Reads the program's memory: the bytes read
    pub fn read(self: *Engine, address: u64, buf: []u8) usize {
        var got: u32 = 0;
        if (!succeeded(self.data.ReadVirtual(address, buf.ptr, @intCast(buf.len), &got))) return 0;
        return got;
    }

    pub fn write(self: *Engine, address: u64, bytes: []const u8) bool {
        var put: u32 = 0;
        return succeeded(self.data.WriteVirtual(address, @constCast(bytes.ptr), @intCast(bytes.len), &put)) and put == bytes.len;
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
        const s = n[0..std.mem.indexOfSentinel(u16, 0, n)];
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
                    .name = if (std.mem.lastIndexOf(u8, full, "::")) |i| full[i + 2 ..] else full,
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

    pub fn terminate(self: *Engine) void {
        _ = self.client.TerminateProcesses();
    }

    pub fn detach(self: *Engine) void {
        _ = self.client.DetachProcesses();
    }
};

comptime {
    if (builtin.os.tag != .windows) @compileError("dbgeng is Windows's");
}
