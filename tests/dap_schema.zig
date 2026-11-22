//! The Debug Adapter Protocol's shapes of the messages that `zfls dap`
//! sends, for the tests' client (tests/dap_client.zig): each response's
//! and event's body, by the types of the protocol's JSON schema
//! (https://microsoft.github.io/debug-adapter-protocol/debugAdapterProtocol.json):
//! the fields they must have, and the types of those they have.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Kind = enum { string, int, number, bool, object, array };

const Field = struct {
    name: []const u8,
    kind: Kind,
    required: bool = false,
    /// An object's fields, or an array's elements' (objects)
    fields: []const Field = &.{},
    /// An array's elements, when not objects
    elements: ?Kind = null,
};

fn req(name: []const u8, kind: Kind) Field {
    return .{ .name = name, .kind = kind, .required = true };
}

fn opt(name: []const u8, kind: Kind) Field {
    return .{ .name = name, .kind = kind };
}

/// An array of objects of `fields`
fn list(name: []const u8, required: bool, fields: []const Field) Field {
    return .{ .name = name, .kind = .array, .required = required, .fields = fields };
}

/// An array of `kind`
fn listOf(name: []const u8, required: bool, kind: Kind) Field {
    return .{ .name = name, .kind = .array, .required = required, .elements = kind };
}

fn object(name: []const u8, required: bool, fields: []const Field) Field {
    return .{ .name = name, .kind = .object, .required = required, .fields = fields };
}

const source: []const Field = &.{ opt("name", .string), opt("path", .string), opt("sourceReference", .int), opt("presentationHint", .string) };

const breakpoint: []const Field = &.{ opt("id", .int), req("verified", .bool), opt("message", .string), object("source", false, source), opt("line", .int), opt("column", .int), opt("endLine", .int), opt("endColumn", .int), opt("instructionReference", .string), opt("offset", .int), opt("reason", .string) };

const variable_hint: Field = object("presentationHint", false, &.{ opt("kind", .string), listOf("attributes", false, .string), opt("visibility", .string), opt("lazy", .bool) });

const variable: []const Field = &.{ req("name", .string), req("value", .string), opt("type", .string), variable_hint, opt("evaluateName", .string), req("variablesReference", .int), opt("namedVariables", .int), opt("indexedVariables", .int), opt("memoryReference", .string) };

const filter: []const Field = &.{ req("filter", .string), req("label", .string), opt("description", .string), opt("default", .bool), opt("supportsCondition", .bool), opt("conditionDescription", .string) };

/// Capabilities: those of `supports...` are booleans (`capabilities`)
const capabilities: []const Field = &.{ list("exceptionBreakpointFilters", false, filter), listOf("completionTriggerCharacters", false, .string), listOf("additionalModuleColumns", false, .object), listOf("supportedChecksumAlgorithms", false, .string), listOf("breakpointModes", false, .object) };

const Shape = struct { []const u8, []const Field };

