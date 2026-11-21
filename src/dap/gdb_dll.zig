//! The runtime-error breakpoints of `zfls dap`'s gdb backend in gfortran's
//! runtime DLL on Windows (`libgfortran-5.dll`), for a program that links
//! it rather than `-static-libgfortran`: MSYS2's gdb reads no symbols of
//! the DLL, so a breakpoint on `_gfortran_runtime_error` by name lands in
//! the program's import thunk only, and the errors the runtime raises
//! inside itself (`RANDOM_SEED`, `MATMUL`, I/O) do not stop. gdb's Python
//! (gdb_dll.py) reads the DLL's export table when gdb loads it and sets
//! internal breakpoints at those functions' addresses, whose functions it
//! keeps for a stop there (`functionOf`); the program's thunks get none,
//! so that a call through one does not stop twice.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const sysinfo = @import("builtin");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");
const gdb_entry = @import("gdb_entry.zig");
const runtime_errors = @import("runtime_errors.zig");

const script = @embedFile("gdb_dll.py");

/// gfortran's runtime DLL, as a program that links it names it
const dll = "libgfortran-5.dll";

/// The runtime's functions that the DLL's breakpoints are on
pub fn isDllFunction(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "_gfortran_");
}

/// At `launch` on Windows: when the program links gfortran's DLL, gdb's
/// Python that sets the DLL's breakpoints once it is loaded
pub fn atLaunch(s: *Session, a: Allocator, program: ?[]const u8, cwd: ?[]const u8) !void {
    s.g.gfortran_dll = false;
    if (sysinfo.target.os.tag != .windows or s.g.lldb) return;
    const p = program orelse return;
    const path = if (cwd) |c| (if (std.Io.Dir.path.isAbsolute(p)) p else try std.Io.Dir.path.join(a, &.{ c, p })) else p;
    if (!gdb_entry.programHas(s.io, path, dll)) return;
    s.g.gfortran_dll = true;
    const r = try gdb.request(s, a, "evaluate", .{ .expression = try python(a, s.g.runtime_errors), .context = "repl" });
    if (!gdb.isSuccess(r)) s.log.warn("zfls dap: no breakpoints in {s}: {s}", .{ dll, json.str(json.get(r, "message")) orelse "?" });
}

/// gdb's command that runs gdb_dll.py, with the functions and their
/// conditions (`runtime_errors.gdb_breakpoints`), the breakpoints enabled
/// when `on` (the filter of runtime errors)
pub fn python(a: Allocator, on: bool) ![]const u8 {
    var want: std.ArrayList(u8) = .empty;
    try want.append(a, '{');
    for (runtime_errors.gdb_breakpoints) |b| {
        if (!isDllFunction(b.name)) continue;
        if (want.items.len > 1) try want.appendSlice(a, ", ");
        try want.print(a, "{f}: ", .{std.json.fmt(b.name, .{})});
        if (b.condition) |c| try want.print(a, "{f}", .{std.json.fmt(c, .{})}) else try want.appendSlice(a, "None");
    }
    try want.append(a, '}');
    var text = try std.mem.replaceOwned(u8, a, script, "ZFLS_WANT", want.items);
    if (!on) text = try std.mem.replaceOwned(u8, a, text, "zfls_dll_on = True", "zfls_dll_on = False");
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(text.len));
    _ = encoder.encode(encoded, text);
    return a.print("python exec(__import__('base64').b64decode('{s}').decode())", .{encoded});
}

/// The filter of runtime errors turned on or off: the DLL's breakpoints too
pub fn enable(s: *Session, a: Allocator, on: bool) !void {
    if (!s.g.gfortran_dll) return;
    _ = try gdb.request(s, a, "evaluate", .{ .expression = if (on) "python zfls_dll_enable(True)" else "python zfls_dll_enable(False)", .context = "repl" });
}

/// The runtime's function of breakpoint `id` when it is one of the DLL's:
/// gdb's internal breakpoints have numbers below 0, which gdb_dll.py keeps
/// with their functions (`zfls_dll_name`), asked once each
pub fn functionOf(s: *Session, a: Allocator, id: i64) ?[]const u8 {
    if (!s.g.gfortran_dll or id >= 0) return null;
    if (s.g.dll_breakpoints.get(id)) |f| return f;
    const r = gdb.request(s, a, "evaluate", .{ .expression = a.print("python zfls_dll_name({d})", .{id}) catch return null, .context = "repl" }) catch return null;
    const f = nameResult(json.str(json.path(r, &.{ "body", "result" })) orelse return null) orelse return null;
    s.g.dll_breakpoints.put(s.gpa, id, f) catch {};
    return f;
}

/// The function that `zfls_dll_name` printed (`zfls-dll _gfortran_runtime_error`),
/// as the runtime's own name, which outlives the output; null for none
pub fn nameResult(output: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "zfls-dll ")) continue;
        const f = runtime_errors.find(std.mem.trim(u8, line["zfls-dll ".len..], " ")) orelse return null;
        return f.name;
    }
    return null;
}

test "the DLL breakpoint's function, as gdb_dll.py prints it" {
    try std.testing.expectEqualStrings("_gfortran_runtime_error", nameResult("zfls-dll _gfortran_runtime_error\n").?);
    try std.testing.expect(nameResult("zfls-dll \n") == null);
    try std.testing.expect(nameResult("zfls-dll printf\r\n") == null);
    try std.testing.expect(nameResult("Traceback (most recent call last):\n") == null);
}

test "gdb's Python of the DLL's breakpoints: gfortran's functions, with their conditions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try python(a, true);
    try std.testing.expect(std.mem.startsWith(u8, cmd, "python exec(__import__('base64').b64decode('"));
    const encoded = cmd["python exec(__import__('base64').b64decode('".len..std.mem.findLast(u8, cmd, "')").?];
    const decoder = std.base64.standard.Decoder;
    const text = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(text, encoded);
    try std.testing.expect(std.mem.find(u8, text, "\"_gfortran_runtime_error\": None") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"_FortranAStopStatement\"") == null);
    try std.testing.expect(std.mem.find(u8, text, "ZFLS_WANT") == null);
}
