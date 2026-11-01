//! The index cache: the texts of the workspace's files in one file of
//! zfls's cache directory, each with its size and modification time, and
//! the AST zfls parsed from it. At initialization a file whose size and time
//! are those of its entry is read from there, not from its own file:
//! reading one file instead of thousands (each scanned by an antivirus on
//! Windows) is what makes a cold start of a large workspace slow. Its AST is
//! taken from there too when what parsing reads (the text, the
//! preprocessor's output, the options: `FortranFile.parseKey`) is what it
//! was, so that a start parses only the files that changed. After
//! initialization the cache is written again when a file or an AST was not
//! in it, or a file has gone.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("../paths.zig");
const parser = @import("../parser.zig");
const pp = @import("../preprocessor.zig");
const objects = @import("../objects.zig");
const serial = @import("../objects/serial.zig");
const FortranFile = parser.FortranFile;
const Ast = objects.Ast;

const srv = @import("../server.zig");
const Server = srv.Server;

/// The start of a cache file: the format, which a new one changes
const magic = "ZFLSIDX2";
/// A smaller workspace starts fast enough without a cache
const min_files = 200;
/// The caches of other workspaces not written for this long are deleted
const max_age_days = 60;

const Entry = struct {
    size: u64,
    mtime: i96,
    text: []const u8,
    /// `FortranFile.parseKey` of `ast`; `ast` is empty when there is none
    key: u64 = 0,
    ast: []const u8 = "",
};

/// What the next cache has for a file: its entry, with what is owned by
/// `gpa` rather than by the snapshot's `data`
const Next = struct {
    entry: Entry,
    own_path: bool = false,
    own_text: bool = false,
    own_ast: bool = false,
};