/// The responses' bodies by command (those of no body: none, or any)
const responses = [_]Shape{
    .{ "initialize", capabilities },
    .{ "setBreakpoints", &.{list("breakpoints", true, breakpoint)} },
    .{ "setFunctionBreakpoints", &.{list("breakpoints", true, breakpoint)} },
    .{ "setExceptionBreakpoints", &.{list("breakpoints", false, breakpoint)} },
    .{ "setInstructionBreakpoints", &.{list("breakpoints", true, breakpoint)} },
    .{ "setDataBreakpoints", &.{list("breakpoints", true, breakpoint)} },
    .{ "breakpointLocations", &.{list("breakpoints", true, &.{ req("line", .int), opt("column", .int), opt("endLine", .int), opt("endColumn", .int) })} },
    .{ "continue", &.{opt("allThreadsContinued", .bool)} },
    .{ "threads", &.{list("threads", true, &.{ req("id", .int), req("name", .string) })} },
    .{ "stackTrace", &.{ list("stackFrames", true, &.{ req("id", .int), req("name", .string), object("source", false, source), req("line", .int), req("column", .int), opt("endLine", .int), opt("endColumn", .int), opt("canRestart", .bool), opt("instructionPointerReference", .string), opt("presentationHint", .string) }), opt("totalFrames", .int) } },
    .{ "scopes", &.{list("scopes", true, &.{ req("name", .string), opt("presentationHint", .string), req("variablesReference", .int), opt("namedVariables", .int), opt("indexedVariables", .int), req("expensive", .bool), object("source", false, source), opt("line", .int) })} },
    .{ "variables", &.{list("variables", true, variable)} },
    .{ "setVariable", &.{ req("value", .string), opt("type", .string), opt("variablesReference", .int), opt("namedVariables", .int), opt("indexedVariables", .int), opt("memoryReference", .string) } },
    .{ "setExpression", &.{ req("value", .string), opt("type", .string), variable_hint, opt("variablesReference", .int), opt("namedVariables", .int), opt("indexedVariables", .int), opt("memoryReference", .string) } },
    .{ "evaluate", &.{ req("result", .string), opt("type", .string), variable_hint, req("variablesReference", .int), opt("namedVariables", .int), opt("indexedVariables", .int), opt("memoryReference", .string) } },
    .{ "completions", &.{list("targets", true, &.{ req("label", .string), opt("text", .string), opt("sortText", .string), opt("detail", .string), opt("type", .string), opt("start", .int), opt("length", .int), opt("selectionStart", .int), opt("selectionLength", .int) })} },
    .{ "exceptionInfo", &.{ req("exceptionId", .string), opt("description", .string), req("breakMode", .string), object("details", false, &.{}) } },
    .{ "loadedSources", &.{list("sources", true, source)} },
    .{ "modules", &.{ list("modules", true, &.{}), opt("totalModules", .int) } },
    .{ "source", &.{ req("content", .string), opt("mimeType", .string) } },
    .{ "readMemory", &.{ req("address", .string), opt("unreadableBytes", .int), opt("data", .string) } },
    .{ "writeMemory", &.{ opt("offset", .int), opt("bytesWritten", .int) } },
    .{ "disassemble", &.{list("instructions", true, &.{ req("address", .string), req("instruction", .string) })} },
};

/// The events' bodies by event
const events = [_]Shape{
    .{ "stopped", &.{ req("reason", .string), opt("description", .string), opt("threadId", .int), opt("preserveFocusHint", .bool), opt("text", .string), opt("allThreadsStopped", .bool), listOf("hitBreakpointIds", false, .int) } },
    .{ "continued", &.{ req("threadId", .int), opt("allThreadsContinued", .bool) } },
    .{ "exited", &.{req("exitCode", .int)} },
    .{ "thread", &.{ req("reason", .string), req("threadId", .int) } },
    .{ "output", &.{ opt("category", .string), req("output", .string), opt("group", .string), opt("variablesReference", .int), object("source", false, source), opt("line", .int), opt("column", .int) } },
    .{ "breakpoint", &.{ req("reason", .string), object("breakpoint", true, breakpoint) } },
    .{ "module", &.{ req("reason", .string), object("module", true, &.{req("name", .string)}) } },
    .{ "loadedSource", &.{ req("reason", .string), object("source", true, source) } },
    .{ "process", &.{ req("name", .string), opt("systemProcessId", .int), opt("isLocalProcess", .bool), opt("startMethod", .string), opt("pointerSize", .int) } },
    .{ "capabilities", &.{object("capabilities", true, capabilities)} },
    .{ "memory", &.{ req("memoryReference", .string), req("offset", .int), req("count", .int) } },
};

