//! Breakpoints for `zfls dap`: of source lines (`setBreakpoints`), and on
//! the Fortran runtime's errors (`setExceptionBreakpoints`), with which of
//! them a stop is at.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const dbgeng = @import("dbgeng.zig");
const runtime_errors = @import("runtime_errors.zig");
const engine_conditions = @import("engine_conditions.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;

/// `setBreakpoints`: a source file's, in place of those it had
pub fn set(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const file = json.str(json.path(args, &.{ "source", "path" })) orelse return s.fail(a, req, "no source");
    const key = try std.ascii.allocLowerString(s.gpa, file);
    const gop = try s.breakpoints.getOrPut(s.gpa, key);
    if (gop.found_existing) {
        s.gpa.free(key);
        for (gop.value_ptr.items) |id| {
            s.engine.removeBreakpoint(id);
            _ = s.unverified.remove(id);
            engine_conditions.forget(s, id);
        }
        gop.value_ptr.clearRetainingCapacity();
    } else gop.value_ptr.* = .empty;
    var out: std.ArrayList(Value) = .empty;
    for (json.items(json.get(args, "breakpoints"))) |b| {
        const line: u32 = @intCast(json.int(json.get(b, "line")) orelse continue);
        const bp = s.engine.addBreakpoint(a, file, line) catch {
            try out.append(a, try json.from(a, .{ .verified = false, .line = line }));
            continue;
        };
        try gop.value_ptr.append(s.gpa, bp.id);
        if (try engine_conditions.keep(s, a, bp.id, b)) |why| {
            try out.append(a, try json.from(a, .{ .id = bp.id, .verified = false, .line = line, .message = why }));
        } else if (bp.offset != null) {
            try out.append(a, try json.from(a, .{ .id = bp.id, .verified = true, .line = line }));
        } else {
            try s.unverified.put(s.gpa, bp.id, line);
            try out.append(a, try json.from(a, .{ .id = bp.id, .verified = false, .line = line, .message = try a.print("not resolved yet (0x{x}; {s})", .{ dbgeng.last_failure, s.engine.symbolState(a) }) }));
        }
    }
    s.respond(a, req, .{ .breakpoints = out.items });
}

/// `setExceptionBreakpoints`: on the Fortran runtime's errors, or none
pub fn setExceptions(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    var wanted = false;
    for (json.items(json.get(args, "filters"))) |f| {
        if (std.mem.eql(u8, json.str(f) orelse "", runtime_errors_filter)) wanted = true;
    }
    for (s.error_breakpoints.items) |b| s.engine.removeBreakpoint(b.id);
    s.error_breakpoints.clearRetainingCapacity();
    if (wanted) try runtime_errors.addEach(s.gpa, &s.error_breakpoints, &runtime_errors.engine_functions, &SymbolBreakpoints{ .s = s, .a = a });
    s.respond(a, req, .{ .breakpoints = &[_]struct { verified: bool }{.{ .verified = true }} });
}

/// The engine's breakpoints on functions, for `runtime_errors.addEach`
const SymbolBreakpoints = struct {
    s: *Session,
    a: Allocator,

    pub fn add(self: *const SymbolBreakpoints, name: []const u8) !u32 {
        return (try self.s.engine.addSymbolBreakpoint(self.a, name, false)).id;
    }
};

/// The exception filter of the Fortran runtime's errors
pub const runtime_errors_filter = "fortranRuntimeErrors";

/// The function of the runtime's errors of an id of `error_breakpoints`
pub fn errorFunction(s: *Session, id: u32) ?runtime_errors.Function {
    return runtime_errors.functionOf(s.error_breakpoints.items, id);
}

/// Whether a stop at a function of both STOP and ERROR STOP (LLVM Flang's)
/// is at a plain STOP, where the program goes on: its argument of ERROR
/// STOP is false
pub fn isPlainStop(s: *Session, f: runtime_errors.Function) bool {
    const i = f.error_stop_argument orelse return false;
    const r = runtime_errors.argumentRegister(builtin.target.cpu.arch, builtin.target.os.tag, i) orelse return false;
    const value = s.engine.register(r.engine) orelse return false;
    return value & 0xff == 0;
}

pub fn isUserBreakpoint(s: *Session, id: u32) bool {
    if (std.mem.findScalar(u32, s.function_breakpoints.items, id) != null) return true;
    var it = s.breakpoints.valueIterator();
    while (it.next()) |ids| for (ids.items) |x| if (x == id) return true;
    return false;
}
