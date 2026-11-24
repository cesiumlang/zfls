//! Minimal thread-safe logger writing to stderr and, optionally, a log file
//! (stand-in for the Python `logging` setup in fortls).

const std = @import("std");
const Io = std.Io;
const stdio = @import("stdio.zig");

const Logger = @This();

pub const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3, off = 4 };

io: Io,
/// Minimum level written to stderr
stderr_level: Level = .info,
/// Log file receiving everything at `file_level` and above
file: ?Io.File = null,
file_level: Level = .debug,
mutex: Io.Mutex = .init,

pub fn init(io: Io) Logger {
    return .{ .io = io };
}

pub fn deinit(self: *Logger) void {
    if (self.file) |f| f.close(self.io);
    self.file = null;
}

pub fn enabled(self: *const Logger, level: Level) bool {
    const lv = @backingInt(level);
    if (lv >= @backingInt(self.stderr_level)) return true;
    if (self.file != null and lv >= @backingInt(self.file_level)) return true;
    return false;
}

/// Start logging everything to `path`, a new file in the place of the old
/// one. Nothing is logged to one that is not a regular file (a link in the
/// workspace may point anywhere), and a link made in the meantime fails
/// the creation.
pub fn openFile(self: *Logger, io: Io, path: []const u8) void {
    const dir = Io.Dir.cwd();
    if (dir.statFile(io, path, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file) return;
        dir.deleteFile(io, path) catch return;
    } else |_| {}
    const f = dir.createFile(io, path, .{ .exclusive = true }) catch return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.file) |old| old.close(self.io);
    self.file = f;
}

fn write(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!self.enabled(level)) return;
    var buf: [4096]u8 = undefined;
    const tag = switch (level) {
        .debug => "DEBU",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERRO",
        .off => "",
    };
    var w: std.Io.Writer = .fixed(&buf);
    // a longer message is written in pieces
    const fits = if (w.print("[{s}] " ++ fmt ++ "\n", .{tag} ++ args)) true else |_| false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var targets: [2]?Io.File = .{ null, null };
    if (@backingInt(level) >= @backingInt(self.stderr_level)) targets[0] = stdio.stderr();
    if (self.file) |f| {
        if (@backingInt(level) >= @backingInt(self.file_level)) targets[1] = f;
    }
    for (targets) |target| {
        const f = target orelse continue;
        if (fits) {
            f.writeStreamingAll(self.io, w.buffered()) catch {};
        } else {
            var piece: [1024]u8 = undefined;
            var fw = f.writerStreaming(self.io, &piece);
            fw.interface.print("[{s}] " ++ fmt ++ "\n", .{tag} ++ args) catch {};
            fw.interface.flush() catch {};
        }
    }
}

pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.write(.debug, fmt, args);
}

pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.write(.info, fmt, args);
}

pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.write(.warn, fmt, args);
}

pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.write(.err, fmt, args);
}

test "a log file in place of a regular file; none through a link" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    try tmp.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "keep" });
    var log = Logger.init(io);
    defer log.deinit();
    // an old log is replaced
    try tmp.dir.writeFile(io, .{ .sub_path = "old.log", .data = "old text" });
    log.openFile(io, try std.Io.Dir.path.join(arena.allocator(), &.{ root, "old.log" }));
    try std.testing.expect(log.file != null);
    log.info("new", .{});
    log.deinit();
    log.file = null;
    var buf: [64]u8 = undefined;
    const text = try tmp.dir.readFile(io, "old.log", &buf);
    try std.testing.expect(std.mem.find(u8, text, "old text") == null and std.mem.find(u8, text, "new") != null);
    // a link: not followed, nothing written
    tmp.dir.symLink(io, "victim.txt", "link.log", .{}) catch return;
    log.openFile(io, try std.Io.Dir.path.join(arena.allocator(), &.{ root, "link.log" }));
    try std.testing.expect(log.file == null);
    const kept = try tmp.dir.readFile(io, "victim.txt", &buf);
    try std.testing.expectEqualStrings("keep", kept);
}
