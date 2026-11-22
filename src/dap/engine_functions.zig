//! The engine's function breakpoints (#745): a Fortran procedure by its
//! name (`work`, `grid::work`; the main program by its name or `main`), at
//! the symbol that Intel or LLVM Flang gives it (`GRID_mp_WORK`,
//! `_QMgridPwork`; `WORK`, `_QPwork`; `MAIN__`, `_QQmain`), the module
//! found in zfls's index of the sources; else a symbol as given. Their
//! conditions, hit conditions and log messages are a source breakpoint's
//! (engine_conditions.zig).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const Session = @import("session.zig").Session;
const engine_conditions = @import("engine_conditions.zig");

/// `setFunctionBreakpoints`: in place of those set before
pub fn set(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    for (s.function_breakpoints.items) |id| {
        s.engine.removeBreakpoint(id);
        engine_conditions.forget(s, id);
    }
    s.function_breakpoints.clearRetainingCapacity();
    var out: std.ArrayList(Value) = .empty;
    for (json.items(json.get(args, "breakpoints"))) |b| {
        const name = std.mem.trim(u8, json.str(json.get(b, "name")) orelse "", " ");
        const id = for (try symbols(s, a, name)) |sym| {
            const bp = s.engine.addSymbolBreakpoint(a, sym, false) catch continue;
            if (bp.offset != null) break bp.id;
            s.engine.removeBreakpoint(bp.id);
        } else null;
        const got = id orelse {
            try out.append(a, try json.from(a, .{ .verified = false, .message = try a.print("no procedure {s} in the program", .{name}) }));
            continue;
        };
        try s.function_breakpoints.append(s.gpa, got);
        if (try engine_conditions.keep(s, a, got, b)) |why| {
            try out.append(a, try json.from(a, .{ .id = got, .verified = false, .message = why }));
        } else try out.append(a, try json.from(a, .{ .id = got, .verified = true }));
    }
    s.respond(a, req, .{ .breakpoints = out.items });
}

/// The symbols a procedure's name may be, most likely first
fn symbols(s: *Session, a: Allocator, given: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (given.len == 0) return out.items;
    const sep = std.mem.find(u8, given, "::");
    const name = if (sep) |i| given[i + 2 ..] else given;
    var modules: std.ArrayList([]const u8) = .empty;
    if (sep) |i| try modules.append(a, given[0..i]) else try modules.appendSlice(a, try modulesOf(s, a, name));
    for (modules.items) |m| try out.appendSlice(a, &.{ try intel(a, m, name), try flang(a, m, name) });
    if (sep == null) {
        try out.appendSlice(a, &.{ try std.ascii.allocUpperString(a, name), try a.print("_QP{s}", .{try std.ascii.allocLowerString(a, name)}) });
        if (isMain(s, a, name)) try out.appendSlice(a, &.{ "MAIN__", "_QQmain" });
        try out.append(a, name);
    }
    return out.items;
}

/// `GRID_mp_WORK`
fn intel(a: Allocator, module: []const u8, name: []const u8) ![]const u8 {
    return a.print("{s}_mp_{s}", .{ try std.ascii.allocUpperString(a, module), try std.ascii.allocUpperString(a, name) });
}

/// `_QMgridPwork`
fn flang(a: Allocator, module: []const u8, name: []const u8) ![]const u8 {
    return a.print("_QM{s}P{s}", .{ try std.ascii.allocLowerString(a, module), try std.ascii.allocLowerString(a, name) });
}

/// The modules whose procedure `name` is, by zfls's index
fn modulesOf(s: *Session, a: Allocator, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const srv = s.server orelse return out.items;
    const found = srv.dispatchPublic(a, "workspace/symbol", try json.from(a, .{ .query = name })) catch return out.items;
    for (json.items(found)) |sym| {
        // functions and subroutines (12), methods (6)
        const kind = json.int(json.get(sym, "kind")) orelse 0;
        if (kind != 12 and kind != 6) continue;
        if (!std.ascii.eqlIgnoreCase(json.str(json.get(sym, "name")) orelse "", name)) continue;
        const container = json.str(json.get(sym, "containerName")) orelse continue;
        if (container.len > 0) try out.append(a, container);
    }
    return out.items;
}

/// Whether `name` is the main program's (`main` too)
fn isMain(s: *Session, a: Allocator, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "main")) return true;
    const srv = s.server orelse return false;
    const found = srv.dispatchPublic(a, "workspace/symbol", json.from(a, .{ .query = name }) catch return false) catch return false;
    for (json.items(found)) |sym| {
        // modules (2) are not; a program is a module's kind in LSP, without a container
        if (std.ascii.eqlIgnoreCase(json.str(json.get(sym, "name")) orelse "", name) and json.str(json.get(sym, "containerName")) == null and json.int(json.get(sym, "kind")) == 2) return true;
    }
    return false;
}

test "a procedure's symbols" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("GRID_mp_WORK", try intel(a, "grid", "work"));
    try std.testing.expectEqualStrings("_QMgridPwork", try flang(a, "Grid", "WORK"));
}
