const std = @import("std");
const Io = std.Io;

const root = @import("root");
const json = @import("json.zig");
const patterns = @import("patterns.zig");
const paths = @import("paths.zig");
const settings = @import("settings.zig");
const jsonrpc = @import("jsonrpc.zig");
const server_mod = @import("server.zig");
const debug = @import("debug.zig");
const version_info = @import("version.zig");
const Logger = @import("logger.zig");

const app_name = if (@hasDecl(root, "app_name")) root.app_name else "zfls";
const version = if (@hasDecl(root, "version")) root.version else @import("build_options").version;

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    s: settings.Settings,
    exit_code: u8 = 0,
};

fn stdoutSend(ctx: ?*anyopaque, body: []const u8) void {
    const io: *const Io = @ptrCast(@alignCast(ctx.?));
    var buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n", .{body.len}) catch return;
    const out = Io.File.stdout();
    out.writeStreamingAll(io.*, header) catch return;
    out.writeStreamingAll(io.*, body) catch return;
}

fn runServer(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    var log = Logger.init(io);
    defer log.deinit();
    const server = server_mod.Server.create(gpa, io, ctx.s, &log) catch |e| {
        log.err("failed to start server: {s}", .{@errorName(e)});
        ctx.exit_code = 1;
        return;
    };
    defer server.destroy();
    var io_copy = io;
    server.sink = .{ .ctx = @ptrCast(&io_copy), .sendFn = stdoutSend };

    var read_buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &read_buf);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (server.running) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const body = jsonrpc.readMessage(&reader.interface, a) catch |e| {
            server.postMessage(a, std.fmt.allocPrint(a, "Unexpected error: {s}", .{@errorName(e)}) catch "Unexpected error", 1);
            break;
        } orelse break;
        const request = json.parse(a, body) catch {
            server.postMessage(a, "Unexpected error: invalid JSON message", 1);
            break;
        };
        if (log.enabled(.debug)) log.debug("RECV {s}", .{json.pretty(a, request) catch ""});
        server.handle(a, request);
        server.flushPostMessages(a);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    patterns.init();
    paths.init(io);

    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var args: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |arg| try args.append(arena, arg);

    version_info.reported = version_info.get(io, version);
    const parsed = try settings.parseArgs(arena, args.items, version_info.reported);
    const s = switch (parsed) {
        .run => |s| s,
        .exit_ok => |text| {
            try Io.File.stdout().writeStreamingAll(io, text);
            return;
        },
        .exit_err => |text| {
            try Io.File.stderr().writeStreamingAll(io, text);
            std.process.exit(2);
        },
    };

    if (s.debug_parser or s.debug_preproc or s.isDebugMode()) {
        const code = debug.run(gpa, io, s) catch |e| blk: {
            const msg = try std.fmt.allocPrint(arena, "ERROR: {s}\n", .{@errorName(e)});
            try Io.File.stdout().writeStreamingAll(io, msg);
            break :blk 255;
        };
        if (code != 0) std.process.exit(code);
        return;
    }

    var ctx: Ctx = .{ .gpa = gpa, .io = io, .s = s };
    // Run on a thread with a large stack: Fortran code can nest deeply and
    // name resolution is recursive.
    const th = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, runServer, .{&ctx});
    th.join();
    if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
}