/// The cache read at initialization, and what the next one will have
pub const Snapshot = struct {
    /// The cache file's bytes (owned by `gpa`), which the entries point into
    data: []u8 = &.{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// The files read during initialization, under `mutex`
    mutex: Io.Mutex = .init,
    next: std.StringHashMapUnmanaged(Next) = .empty,
    /// Whether a text or an AST of `next` is not in `data`
    changed: bool = false,

    fn deinit(s: *Snapshot, gpa: Allocator) void {
        var it = s.next.iterator();
        while (it.next()) |kv| {
            const n = kv.value_ptr.*;
            if (n.own_path) gpa.free(kv.key_ptr.*);
            if (n.own_text) gpa.free(n.entry.text);
            if (n.own_ast) gpa.free(n.entry.ast);
        }
        s.next.deinit(gpa);
        s.entries.deinit(gpa);
        gpa.free(s.data);
    }
};

/// The cache file of the workspace: one per root, null without a cache
/// directory
fn cachePath(self: *Server, a: Allocator) !?[]const u8 {
    const base = paths.cacheDir() orelse return null;
    var h = std.hash.Wyhash.init(0);
    h.update(self.root_path);
    return try paths.join(a, &.{ base, "index", try std.fmt.allocPrint(a, "{x:0>16}.zfc", .{h.final()}) });
}

/// Reads the cache for initializing a workspace of `file_count` files (none
/// when it is off, missing or not readable)
pub fn begin(self: *Server, a: Allocator, file_count: usize) void {
    if (self.s.disable_index_cache or file_count < min_files) return;
    const snap = self.gpa.create(Snapshot) catch return;
    snap.* = .{};
    self.index = snap;
    const file = (cachePath(self, a) catch null) orelse return;
    snap.data = Io.Dir.cwd().readFileAlloc(self.io, file, self.gpa, .limited(1 << 34)) catch return;
    parse(self.gpa, snap) catch {
        self.log.info("index cache {s} is not readable; it will be written again", .{file});
        snap.entries.clearRetainingCapacity();
    };
}

const Reader = struct {
    data: []const u8,
    at: usize = 0,

    fn bytes(r: *Reader, n: usize) ![]const u8 {
        if (n > r.data.len - r.at) return error.Truncated;
        defer r.at += n;
        return r.data[r.at .. r.at + n];
    }

    fn int(r: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try r.bytes(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

/// The entries of `snap.data`: `magic`, a count, then for each file its
/// path, size, time, text, AST key and AST, little-endian
fn parse(gpa: Allocator, snap: *Snapshot) !void {
    var r: Reader = .{ .data = snap.data };
    if (!std.mem.eql(u8, try r.bytes(magic.len), magic)) return error.Format;
    const n = try r.int(u32);
    try snap.entries.ensureTotalCapacity(gpa, n);
    for (0..n) |_| {
        const path = try r.bytes(try r.int(u32));
        const size = try r.int(u64);
        const mtime = try r.int(i128);
        const text = try r.bytes(try r.int(u64));
        const key = try r.int(u64);
        const ast = try r.bytes(try r.int(u64));
        snap.entries.putAssumeCapacity(path, .{ .size = size, .mtime = @truncate(mtime), .text = text, .key = key, .ast = ast });
    }
}

/// The text of a workspace file, owned by `gpa`: its entry's when the file
/// has the entry's size and time, else the file's, which the cache then
/// takes (on any initialization thread)
pub fn read(self: *Server, path: []const u8) error{ OutOfMemory, ReadFailed }![]u8 {
    const snap = self.index orelse return readFile(self, path);
    const st = Io.Dir.cwd().statFile(self.io, path, .{}) catch return readFile(self, path);
    if (snap.entries.getEntry(path)) |kv| {
        const e = kv.value_ptr.*;
        if (e.size == st.size and e.mtime == st.mtime.nanoseconds) {
            const text = try self.gpa.dupe(u8, e.text);
            errdefer self.gpa.free(text);
            snap.mutex.lockUncancelable(self.io);
            defer snap.mutex.unlock(self.io);
            const gop = try snap.next.getOrPut(self.gpa, kv.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = .{ .entry = e };
            return text;
        }
    }
    const text = try readFile(self, path);
    errdefer self.gpa.free(text);
    // the time before the read: a file changed during it is read again
    // next time
    const keep = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(keep);
    const key = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(key);
    snap.mutex.lockUncancelable(self.io);
    defer snap.mutex.unlock(self.io);
    const gop = try snap.next.getOrPut(self.gpa, key);
    // a path listed twice (overlapping source directories) is read twice
    if (gop.found_existing) {
        self.gpa.free(key);
        self.gpa.free(keep);
        return text;
    }
    gop.value_ptr.* = .{ .entry = .{ .size = st.size, .mtime = st.mtime.nanoseconds, .text = keep }, .own_path = true, .own_text = true };
    snap.changed = true;
    return text;
}

fn readFile(self: *Server, path: []const u8) error{ OutOfMemory, ReadFailed }![]u8 {
    return Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 30)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// The AST of `f` (read by `read`) with the preprocessor's output
/// `prepared`: the cache's when its key is the same, else parsed, and then
/// kept for the cache (on any initialization thread)
pub fn parseFile(self: *Server, f: *FortranFile, prepared: ?pp.Output, opts: parser.Options) !*Ast {
    const snap = self.index orelse return f.parsePrepared(prepared, opts);
    // a trace is of parsing
    if (opts.trace != null) return f.parsePrepared(prepared, opts);
    const key = f.parseKey(prepared, opts, serial.schema);
    if (snap.entries.get(f.path)) |e| if (e.key == key and e.ast.len > 0) {
        const ast = try Ast.create(self.gpa, f);
        if (serial.load(self.gpa, ast, e.ast)) {
            return ast;
        } else |err| {
            ast.destroy();
            self.log.info("index cache: the AST of {s} is not readable ({s}); parsing it", .{ f.path, @errorName(err) });
        }
    };
    const ast = try f.parsePrepared(prepared, opts);
    const bytes = serial.save(self.gpa, ast) catch |err| switch (err) {
        error.OutOfMemory => return ast,
        // not kept: parsed every time
        error.Foreign => return ast,
    };
    snap.mutex.lockUncancelable(self.io);
    defer snap.mutex.unlock(self.io);
    const n = snap.next.getPtr(f.path) orelse {
        self.gpa.free(bytes);
        return ast;
    };
    if (n.own_ast) self.gpa.free(n.entry.ast);
    n.entry.key = key;
    n.entry.ast = bytes;
    n.own_ast = true;
    snap.changed = true;
    return ast;
}

/// After initialization: writes the cache again when a text or an AST was
/// not in it, or an entry was not used (its file has gone or changed), on a
/// thread of its own, which frees the snapshot (the server waits for it
/// when it stops)
pub fn end(self: *Server) void {
    const snap = self.index orelse return;
    self.index = null;
    if (!snap.changed and snap.next.count() == snap.entries.count()) return free(self, snap);
    // one writer at a time
    wait(self);
    self.index_writer = std.Thread.spawn(.{}, writeAndFree, .{ self, snap }) catch {
        writeAndFree(self, snap);
        return;
    };
}

fn free(self: *Server, snap: *Snapshot) void {
    snap.deinit(self.gpa);
    self.gpa.destroy(snap);
}

fn writeAndFree(self: *Server, snap: *Snapshot) void {
    defer free(self, snap);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    write(self, arena.allocator(), snap) catch |e| self.log.warn("could not write the index cache: {s}", .{@errorName(e)});
}

/// Waits for the cache to be written (server shutdown)
pub fn wait(self: *Server) void {
    if (self.index_writer) |t| t.join();
    self.index_writer = null;
}

fn write(self: *Server, a: Allocator, snap: *Snapshot) !void {
    const file = (try cachePath(self, a)) orelse return;
    Io.Dir.cwd().createDirPath(self.io, paths.dirname(file)) catch {};
    // a new file, then renamed over the old one: a reader never sees half
    const tmp = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ file, std.Thread.getCurrentId() });
    const count = snap.next.count();
    {
        const f = try Io.Dir.cwd().createFile(self.io, tmp, .{});
        defer f.close(self.io);
        var buf: [64 * 1024]u8 = undefined;
        var w: Writer = .{ .file = f, .io = self.io, .buf = &buf };
        try w.bytes(magic);
        try w.int(u32, @intCast(count));
        var it = snap.next.iterator();
        while (it.next()) |kv| try w.entry(kv.key_ptr.*, kv.value_ptr.entry);
        try w.flush();
    }
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), file, self.io) catch |e| {
        Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
        return e;
    };
    self.log.info("index cache: {d} files in {s}", .{ count, file });
    prune(self, a, paths.dirname(file));
}

/// Deletes the caches in `dir` not written for `max_age_days`
fn prune(self: *Server, a: Allocator, dir_path: []const u8) void {
    var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);
    const now = Io.Clock.real.now(self.io).nanoseconds;
    const max_age: i96 = @as(i96, max_age_days) * std.time.ns_per_day;
    var it = dir.iterate();
    while (it.next(self.io) catch null) |e| {
        if (e.kind != .file) continue;
        // the unfinished file of a server stopped while it wrote
        const tmp = std.mem.endsWith(u8, e.name, ".tmp");
        if (!tmp and !std.mem.endsWith(u8, e.name, ".zfc")) continue;
        const st = dir.statFile(self.io, e.name, .{}) catch continue;
        if (now - st.mtime.nanoseconds > if (tmp) std.time.ns_per_day else max_age) {
            dir.deleteFile(self.io, e.name) catch {};
            self.log.info("index cache: deleted {s}, unused for {d} days", .{ paths.join(a, &.{ dir_path, e.name }) catch e.name, max_age_days });
        }
    }
}

