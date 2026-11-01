//! clangd, asked by zfls itself (`bind_c_clangd`) for the C declarations
//! and calls of a `BIND(C)` procedure's C name, for an editor that has no C
//! language server of its own to ask: its answers are added to those of
//! zfls's search of the C files (bindc.zig), which answers alone when
//! clangd is not set, not started, finds nothing, or does not answer in
//! time. clangd knows a project's C files from its `compile_commands.json`
//! once a file of it is opened: zfls starts it after initialization and
//! opens one, and clangd builds its index (kept in `.cache/clangd/index`)
//! meanwhile. A question opens the file of the C name's symbol, which
//! clangd answers only for an opened file, and closes it after.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const jsonrpc = @import("../jsonrpc.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const bindc = @import("bindc.zig");
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;

/// How long a question waits for each of clangd's answers
const answer_ms = 3000;
/// The `kind` of a function in clangd's workspace symbols
const function_kind = 12;
/// The id of the `initialize` request
const initialize_id = 1;

pub const Clangd = struct {
    child: std.process.Child,
    thread: std.Thread,
    /// The C file opened at the start, so that clangd reads the project's
    /// `compile_commands.json` (owned by `gpa`)
    first_uri: []u8,
    /// Over `waiting`, `next_id`, `ready` and `gone`
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// The questions asked and not yet given up, by id, with clangd's answer
    /// once it came (owned by `gpa`)
    waiting: std.AutoHashMapUnmanaged(i64, ?[]u8) = .empty,
    next_id: i64 = initialize_id + 1,
    /// clangd answered `initialize`
    ready: bool = false,
    /// clangd's output ended: it exited
    gone: bool = false,
    /// One message written at a time
    write_mutex: Io.Mutex = .init,
};

