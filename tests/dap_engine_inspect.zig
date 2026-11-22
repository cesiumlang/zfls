//! zfls dap on Windows's Debugger Engine, for tests/dap_windows.zig and
//! tests/dap_ifx.zig: `readMemory`, `disassemble`, `modules` and
//! `loadedSources` (#745), stopped in tests/dap/grid.f90's `work` (LLVM
//! Flang's and ifx's programs): an array's bytes by its `memoryReference`,
//! the instructions about the frame's `instructionPointerReference`, the
//! program among the modules, its source among the sources.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

pub const Program = struct {
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    work_line: i64,
};

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    const c = try Client.startEnv(io, gpa, p.argv, p.env);
    defer c.deinit();
    defer c.end(true);
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    for ([_][]const u8{ "supportsReadMemoryRequest", "supportsDisassembleRequest", "supportsModulesRequest", "supportsLoadedSourcesRequest" }) |name| {
        const v = get(caps, name) orelse Value{ .bool = false };
        try check(v == .bool and v.bool, "the engine's {s}", .{name});
    }
    _ = try c.request("launch", .{ .program = p.program, .cwd = p.dir, .sourceRoot = p.dir, .console = "internalConsole", .dbgeng = true });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = .{.{ .line = p.work_line }} });
    _ = try c.request("configurationDone", .{});
    const stopped = get(try c.event("stopped"), "body").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    const scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    const locals = items(try c.request("variables", .{ .variablesReference = int(scopes[0], "variablesReference").? }), "variables");

    // a = [6.0, 2.0, 3.0]: three REAL(4)'s bytes
    const av = for (locals) |v| {
        if (std.mem.eql(u8, str(v, "name") orelse "", "a")) break v;
    } else return check(false, "a among the locals", .{});
    const ref = str(av, "memoryReference") orelse return check(false, "a's memoryReference", .{});
    const mem = try c.request("readMemory", .{ .memoryReference = ref, .count = 12 });
    const data = str(mem, "data") orelse "";
    var bytes: [12]u8 = undefined;
    const n = std.base64.standard.Decoder.calcSizeForSlice(data) catch 0;
    if (n == 12) try std.base64.standard.Decoder.decode(&bytes, data);
    const floats = [3]f32{ @bitCast(std.mem.readInt(u32, bytes[0..4], .little)), @bitCast(std.mem.readInt(u32, bytes[4..8], .little)), @bitCast(std.mem.readInt(u32, bytes[8..12], .little)) };
    try check(n == 12 and floats[0] == 6 and floats[1] == 2 and floats[2] == 3, "readMemory of a ({s}): {d} bytes, {any}", .{ ref, n, floats });

    // five instructions before the frame's and five from it
    const ip = str(frames[0], "instructionPointerReference") orelse return check(false, "the frame's instructionPointerReference", .{});
    const dis = items(try c.request("disassemble", .{ .memoryReference = ip, .instructionOffset = -5, .instructionCount = 10 }), "instructions");
    const at = for (dis, 0..) |x, k| {
        if (std.mem.eql(u8, str(x, "address") orelse "", ip)) break k;
    } else null;
    const text: []const u8 = if (at) |k| str(dis[k], "instruction") orelse "" else "";
    try check(dis.len == 10 and at != null and text.len > 0, "disassemble about {s}: {d} instructions, the frame's the {?d}th ({s})", .{ ip, dis.len, at, text });

    const mods = items(try c.request("modules", .{}), "modules");
    const exe = std.Io.Dir.path.basename(p.program);
    const ours = for (mods) |m| {
        if (std.ascii.endsWithIgnoreCase(str(m, "path") orelse "", exe)) break true;
    } else false;
    try check(ours, "modules: {s} among {d}", .{ exe, mods.len });

    const sources = items(try c.request("loadedSources", .{}), "sources");
    const src = for (sources) |x| {
        if (std.ascii.endsWithIgnoreCase(str(x, "path") orelse "", "grid.f90")) break true;
    } else false;
    try check(src, "loadedSources: grid.f90 among {d}", .{sources.len});
}