/// Writes the cache through a buffer (or, in the tests, into a list)
const Writer = struct {
    file: ?Io.File = null,
    io: ?Io = null,
    buf: []u8 = &.{},
    n: usize = 0,
    list: ?*std.ArrayList(u8) = null,
    a: ?Allocator = null,

    fn bytes(w: *Writer, b: []const u8) !void {
        if (w.list) |l| return l.appendSlice(w.a.?, b);
        if (w.n + b.len > w.buf.len) try w.flush();
        if (b.len > w.buf.len) return w.file.?.writeStreamingAll(w.io.?, b);
        @memcpy(w.buf[w.n .. w.n + b.len], b);
        w.n += b.len;
    }

    fn flush(w: *Writer) !void {
        if (w.n == 0) return;
        try w.file.?.writeStreamingAll(w.io.?, w.buf[0..w.n]);
        w.n = 0;
    }

    fn int(w: *Writer, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.bytes(&b);
    }

    fn entry(w: *Writer, path: []const u8, e: Entry) !void {
        try w.int(u32, @intCast(path.len));
        try w.bytes(path);
        try w.int(u64, e.size);
        try w.int(i128, e.mtime);
        try w.int(u64, e.text.len);
        try w.bytes(e.text);
        try w.int(u64, e.key);
        try w.int(u64, e.ast.len);
        try w.bytes(e.ast);
    }
};

test "a cache's entries read back" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var w: Writer = .{ .list = &out, .a = a };
    try w.bytes(magic);
    try w.int(u32, 2);
    try w.entry("/w/a.f90", .{ .size = 5, .mtime = -7, .text = "x = 1", .key = 42, .ast = "abc" });
    try w.entry("/w/b.f90", .{ .size = 0, .mtime = 1 << 70, .text = "" });
    var snap: Snapshot = .{ .data = try gpa.dupe(u8, out.items) };
    defer snap.deinit(gpa);
    try parse(gpa, &snap);
    try std.testing.expectEqual(@as(usize, 2), snap.entries.count());
    const e = snap.entries.get("/w/a.f90").?;
    try std.testing.expectEqualStrings("x = 1", e.text);
    try std.testing.expectEqual(@as(i96, -7), e.mtime);
    try std.testing.expectEqual(@as(u64, 42), e.key);
    try std.testing.expectEqualStrings("abc", e.ast);
    try std.testing.expectEqual(@as(i96, 1 << 70), snap.entries.get("/w/b.f90").?.mtime);
    try std.testing.expectEqualStrings("", snap.entries.get("/w/b.f90").?.ast);
    // a truncated file is no cache
    var bad: Snapshot = .{ .data = try gpa.dupe(u8, out.items[0 .. out.items.len - 3]) };
    defer bad.deinit(gpa);
    try std.testing.expectError(error.Truncated, parse(gpa, &bad));
}
