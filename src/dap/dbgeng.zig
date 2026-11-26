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

// dbghelp's lookups (dbgeng_symbols.zig)
const lookups = @import("dbgeng_symbols.zig");
const fsio = @import("../fsio.zig");
const code_lookups = @import("dbgeng_code.zig");
pub const SymbolInfo = lookups.SymbolInfo;
pub const TypeQuery = lookups.TypeQuery;
pub const SymTag = lookups.SymTag;
const withoutUnderscore = lookups.withoutUnderscore;

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
/// The errors of the last lookups of a line's address, by path and by name
pub var line_lookups: [2]u32 = .{ 0, 0 };
/// What it was doing
pub var last_step: []const u8 = "";

fn ok(hr: HRESULT) Error!void {
    if (@as(i32, @bitCast(hr)) < 0) {
        last_failure = @bitCast(hr);
        return error.Engine;
    }
}

pub fn succeeded(hr: HRESULT) bool {
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
    /// The engine's own line of the place, which steps go by: another than
    /// `line` where a line table has empty records before the statement's
    engine_line: u32 = 0,
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
    /// A break instruction of the program's own (`int 3`, `DebugBreak`),
    /// such as the Intel runtime's at a runtime error under a debugger
    trap: struct { thread: u32, description: []const u8 },
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
    pub fn launch(self: *Engine, a: Allocator, program: []const u8, command_line: []const u8, cwd: ?[]const u8, window: bool) !void {
        try fsio.check(program);
        try fsio.checkSpawn(&.{command_line}, cwd);
        try self.setup();
        // symbols from the program's own directory, where compilers put its
        // PDB: not a machine's symbol server (`srv*`), which then hides it
        if (std.Io.Dir.path.dirname(program)) |dir| {
            const wdir = try std.unicode.utf8ToUtf16LeAllocZ(a, dir);
            _ = self.symbols.SetSymbolPathWide(wdir.ptr);
        }
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
        // symbols from the program's own directory, where compilers put its
        // PDB: not a machine's symbol server (`srv*`), which then hides it
        var image: [1024:0]u16 = undefined;
        var image_len: u32 = 0;
        if (succeeded(self.symbols.GetModuleNameStringWide(dbg.DEBUG_MODNAME_IMAGE, 0, 0, &image, image.len, &image_len)) and image_len > 1) {
            var end: usize = image_len - 1;
            while (end > 0 and image[end - 1] != '\\' and image[end - 1] != '/') end -= 1;
            if (end > 1) {
                image[end - 1] = 0;
                _ = self.symbols.SetSymbolPathWide(image[0 .. end - 1 :0]);
            }
        }
        // the program's own symbols now (the engine loads them lazily), for
        // the breakpoints of its lines
        var name: [256:0]u16 = undefined;
        var len: u32 = 0;
        if (succeeded(self.symbols.GetModuleNameStringWide(dbg.DEBUG_MODNAME_MODULE, 0, 0, &name, name.len, &len)) and len > 1) {
            var cmd: [300:0]u16 = undefined;
            const prefix = std.unicode.utf8ToUtf16LeStringLiteral("/f ");
            @memcpy(cmd[0..prefix.len], prefix);
            const n = @min(len - 1, cmd.len - prefix.len - 1);
            @memcpy(cmd[prefix.len..][0..n], name[0..n]);
            cmd[prefix.len + n] = 0;
            _ = self.symbols.ReloadWide(&cmd);
        }
        var h: u64 = 0;
        try ok(self.system.GetCurrentProcessHandle(&h));
        self.process = @intCast(h);
    }

    /// A breakpoint at `file`:`line` (deferred until its module loads)
    pub fn addBreakpoint(self: *Engine, a: Allocator, file: []const u8, line: u32) !Breakpoint {
        var bp: ?*dbg.IDebugBreakpoint2 = null;
        try ok(self.control.AddBreakpoint2(DEBUG_BREAKPOINT_CODE, DEBUG_ANY_ID, &bp));
        const b = bp.?;
        var id: u32 = 0;
        try ok(b.GetId(&id));
        // the line's code, when its module's symbols are loaded: by the
        // symbols' own lookup, by the file's path, else its name (the
        // engine's expression of a source line does not match every path)
        if (try self.lineOffset(a, file, line)) |at| {
            try ok(b.SetOffset(at));
            try ok(b.AddFlags(DEBUG_BREAKPOINT_ENABLED));
            return .{ .id = id, .offset = at };
        }
        // else the engine's expression, deferred until the module loads
        const expr = try a.print("`{s}:{d}`", .{ file, line });
        const wexpr = try std.unicode.utf8ToUtf16LeAllocZ(a, expr);
        _ = b.SetOffsetExpressionWide(wexpr.ptr);
        try ok(b.AddFlags(DEBUG_BREAKPOINT_ENABLED));
        var offset: u64 = 0;
        if (!succeeded(b.GetOffset(&offset))) {
            // its module's symbols not loaded yet: once more after a reload
            _ = self.symbols.ReloadWide(std.unicode.utf8ToUtf16LeStringLiteral(""));
            _ = b.SetOffsetExpressionWide(wexpr.ptr);
            const hr = b.GetOffset(&offset);
            if (!succeeded(hr)) {
                last_failure = @bitCast(hr);
                return .{ .id = id, .offset = null };
            }
        }
        return .{ .id = id, .offset = offset };
    }

    /// A breakpoint at a symbol (`MAIN__`, `_QQmain`, a runtime's
    /// function), maybe once: at its address in the loaded modules (see
    /// `global`), else deferred until a module that has it loads
    pub fn addSymbolBreakpoint(self: *Engine, a: Allocator, symbol: []const u8, one_shot: bool) !Breakpoint {
        var bp: ?*dbg.IDebugBreakpoint2 = null;
        try ok(self.control.AddBreakpoint2(DEBUG_BREAKPOINT_CODE, DEBUG_ANY_ID, &bp));
        const b = bp.?;
        if (try self.global(a, symbol)) |g| {
            try ok(b.SetOffset(g.address));
        } else {
            // the engine's expression, without the `_` that dbghelp drops
            const wexpr = try std.unicode.utf8ToUtf16LeAllocZ(a, withoutUnderscore(symbol));
            _ = b.SetOffsetExpressionWide(wexpr.ptr);
        }
        try ok(b.AddFlags(DEBUG_BREAKPOINT_ENABLED | if (one_shot) DEBUG_BREAKPOINT_ONE_SHOT else 0));
        var id: u32 = 0;
        try ok(b.GetId(&id));
        var offset: u64 = 0;
        return .{ .id = id, .offset = if (succeeded(b.GetOffset(&offset))) offset else null };
    }

    /// Why breakpoints of the program's lines may not resolve: its module's
    /// symbols (0 none, 1 COFF, 2 CodeView, 3 PDB, 4 export, 5 deferred, 6
    /// SYM) and the symbol path
    pub fn symbolState(self: *Engine, a: Allocator) []const u8 {
        var params: [1]dbg.DEBUG_MODULE_PARAMETERS = undefined;
        const kind: i64 = if (succeeded(self.symbols.GetModuleParameters(1, null, 0, &params))) params[0].SymbolType else -1;
        var path: [1024:0]u16 = undefined;
        var len: u32 = 0;
        const sym_path = if (succeeded(self.symbols.GetSymbolPathWide(&path, path.len, &len)) and len > 0)
            std.unicode.utf16LeToUtf8Alloc(a, path[0 .. len - 1]) catch "?"
        else
            "";
        var file: [1024:0]u16 = undefined;
        var flen: u32 = 0;
        const pdb = if (succeeded(self.symbols.GetModuleNameStringWide(4, 0, 0, &file, file.len, &flen)) and flen > 0) // DEBUG_MODNAME_SYMBOL_FILE
            std.unicode.utf16LeToUtf8Alloc(a, file[0 .. flen - 1]) catch "?"
        else
            "";
        var module: [256:0]u16 = undefined;
        var mlen: u32 = 0;
        const mod_name = if (succeeded(self.symbols.GetModuleNameStringWide(dbg.DEBUG_MODNAME_MODULE, 0, 0, &module, module.len, &mlen)) and mlen > 0)
            std.unicode.utf16LeToUtf8Alloc(a, module[0 .. mlen - 1]) catch "?"
        else
            "(none)";
        // where the PDB puts the main program: its lines read, and its files' names
        var where: []const u8 = "no main";
        for ([_][]const u8{ "twice", "main", "MAIN__", "_QQmain" }) |m| {
            const full = a.print("{s}!{s}", .{ mod_name, m }) catch break;
            const wfull = std.unicode.utf8ToUtf16LeAllocZ(a, full) catch break;
            var off: u64 = 0;
            if (!succeeded(self.symbols.GetOffsetByNameWide(wfull.ptr, &off))) continue;
            var src: [1024:0]u16 = undefined;
            var slen: u32 = 0;
            var line: u32 = 0;
            const hr = self.symbols.GetLineByOffsetWide(off, &line, &src, src.len, &slen, null);
            where = if (succeeded(hr) and slen > 0)
                a.print("{s} at {s}:{d}", .{ m, std.unicode.utf16LeToUtf8Alloc(a, src[0 .. slen - 1]) catch "?", line }) catch ""
            else
                a.print("{s} at 0x{x}, no line (0x{x})", .{ m, off, @as(u32, @bitCast(hr)) }) catch "";
            break;
        }
        return a.print("module {s}: symbols {d}, file {s}, path {s}, {s}; by line 0x{x} 0x{x}", .{ mod_name, kind, pdb, sym_path, where, line_lookups[0], line_lookups[1] }) catch "";
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
            const description = try a.dupe(u8, desc[0..@min(desc_len -| 1, desc.len)]);
            // a break instruction: the program's own but in a step (the
            // initial breakpoint is the launch's, which waits for it)
            if (code == 0x80000003 and !self.stepping) return .{ .trap = .{ .thread = thread, .description = description } };
            // a step's own trap is not the program's
            if (code != 0x80000003 and code != 0x80000004 and code != 0x4000001f) {
                return .{ .exception = .{ .code = code, .thread = thread, .description = description } };
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
        for (raw[0..filled], out, 0..) |f, *o, i| {
            o.* = .{ .name = "?", .file = null, .line = 0, .instruction = f.InstructionOffset, .frame_offset = f.FrameOffset, .stack_offset = f.StackOffset };
            // a caller's place is its call, before the return address (the
            // next line's, or the next function's after a call that does
            // not return)
            const at = if (i > 0 and f.InstructionOffset > 0) f.InstructionOffset - 1 else f.InstructionOffset;
            var name: [512:0]u16 = undefined;
            var name_len: u32 = 0;
            if (succeeded(self.symbols.GetNameByOffsetWide(at, &name, name.len, &name_len, null))) {
                o.name = try std.unicode.utf16LeToUtf8Alloc(a, name[0..@min(name_len -| 1, name.len)]);
            }
            var file: [1024:0]u16 = undefined;
            var file_len: u32 = 0;
            var line: u32 = 0;
            if (succeeded(self.symbols.GetLineByOffsetWide(at, &line, &file, file.len, &file_len, null))) {
                o.file = try std.unicode.utf16LeToUtf8Alloc(a, file[0..@min(file_len -| 1, file.len)]);
                o.line = self.lastLineAt(at, &file) orelse line;
                o.engine_line = line;
            }
        }
        return out;
    }

    /// A register of the scope's frame (at a stop: of the thread stopped,
    /// its innermost frame), by its name (`rdx`)
    pub fn register(self: *Engine, name: [:0]const u8) ?u64 {
        var index: u32 = 0;
        if (!succeeded(self.registers.GetIndexByName(name.ptr, &index))) return null;
        var v: [1]dbg.DEBUG_VALUE = undefined;
        if (!succeeded(self.registers.GetValues2(dbg.DEBUG_REGSRC_FRAME, 1, @ptrCast(&index), 0, &v))) return null;
        return v[0].Anonymous.Anonymous.I64;
    }

    /// The base of the module of an address (a frame's instruction)
    pub fn moduleBase(self: *Engine, address: u64) ?u64 {
        var base: u64 = 0;
        return if (succeeded(self.symbols.GetModuleByOffset(address, 0, null, &base))) base else null;
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

    pub fn terminate(self: *Engine) void {
        _ = self.client.TerminateProcesses();
    }

    pub fn detach(self: *Engine) void {
        _ = self.client.DetachProcesses();
    }

    // dbghelp's lookups (dbgeng_symbols.zig)
    const lineOffset = lookups.lineOffset;
    const lastLineAt = lookups.lastLineAt;
    pub const variables = lookups.variables;
    pub const global = lookups.global;
    pub const dataAt = lookups.dataAt;
    pub const globalsNamed = lookups.globalsNamed;
    pub const symbolAt = lookups.symbolAt;
    pub const typeNamed = lookups.typeNamed;
    pub const definition = lookups.definition;
    pub const typeInfo = lookups.typeInfo;
    pub const typeName = lookups.typeName;
    pub const Member = lookups.Member;
    pub const members = lookups.members;

    // instructions, modules, sources (dbgeng_code.zig)
    pub const nearInstruction = code_lookups.nearInstruction;
    pub const disassemble = code_lookups.disassemble;
    pub const modules = code_lookups.modules;
    pub const sources = code_lookups.sources;
};

comptime {
    if (builtin.target.os.tag != .windows) @compileError("dbgeng is Windows's");
}
