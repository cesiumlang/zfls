//! Minimal thread-safe logger writing to stderr and, optionally, a log file
//! (stand-in for the Python `logging` setup in fortls).

const std = @import("std");
const Io = std.Io;

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

/// Start logging everything to `path` (truncating it)
pub fn openFile(self: *Logger, io: Io, path: []const u8) void {
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
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
    if (@backingInt(level) >= @backingInt(self.stderr_level)) targets[0] = Io.File.stderr();
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
