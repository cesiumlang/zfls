//! Breakpoints for `zfls dap`: of source lines (`setBreakpoints`), and on
//! the Fortran runtime's errors (`setExceptionBreakpoints`), with which of
//! them a stop is at.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const dbgeng = @import("dbgeng.zig");
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
        }
        gop.value_ptr.clearRetainingCapacity();
    } else gop.value_ptr.* = .empty;
    var out: std.ArrayList(Value) = .empty;
    for (json.items(json.get(args, "breakpoints"))) |b| {
        const line: u32 = @intCast(json.int(json.get(b, "line")) orelse continue);
        const bp = s.engine.addBreakpoint(a, file, line, json.str(json.get(b, "condition"))) catch {
            try out.append(a, try json.from(a, .{ .verified = false, .line = line }));
            continue;
        };
        try gop.value_ptr.append(s.gpa, bp.id);
        if (bp.offset != null) {
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
    for (s.error_breakpoints.items) |id| s.engine.removeBreakpoint(id);
    s.error_breakpoints.clearRetainingCapacity();
    if (wanted) for (runtime_error_functions) |f| {
        const bp = s.engine.addSymbolBreakpoint(a, f, false) catch continue;
        try s.error_breakpoints.append(s.gpa, bp.id);
    };
    s.respond(a, req, .{ .breakpoints = &[_]struct { verified: bool }{.{ .verified = true }} });
}

/// The exception filter of the Fortran runtime's errors
pub const runtime_errors_filter = "fortranRuntimeErrors";

/// What Intel's runtime calls on a severe error (an array bound exceeded
/// under /check:bounds, a failed allocation, an I/O error without iostat=)
/// and on ERROR STOP; LLVM Flang's
const runtime_error_functions = [_][]const u8{
    "for__issue_diagnostic",
    "for_error_stop",
    "for_error_stop8",
    "for_error_stop_int",
    "for_error_stop_int8",
    "_FortranAReportFatalUserError",
    "_FortranAStopStatement",
};

pub fn errorFunction(s: *Session, id: u32) ?[]const u8 {
    for (s.error_breakpoints.items, 0..) |x, i| if (x == id) return runtime_error_functions[i];
    return null;
}

pub fn isUserBreakpoint(s: *Session, id: u32) bool {
    var it = s.breakpoints.valueIterator();
    while (it.next()) |ids| for (ids.items) |x| if (x == id) return true;
    return false;
}
