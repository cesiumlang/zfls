//! The capabilities that `zfls dap` gives the client: Windows's Debugger
//! Engine's, at `initialize` or, when a launch or attach chooses the engine
//! after the client was given another debugger's (gdb's, lldb-dap's), in a
//! `capabilities` event that takes back what the engine lacks (#731).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const runtime_errors_filter = @import("breakpoints.zig").runtime_errors_filter;

const Filter = struct { filter: []const u8, label: []const u8, description: []const u8, default: bool };

/// The engine's capabilities
pub fn engine(s: *Session) struct {
    supportsConfigurationDoneRequest: bool = true,
    supportsTerminateRequest: bool = true,
    supportsEvaluateForHovers: bool = true,
    supportsDelayedStackTraceLoading: bool = false,
    supportsExceptionInfoRequest: bool = true,
    exceptionBreakpointFilters: [1]Filter,
} {
    return .{ .exceptionBreakpointFilters = .{.{
        .filter = runtime_errors_filter,
        .label = s.text.runtime_errors,
        .description = s.text.runtime_errors_description,
        .default = true,
    }} };
}

/// Keeps the capabilities the client was given by another debugger, for
/// `toEngine`
pub fn given(s: *Session, a: Allocator, body: Value) !void {
    if (s.given_capabilities.len > 0) s.gpa.free(s.given_capabilities);
    s.given_capabilities = try s.gpa.dupe(u8, try json.stringify(a, body));
}

/// The engine chosen: the `capabilities` event that gives the client the
/// engine's in place of those given (`given`), if any
pub fn toEngine(s: *Session, a: Allocator) !void {
    if (s.given_capabilities.len == 0) return;
    defer {
        s.gpa.free(s.given_capabilities);
        s.given_capabilities = "";
    }
    const before = json.parse(a, s.given_capabilities) catch return;
    s.event(a, "capabilities", .{ .capabilities = try changed(a, before, try json.from(a, engine(s))) });
}

/// `after`, with each of `before` that it has not taken back: the
/// capabilities `before` has true, false; the completion characters, none
fn changed(a: Allocator, before: Value, after: Value) !Value {
    var out: json.ObjectMap = .empty;
    if (before == .object) {
        var it = before.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            if (after.object.contains(key)) continue;
            if (kv.value_ptr.* == .bool and kv.value_ptr.*.bool) {
                try out.put(a, key, .{ .bool = false });
            } else if (kv.value_ptr.* == .array) try out.put(a, key, .{ .array = .init(a) });
        }
    }
    var it = after.object.iterator();
    while (it.next()) |kv| try out.put(a, kv.key_ptr.*, kv.value_ptr.*);
    return .{ .object = out };
}

test "the engine's capabilities over gdb's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // gdb 17.2's, in part, with zfls's filter
    const gdb = try json.parse(a, "{\"supportsConditionalBreakpoints\":true,\"supportsSetVariable\":true,\"supportsFunctionBreakpoints\":true,\"supportsTerminateRequest\":true,\"supportsDelayedStackTraceLoading\":true,\"supportsStepBack\":false,\"completionTriggerCharacters\":[\" \",\".\"],\"exceptionBreakpointFilters\":[{\"filter\":\"fortranRuntimeErrors\"},{\"filter\":\"throw\"}]}");
    const ours = try json.parse(a, "{\"supportsTerminateRequest\":true,\"supportsDelayedStackTraceLoading\":false,\"exceptionBreakpointFilters\":[{\"filter\":\"fortranRuntimeErrors\"}]}");
    const got = try json.stringify(a, try changed(a, gdb, ours));
    try std.testing.expectEqualStrings("{\"supportsConditionalBreakpoints\":false,\"supportsSetVariable\":false,\"supportsFunctionBreakpoints\":false,\"completionTriggerCharacters\":[],\"supportsTerminateRequest\":true,\"supportsDelayedStackTraceLoading\":false,\"exceptionBreakpointFilters\":[{\"filter\":\"fortranRuntimeErrors\"}]}", got);
}
