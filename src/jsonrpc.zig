//! JSON-RPC 2.0 message framing over byte streams (port of `fortls.jsonrpc`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");

pub const ReadError = error{ ProtocolError, OutOfMemory, ReadFailed };

/// Read one message body; returns null at end of stream
pub fn readMessage(r: *Io.Reader, a: Allocator) ReadError!?[]u8 {
    var content_length: ?usize = null;
    var first = true;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => {
                if (first) return null;
                return error.ProtocolError;
            },
            error.StreamTooLong => return error.ProtocolError,
            error.ReadFailed => return error.ReadFailed,
        };
        if (first and line.len < 2) return error.ProtocolError;
        first = false;
        const trimmed = str.rstrip(line);
        if (trimmed.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = str.strip(trimmed[0..colon]);
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, str.strip(trimmed[colon + 1 ..]), 10) catch return error.ProtocolError;
        }
    }
    const len = content_length orelse return error.ProtocolError;
    return r.readAllocAll(a, len) catch |e| switch (e) {
        error.EndOfStream => error.ProtocolError,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// Frame a JSON body with the LSP headers
pub fn frame(a: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n{s}", .{ body.len, body });
}

test "read framed message" {
    const a = std.testing.allocator;
    var r: Io.Reader = .fixed("Content-Length: 2\r\nContent-Type: x\r\n\r\n{}Content-Length: 3\r\n\r\n[1]");
    const m1 = (try readMessage(&r, a)).?;
    defer a.free(m1);
    try std.testing.expectEqualStrings("{}", m1);
    const m2 = (try readMessage(&r, a)).?;
    defer a.free(m2);
    try std.testing.expectEqualStrings("[1]", m2);
    try std.testing.expect((try readMessage(&r, a)) == null);
}
