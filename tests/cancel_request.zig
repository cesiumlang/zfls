//! `$/cancelRequest` against zfls over stdio (#740; `zig build test-cancel`,
//! part of `zig build test`). zfls handles one message at a time: a request
//! the client cancels while it waits behind another is answered with
//! RequestCancelled (-32800) and not worked on; one that is running when
//! its cancel comes runs to its end and is answered as usual.
//!
//! A formatting request keeps zfls busy: the formatter is this program
//! (`--blocking-formatter DIR`), which waits until the test lets it go.
//!
//!     cancel_request --zfls ZFLS

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

/// How long the formatter waits to be let go, and the test for it to start
const wait_ms = 60_000;

/// The formatter: says it started (`DIR/started`), waits for `DIR/go`,
/// then prints its input unchanged
fn blockingFormatter(io: Io, a: Allocator, dir: []const u8) !u8 {
    const cwd = Io.Dir.cwd();
    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buf);
    const input = try reader.interface.allocRemaining(a, .unlimited);
    try cwd.writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ dir, "started" }), .data = "" });
    if (!try waitForFile(io, try std.Io.Dir.path.join(a, &.{ dir, "go" }))) return 1;
    try Io.File.stdout().writeStreamingAll(io, input);
    return 0;
}

fn waitForFile(io: Io, path: []const u8) !bool {
    var waited: u32 = 0;
    while (waited < wait_ms) : (waited += 20) {
        if (Io.Dir.cwd().access(io, path, .{})) |_| return true else |_| {}
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return false;
}

/// The error code of a response, null for a result
fn errorCode(v: Value) ?i64 {
    const e = v.object.get("error") orelse return null;
    const code = e.object.get("code") orelse return null;
    return if (code == .integer) code.integer else null;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len == 3 and std.mem.eql(u8, argv[1], "--blocking-formatter")) return blockingFormatter(io, a, argv[2]);
    if (argv.len != 3 or !std.mem.eql(u8, argv[1], "--zfls")) {
        std.debug.print("usage: cancel_request --zfls ZFLS\n", .{});
        return 2;
    }
    const self_exe = try std.process.executablePathAlloc(io, a);
    const tmp = try Io.Dir.cwd().realPathFileAlloc(io, try lsp.tempDir(io, a, init.environ_map, "zfls_cancel_"), a);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const source = try std.Io.Dir.path.join(a, &.{ tmp, "a.f90" });
    const text = "program p\nx = 1\nend program p\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = text });
    const uri = try zfls.paths.pathToUri(a, source);

    const c = try lsp.Client.start(io, init.gpa, &.{ argv[2], "--disable_index_cache" }, null);
    defer c.deinit();
    errdefer c.kill();
    _ = try c.request("initialize", .{
        .rootUri = try zfls.paths.pathToUri(a, tmp),
        .rootPath = tmp,
        .capabilities = struct {}{},
        .initializationOptions = .{
            .formatter = "custom",
            .formatter_path = self_exe,
            .formatter_args = &[_][]const u8{ "--blocking-formatter", tmp },
        },
    });
    try c.send("initialized", struct {}{}, null);
    try c.send("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "fortran", .version = 1, .text = text } }, null);

    const doc = .{ .textDocument = .{ .uri = uri } };
    // running: the formatting, canceled once the formatter has started
    try c.send("textDocument/formatting", .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } }, 1);
    if (!try waitForFile(io, try std.Io.Dir.path.join(a, &.{ tmp, "started" }))) {
        std.debug.print("FAIL: the formatter did not start\n", .{});
        return 1;
    }
    try c.send("$/cancelRequest", .{ .id = 1 }, null);
    // waiting behind it: 2, canceled, and 3, not
    try c.send("textDocument/documentSymbol", doc, 2);
    try c.send("$/cancelRequest", .{ .id = 2 }, null);
    try c.send("textDocument/documentSymbol", doc, 3);
    // time for zfls's reader to take them all in
    try io.sleep(.fromMilliseconds(500), .awake);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ tmp, "go" }), .data = "" });

    var failures: usize = 0;
    // answered in order: once 3 is, so are 1 and 2 (the last answer of each)
    const third = try c.response(3);
    const first = try c.response(1);
    const second = try c.response(2);
    if (errorCode(first)) |code| {
        std.debug.print("FAIL: the running request was answered with error {d}, not its result\n", .{code});
        failures += 1;
    }
    if (errorCode(second) != -32800) {
        std.debug.print("FAIL: the canceled request waiting was not answered with RequestCancelled (-32800): {s}\n", .{try std.json.Stringify.valueAlloc(a, second, .{})});
        failures += 1;
    }
    if (errorCode(third)) |code| {
        std.debug.print("FAIL: the request waiting that was not canceled was answered with error {d}\n", .{code});
        failures += 1;
    }
    const term = try c.close();
    if (term != .exited or term.exited != 0) {
        std.debug.print("FAIL: zfls ended with {s}\n", .{try lsp.termText(a, term)});
        failures += 1;
    }
    if (failures > 0) return 1;
    std.debug.print("$/cancelRequest: a running request answered, a waiting one canceled\n", .{});
    return 0;
}
