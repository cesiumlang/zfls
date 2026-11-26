//! The engine's `readMemory`, `disassemble`, `modules` and `loadedSources`
//! (#745): the program's memory from a variable's `memoryReference` (its
//! address) or a frame's `instructionPointerReference`, its instructions
//! (before the address too, as the client's disassembly asks), its loaded
//! modules, and the sources of its modules' line tables that exist.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const paths = @import("../paths.zig");
const Value = json.Value;

const Session = @import("session.zig").Session;

/// A memory reference's address (`0x1400a2000`)
pub fn address(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    const digits = if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) t[2..] else t;
    return std.fmt.parseInt(u64, digits, 16) catch null;
}

pub fn reference(a: Allocator, at: u64) ![]const u8 {
    return a.print("0x{x}", .{at});
}

/// The most read at once
const max_read = 1 << 20;

pub fn readMemory(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const base = address(json.str(json.get(args, "memoryReference")) orelse "") orelse return s.fail(a, req, "no memoryReference");
    const offset = json.int(json.get(args, "offset")) orelse 0;
    const count: usize = @intCast(std.math.clamp(json.int(json.get(args, "count")) orelse 0, 0, max_read));
    const start: u64 = @bitCast(@as(i64, @bitCast(base)) +% offset);
    const buf = try a.alloc(u8, count);
    // what is read up to the first page that is not
    var got: usize = 0;
    while (got < count) {
        const abs = start + got;
        const page_end = (abs | 0xfff) +% 1;
        const n = s.engine.read(abs, buf[got..][0..@intCast(@min(count - got, page_end -% abs))]);
        if (n == 0) break;
        got += n;
    }
    const encoder = std.base64.standard.Encoder;
    const data = try a.alloc(u8, encoder.calcSize(got));
    _ = encoder.encode(data, buf[0..got]);
    s.respond(a, req, .{ .address = try reference(a, start), .unreadableBytes = count - got, .data = data });
}

pub fn disassemble(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const base = address(json.str(json.get(args, "memoryReference")) orelse "") orelse return s.fail(a, req, "no memoryReference");
    const offset = json.int(json.get(args, "offset")) orelse 0;
    const skip = json.int(json.get(args, "instructionOffset")) orelse 0;
    const count: usize = @intCast(std.math.clamp(json.int(json.get(args, "instructionCount")) orelse 0, 0, 10000));
    var at: u64 = @bitCast(@as(i64, @bitCast(base)) +% offset);
    if (skip != 0) at = s.engine.nearInstruction(at, @intCast(std.math.clamp(skip, -100000, 100000))) orelse at;
    var out: std.ArrayList(Value) = .empty;
    while (out.items.len < count) {
        const got = (try s.engine.disassemble(a, at)) orelse {
            // no code here: the protocol's invalid instruction
            try out.append(a, try json.from(a, .{ .address = try reference(a, at), .instruction = "??", .presentationHint = "invalid" }));
            at += 1;
            continue;
        };
        const i, const next = got;
        try out.append(a, try json.from(a, .{ .address = try reference(a, i.address), .instructionBytes = i.bytes, .instruction = i.text }));
        at = next;
    }
    s.respond(a, req, .{ .instructions = out.items });
}

pub fn modules(s: *Session, a: Allocator, req: Value) !void {
    var out: std.ArrayList(Value) = .empty;
    for (try s.engine.modules(a)) |m| {
        try out.append(a, try json.from(a, .{
            .id = try reference(a, m.base),
            .name = m.name,
            .path = m.path,
            .addressRange = try a.print("0x{x}-0x{x}", .{ m.base, m.base + m.size }),
        }));
    }
    s.respond(a, req, .{ .modules = out.items, .totalModules = out.items.len });
}

/// The sources of the modules' line tables that are files here, once each
pub fn loadedSources(s: *Session, a: Allocator, req: Value) !void {
    var out: std.ArrayList(Value) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try s.engine.modules(a)) |m| {
        for (try s.engine.sources(a, m.base)) |f| {
            const key = try std.ascii.allocLowerString(a, f);
            if (seen.contains(key) or !paths.isFile(s.io, f)) continue;
            try seen.put(a, key, {});
            try out.append(a, try json.from(a, .{ .name = std.Io.Dir.path.basename(f), .path = f }));
        }
    }
    s.respond(a, req, .{ .sources = out.items });
}

test address {
    try std.testing.expectEqual(@as(?u64, 0x1400a2000), address("0x1400a2000"));
    try std.testing.expectEqual(@as(?u64, null), address("zz"));
}