/// What is wrong with a message of the adapter by the protocol, or null;
/// `request` is the client's request that a response answers
pub fn violation(a: Allocator, msg: Value, request: ?Value) Allocator.Error!?[]const u8 {
    if (msg != .object) return "a message that is not an object";
    if (try wrong(a, "", msg, &.{ req("seq", .int), req("type", .string) })) |w| return w;
    const kind = msg.object.get("type").?.string;
    if (std.mem.eql(u8, kind, "response")) return response(a, msg, request);
    if (std.mem.eql(u8, kind, "event")) {
        if (try wrong(a, "", msg, &.{req("event", .string)})) |w| return w;
        const name = msg.object.get("event").?.string;
        const where = try a.print("the event {s}", .{name});
        const body = msg.object.get("body");
        const fields = shapeOf(&events, name) orelse return notObject(a, where, body);
        return wrongBody(a, where, body orelse return try a.print("{s}: no body", .{where}), fields);
    }
    if (std.mem.eql(u8, kind, "request")) return wrong(a, "a request", msg, &.{ req("command", .string), opt("arguments", .object) });
    return try a.print("a message of type {s}", .{kind});
}

fn response(a: Allocator, msg: Value, request: ?Value) !?[]const u8 {
    if (try wrong(a, "a response", msg, &.{ req("request_seq", .int), req("success", .bool), req("command", .string), opt("message", .string) })) |w| return w;
    const command = msg.object.get("command").?.string;
    if (request) |r| if (str(r, "command")) |c| if (!std.mem.eql(u8, c, command))
        return try a.print("the response to {s} says {s}", .{ c, command });
    const body = msg.object.get("body");
    if (!msg.object.get("success").?.bool) return notObject(a, command, body);
    const fields = shapeOf(&responses, command) orelse return notObject(a, command, body);
    const b = body orelse return if (hasRequired(fields)) try a.print("{s}: no body", .{command}) else null;
    if (try wrongBody(a, command, b, fields)) |w| return w;
    // one breakpoint for each asked, in their order
    if (std.mem.eql(u8, command, "setBreakpoints") or std.mem.eql(u8, command, "setFunctionBreakpoints")) if (request) |r| {
        const args = if (r == .object) r.object.get("arguments") orelse Value.null else Value.null;
        const asked = arrayLen(args, "breakpoints") orelse arrayLen(args, "lines") orelse 0;
        const given = arrayLen(b, "breakpoints").?;
        if (asked != given) return try a.print("{s}: {d} breakpoints for {d} asked", .{ command, given, asked });
    };
    return null;
}

/// A body that must be an object, if any
fn notObject(a: Allocator, where: []const u8, body: ?Value) !?[]const u8 {
    const b = body orelse return null;
    return if (b == .object or b == .null) null else try a.print("{s}: a body that is not an object", .{where});
}

fn str(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn arrayLen(v: Value, key: []const u8) ?usize {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .array) x.array.items.len else null;
}

fn shapeOf(shapes: []const Shape, name: []const u8) ?[]const Field {
    for (shapes) |sh| if (std.mem.eql(u8, sh[0], name)) return sh[1];
    return null;
}

fn hasRequired(fields: []const Field) bool {
    for (fields) |f| if (f.required) return true;
    return false;
}

fn wrongBody(a: Allocator, where: []const u8, body: Value, fields: []const Field) !?[]const u8 {
    if (body != .object) return try a.print("{s}: a body that is not an object", .{where});
    return wrong(a, where, body, fields);
}

/// What is wrong with the object `v` by `fields`, or null
fn wrong(a: Allocator, where: []const u8, v: Value, fields: []const Field) Allocator.Error!?[]const u8 {
    // capabilities: those named `supports...` are booleans
    if (fields.ptr == capabilities.ptr) {
        var it = v.object.iterator();
        while (it.next()) |kv| if (std.mem.startsWith(u8, kv.key_ptr.*, "supports") and kv.value_ptr.* != .bool)
            return try a.print("{s}.{s}: {s}, not bool", .{ where, kv.key_ptr.*, kindOf(kv.value_ptr.*) });
    }
    for (fields) |f| {
        const x = v.object.get(f.name) orelse {
            if (f.required) return try a.print("{s}: no {s}", .{ where, f.name });
            continue;
        };
        const at = try a.print("{s}.{s}", .{ where, f.name });
        if (!isKind(x, f.kind)) return try a.print("{s}: {s}, not {s}", .{ at, kindOf(x), @tagName(f.kind) });
        switch (f.kind) {
            .object => if (try wrong(a, at, x, f.fields)) |w| return w,
            .array => for (x.array.items, 0..) |e, i| {
                const want: Kind = f.elements orelse .object;
                const at_i = try a.print("{s}[{d}]", .{ at, i });
                if (!isKind(e, want)) return try a.print("{s}: {s}, not {s}", .{ at_i, kindOf(e), @tagName(want) });
                if (want == .object) if (try wrong(a, at_i, e, f.fields)) |w| return w;
            },
            else => {},
        }
    }
    return null;
}