/// Starts clangd after initialization when `bind_c_clangd` names one and
/// the workspace has C files (a failure is logged, and zfls's own search
/// answers)
pub fn start(self: *Server, a: Allocator) void {
    const exe = self.s.bind_c_clangd orelse return;
    if (exe.len == 0 or self.clangd != null or self.s.disable_bind_c_search) return;
    const first = firstFile(self, a) orelse return;
    const first_uri = self.gpa.dupe(u8, paths.pathToUri(a, first) catch return) catch return;
    var child = std.process.spawn(self.io, .{
        .argv = &.{ exe, "--background-index", "--log=error" },
        .cwd = .{ .path = self.root_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |e| {
        self.gpa.free(first_uri);
        self.log.warn("bind_c_clangd: could not start {s}: {s}", .{ exe, @errorName(e) });
        return;
    };
    const c = self.gpa.create(Clangd) catch {
        stopChild(self, &child);
        self.gpa.free(first_uri);
        return;
    };
    c.* = .{ .child = child, .thread = undefined, .first_uri = first_uri };
    c.thread = std.Thread.spawn(.{}, readAnswers, .{ self, c }) catch {
        stopChild(self, &c.child);
        self.gpa.free(first_uri);
        self.gpa.destroy(c);
        return;
    };
    self.clangd = c;
    const init = json.from(a, .{
        .jsonrpc = "2.0",
        .id = initialize_id,
        .method = "initialize",
        .params = .{ .processId = null, .rootUri = paths.pathToUri(a, self.root_path) catch "", .capabilities = .{} },
    }) catch return;
    send(self, c, a, init);
    self.log.info("bind_c_clangd: started {s}", .{exe});
}

/// A C file of the workspace, a source before a header
fn firstFile(self: *Server, a: Allocator) ?[]const u8 {
    const files = bindc.cFiles(self, a) catch return null;
    for (files) |f| {
        const ext = std.fs.path.extension(f);
        if (!std.mem.startsWith(u8, ext, ".h") and !std.mem.eql(u8, ext, ".cuh")) return f;
    }
    return if (files.len > 0) files[0] else null;
}

/// Stops clangd (server shutdown)
pub fn stop(self: *Server) void {
    const c = self.clangd orelse return;
    self.clangd = null;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // as an editor would, so that clangd ends its index's writes
    _ = request(self, c, a, "shutdown", .null) catch null;
    if (json.from(a, .{ .jsonrpc = "2.0", .method = "exit" })) |exit| send(self, c, a, exit) else |_| {}
    stopChild(self, &c.child);
    c.thread.join();
    var it = c.waiting.valueIterator();
    while (it.next()) |v| if (v.*) |body| self.gpa.free(body);
    c.waiting.deinit(self.gpa);
    self.gpa.free(c.first_uri);
    self.gpa.destroy(c);
}

fn stopChild(self: *Server, child: *std.process.Child) void {
    child.kill(self.io);
}

/// Writes a message to clangd (a failure is clangd gone, seen by the
/// reader)
fn send(self: *Server, c: *Clangd, a: Allocator, msg: Value) void {
    const body = json.stringify(a, msg) catch return;
    const framed = jsonrpc.frame(a, body) catch return;
    c.write_mutex.lockUncancelable(self.io);
    defer c.write_mutex.unlock(self.io);
    c.child.stdin.?.writeStreamingAll(self.io, framed) catch {};
}

/// Reads clangd's messages until it exits: keeps the answers to the
/// questions waiting, answers its requests with null, and, when it has
/// answered `initialize`, opens the first C file
fn readAnswers(self: *Server, c: *Clangd) void {
    var buf: [64 * 1024]u8 = undefined;
    var fr = c.child.stdout.?.reader(self.io, &buf);
    while (true) {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const body = (jsonrpc.readMessage(&fr.interface, a) catch null) orelse break;
        const msg = json.parse(a, body) catch continue;
        const id = json.int(json.get(msg, "id")) orelse continue;
        if (json.get(msg, "method") != null) {
            // a request of clangd's (none is expected with no capabilities)
            if (json.from(a, .{ .jsonrpc = "2.0", .id = id, .result = null })) |r| send(self, c, a, r) else |_| {}
            continue;
        }
        if (id == initialize_id) {
            initialized(self, c, a);
            continue;
        }
        c.mutex.lockUncancelable(self.io);
        defer c.mutex.unlock(self.io);
        const slot = c.waiting.getPtr(id) orelse continue;
        if (slot.* != null) continue;
        slot.* = self.gpa.dupe(u8, body) catch null;
        c.cond.broadcast(self.io);
    }
    c.mutex.lockUncancelable(self.io);
    defer c.mutex.unlock(self.io);
    c.gone = true;
    c.cond.broadcast(self.io);
}

fn initialized(self: *Server, c: *Clangd, a: Allocator) void {
    if (json.from(a, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} })) |m| send(self, c, a, m) else |_| {}
    openFile(self, c, a, c.first_uri);
    c.mutex.lockUncancelable(self.io);
    defer c.mutex.unlock(self.io);
    c.ready = true;
}

fn openFile(self: *Server, c: *Clangd, a: Allocator, uri: []const u8) void {
    const path = paths.pathFromUri(self.io, a, uri) catch return;
    const text = Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 * 1024 * 1024)) catch return;
    const ext = std.fs.path.extension(path);
    const cpp = !std.mem.eql(u8, ext, ".c") and !std.mem.eql(u8, ext, ".h");
    const msg = json.from(a, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{ .uri = uri, .languageId = if (cpp) "cpp" else "c", .version = 1, .text = json.validUtf8(a, text) catch return } },
    }) catch return;
    send(self, c, a, msg);
}

fn closeFile(self: *Server, c: *Clangd, a: Allocator, uri: []const u8) void {
    const msg = json.from(a, .{ .jsonrpc = "2.0", .method = "textDocument/didClose", .params = .{ .textDocument = .{ .uri = uri } } }) catch return;
    send(self, c, a, msg);
}

