//! What the compiler oracles (gfortran_oracle.zig, flang_oracle.zig) share:
//! running a program, finding one on the PATH, and the files to check.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp_client");

pub fn findOnPath(io: Io, a: Allocator, env: *const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const path = env.get("PATH") orelse env.get("Path") orelse return null;
    const exe = if (builtin.target.os.tag == .windows) try a.print("{s}.exe", .{name}) else name;
    var dirs = std.mem.tokenizeScalar(u8, path, if (builtin.target.os.tag == .windows) ';' else ':');
    while (dirs.next()) |d| {
        const candidate = try std.Io.Dir.path.join(a, &.{ d, exe });
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
    }
    return null;
}

/// `env` with the directory of `exe` first on its PATH, so that on Windows
/// a compiler loads the DLLs it was built with rather than other copies
/// (Git for Windows' bash puts its own first)
pub fn envWithDirOf(io: Io, a: Allocator, env: *const std.process.Environ.Map, exe: []const u8) !std.process.Environ.Map {
    var out = try env.clone(a);
    const full = if (std.Io.Dir.path.dirname(exe) == null) (try findOnPath(io, a, env, exe)) orelse exe else exe;
    if (std.Io.Dir.path.dirname(full)) |dir| {
        const key = if (env.get("PATH") == null and env.get("Path") != null) "Path" else "PATH";
        const old = env.get(key) orelse "";
        try out.put(key, try a.print("{s}{c}{s}", .{ dir, if (builtin.target.os.tag == .windows) @as(u8, ';') else ':', old }));
    }
    return out;
}

pub const Run = struct { stdout: []const u8, stderr: []const u8, ok: bool, code: []const u8 };

pub fn run(io: Io, a: Allocator, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) !Run {
    const r = try std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .create_no_window = true,
    });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .ok = r.term.success(), .code = try lsp.termText(a, r.term) };
}

/// The line of a compiler's error output that says why it failed: the
/// first that mentions an error, else the first, else the exit status
pub fn failure(r: Run) []const u8 {
    var lines = std.mem.splitScalar(u8, r.stderr, '\n');
    var first_line: ?[]const u8 = null;
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r\t");
        if (t.len == 0) continue;
        if (first_line == null) first_line = t;
        if (std.mem.find(u8, t, "rror") != null) return t;
    }
    return first_line orelse r.code;
}

pub fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The files of `paths`: a file as it is, the files of a directory, searched
/// recursively, whose names `wanted` accepts, sorted
pub fn collect(io: Io, a: Allocator, paths: []const []const u8, wanted: *const fn ([]const u8) bool) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (Io.Dir.cwd().openDir(io, p, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(io);
            var found: std.ArrayList([]const u8) = .empty;
            var walker = try dir.walk(a);
            defer walker.deinit();
            while (try walker.next(io)) |e| {
                if (e.kind != .file or !wanted(e.basename)) continue;
                try found.append(a, try std.Io.Dir.path.join(a, &.{ p, e.path }));
            }
            std.mem.sort([]const u8, found.items, {}, lessThan);
            try files.appendSlice(a, found.items);
        } else |_| try files.append(a, p);
    }
    return files.items;
}