fn isKind(v: Value, kind: Kind) bool {
    return switch (kind) {
        .string => v == .string,
        .int => v == .integer,
        .number => v == .integer or v == .float,
        .bool => v == .bool,
        .object => v == .object,
        .array => v == .array,
    };
}

fn kindOf(v: Value) []const u8 {
    return switch (v) {
        .integer => "int",
        .float, .number_string => "number",
        else => @tagName(v),
    };
}

fn expectViolation(want: ?[]const u8, text: []const u8, request: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = try std.json.parseFromSliceLeaky(Value, a, text, .{});
    const r = if (request) |t| try std.json.parseFromSliceLeaky(Value, a, t, .{}) else null;
    const got = try violation(a, msg, r);
    if (want) |w| {
        try std.testing.expectEqualStrings(w, got orelse "(none)");
    } else if (got) |g| {
        std.debug.print("unexpected: {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
}

test "the protocol's shapes" {
    const ok_vars = "{\"seq\":3,\"type\":\"response\",\"request_seq\":2,\"command\":\"variables\",\"success\":true,\"body\":{\"variables\":[]}}";
    // an empty string for an array (#726)
    try expectViolation("variables.variables: string, not array", "{\"seq\":3,\"type\":\"response\",\"request_seq\":2,\"command\":\"variables\",\"success\":true,\"body\":{\"variables\":\"\"}}", null);
    try expectViolation(null, ok_vars, null);
    try expectViolation("the response to scopes says variables", ok_vars, "{\"seq\":2,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":1}}");
    try expectViolation("setFunctionBreakpoints: 0 breakpoints for 1 asked", "{\"seq\":3,\"type\":\"response\",\"request_seq\":2,\"command\":\"setFunctionBreakpoints\",\"success\":true,\"body\":{\"breakpoints\":[]}}", "{\"seq\":2,\"type\":\"request\",\"command\":\"setFunctionBreakpoints\",\"arguments\":{\"breakpoints\":[{\"name\":\"f\"}]}}");
    try expectViolation("setBreakpoints.breakpoints[0]: no verified", "{\"seq\":3,\"type\":\"response\",\"request_seq\":2,\"command\":\"setBreakpoints\",\"success\":true,\"body\":{\"breakpoints\":[{\"line\":3}]}}", null);
    try expectViolation("initialize.supportsSetVariable: int, not bool", "{\"seq\":1,\"type\":\"response\",\"request_seq\":1,\"command\":\"initialize\",\"success\":true,\"body\":{\"supportsSetVariable\":1}}", null);
    try expectViolation("the event stopped: no reason", "{\"seq\":9,\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"threadId\":1}}", null);
    try expectViolation("the event capabilities.capabilities.exceptionBreakpointFilters[0]: no label", "{\"seq\":9,\"type\":\"event\",\"event\":\"capabilities\",\"body\":{\"capabilities\":{\"exceptionBreakpointFilters\":[{\"filter\":\"x\"}]}}}", null);
    try expectViolation(null, "{\"seq\":9,\"type\":\"response\",\"request_seq\":4,\"command\":\"evaluate\",\"success\":false,\"message\":\"no symbol\"}", null);
    try expectViolation("evaluate: no body", "{\"seq\":9,\"type\":\"response\",\"request_seq\":4,\"command\":\"evaluate\",\"success\":true}", null);
    try expectViolation(null, "{\"seq\":9,\"type\":\"response\",\"request_seq\":4,\"command\":\"next\",\"success\":true}", null);
}