/// clangd's `result` for `method`, in `a`; null when it is gone or does not
/// answer in time
fn request(self: *Server, c: *Clangd, a: Allocator, method: []const u8, params: Value) !?Value {
    const io = self.io;
    c.mutex.lockUncancelable(io);
    if (c.gone) {
        c.mutex.unlock(io);
        return null;
    }
    const id = c.next_id;
    c.next_id += 1;
    c.waiting.put(self.gpa, id, null) catch |e| {
        c.mutex.unlock(io);
        return e;
    };
    c.mutex.unlock(io);
    send(self, c, a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }));
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    // given up or answered: no longer waiting
    defer if (c.waiting.fetchRemove(id)) |kv| if (kv.value) |body| self.gpa.free(body);
    const wait: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(answer_ms), .clock = .awake } };
    const deadline = wait.toDeadline(io);
    while (true) {
        if (c.waiting.get(id).?) |body| {
            const msg = json.parse(a, try a.dupe(u8, body)) catch return null;
            return json.get(msg, "result");
        }
        if (c.gone) return null;
        c.cond.waitTimeout(io, &c.mutex, deadline) catch return null;
    }
}

pub const Want = enum { declarations, uses };

/// What clangd knows of the C function `cname`: its declarations and
/// definition, or all its places (declarations and calls); null when
/// clangd is not running or not ready yet, finds no such function, or does
/// not answer in time
pub fn places(self: *Server, a: Allocator, cname: []const u8, want: Want) !?[]const lsp.Location {
    const c = self.clangd orelse return null;
    {
        c.mutex.lockUncancelable(self.io);
        defer c.mutex.unlock(self.io);
        if (!c.ready or c.gone) return null;
    }
    const symbols = (try request(self, c, a, "workspace/symbol", try json.from(a, .{ .query = cname }))) orelse return null;
    var out: std.ArrayList(lsp.Location) = .empty;
    for (json.items(symbols)) |sym| {
        const name = json.str(json.get(sym, "name")) orelse continue;
        if (!std.mem.eql(u8, name, cname) or (json.int(json.get(sym, "kind")) orelse 0) != function_kind) continue;
        // a C function, not a member of a C++ class or namespace
        if (json.str(json.get(sym, "containerName"))) |container| if (container.len > 0) continue;
        const loc = json.decode(lsp.Location, a, json.get(sym, "location") orelse continue) catch continue;
        const opened = !std.mem.eql(u8, loc.uri, c.first_uri);
        if (opened) openFile(self, c, a, loc.uri);
        defer if (opened) closeFile(self, c, a, loc.uri);
        const at = try json.from(a, .{ .textDocument = .{ .uri = loc.uri }, .position = loc.range.start });
        switch (want) {
            .declarations => {
                try out.append(a, loc);
                for ([_][]const u8{ "textDocument/declaration", "textDocument/definition" }) |method| {
                    const r = (try request(self, c, a, method, at)) orelse continue;
                    try appendLocations(a, &out, r);
                }
            },
            .uses => {
                var params = at;
                try params.object.put(a, "context", try json.from(a, .{ .includeDeclaration = true }));
                const r = (try request(self, c, a, "textDocument/references", params)) orelse continue;
                try appendLocations(a, &out, r);
            },
        }
    }
    if (out.items.len == 0) return null;
    // the URIs as zfls writes them
    for (out.items) |*l| {
        const p = paths.pathFromUri(self.io, a, l.uri) catch continue;
        l.uri = try paths.pathToUri(a, p);
    }
    return try bindc.unique(a, out.items);
}

/// The locations of an answer (a location, or a list of them)
fn appendLocations(a: Allocator, out: *std.ArrayList(lsp.Location), v: Value) !void {
    if (v == .object) {
        if (json.decode(lsp.Location, a, v)) |l| try out.append(a, l) else |_| {}
        return;
    }
    for (json.items(v)) |item| {
        const l = json.decode(lsp.Location, a, item) catch continue;
        try out.append(a, l);
    }
}
