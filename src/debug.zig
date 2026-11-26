//! Debug command line modes (port of `fortls.debug`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const stdio = @import("stdio.zig");
const str = @import("str.zig");
const json = @import("json.zig");
const config_file = @import("settings/config_file.zig");
const paths = @import("paths.zig");
const glob = @import("glob.zig");
const parser = @import("parser.zig");
const pp = @import("preprocessor.zig");
const objects = @import("objects.zig");
const settings_mod = @import("settings.zig");
const workspace_file = @import("settings/workspace_file.zig");
const server_mod = @import("server.zig");
const Logger = @import("logger.zig");
const compilers = @import("compilers.zig");
const predefined = @import("compilers/predefined.zig");
const default_kinds = @import("default_kinds.zig");
const command_options = @import("command_options.zig");
const Settings = settings_mod.Settings;
const Value = json.Value;
const fsio = @import("fsio.zig");

const sep80 = "================================================================================";
const sep75 = "===========================================================================";

pub const DebugError = error{ DebugFailed, OutOfMemory };

/// How much held output is written at once
const hold_limit = 1 << 16;

const Out = struct {
    io: Io,
    buf: std.ArrayList(u8) = .empty,
    a: Allocator,
    /// What `fail` reported
    fail_msg: []const u8 = "",
    /// Where the output goes instead of stdout (for tests), with its
    /// allocator
    capture: ?Capture = null,
    /// The error of the first write that failed: the output is incomplete
    write_error: ?anyerror = null,
    /// Whether `print` waits for `hold_limit` bytes before it writes
    hold: bool = false,

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        self.buf.print(self.a, fmt, args) catch {};
        if (!self.hold or self.buf.items.len >= hold_limit) self.flush();
    }

    /// `n` blanks
    fn spaces(self: *Out, n: usize) void {
        self.buf.appendNTimes(self.a, ' ', n) catch {};
    }

    /// From now on write in blocks, not at each line (for the thousands of
    /// lines of a tree); `release` writes what is left
    fn holdOutput(self: *Out) void {
        self.hold = true;
    }

    fn release(self: *Out) void {
        self.hold = false;
        self.flush();
    }

    fn flush(self: *Out) void {
        if (self.capture) |c| {
            c.out.appendSlice(c.a, self.buf.items) catch {};
        } else if (self.write_error == null) stdio.stdout().writeStreamingAll(self.io, self.buf.items) catch |e| {
            self.write_error = e;
        };
        self.buf.clearRetainingCapacity();
    }
};

pub const Capture = struct { a: Allocator, out: *std.ArrayList(u8) };

fn fail(o: *Out, comptime fmt: []const u8, args: anytype) DebugError {
    o.fail_msg = o.a.print(fmt, args) catch "debug error";
    return error.DebugFailed;
}

fn separator(o: *Out) void {
    o.print("{s}\n", .{sep80});
}

fn traceWrite(ctx: *anyopaque, msg: []const u8) void {
    const o: *Out = @ptrCast(@alignCast(ctx));
    o.print("{s}\n", .{msg});
}

fn traceTo(o: *Out) parser.Trace {
    return .{ .ctx = o, .writeFn = traceWrite };
}

/// Run the requested debug mode; returns the process exit code
pub fn run(gpa: Allocator, io: Io, s_in: Settings) !u8 {
    return runTo(gpa, io, s_in, null);
}

/// `run`, its output in `capture` instead of on stdout
pub fn runTo(gpa: Allocator, io: Io, s_in: Settings, capture: ?Capture) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var o: Out = .{ .io = io, .a = a, .capture = capture };
    var s = s_in;
    const result = blk: {
        if (s.debug_parser) break :blk debugParser(a, io, &o, &s);
        if (s.debug_preproc) break :blk debugPreprocessor(a, io, &o, &s);
        break :blk debugLsp(gpa, a, io, &o, &s);
    };
    result catch |e| switch (e) {
        error.DebugFailed => {
            o.print("ERROR: {s}\n", .{o.fail_msg});
            return 255;
        },
        else => return e,
    };
    if (o.write_error) |e| {
        // a reader that has gone away (`| head`) knows
        if (e != error.BrokenPipe) {
            var buf: [128]u8 = undefined;
            const msg = std.mem.print(&buf, "ERROR: the output is incomplete: {s}\n", .{@errorName(e)}) catch "";
            stdio.stderr().writeStreamingAll(io, msg) catch {};
        }
        return 1;
    }
    return 0;
}

fn ensureFileAccessible(io: Io, o: *Out, filepath: ?[]const u8) DebugError![]const u8 {
    const fp = filepath orelse return fail(o, "File 'None' does not exist or is not accessible", .{});
    if (!paths.isFile(io, fp)) return fail(o, "File '{s}' does not exist or is not accessible", .{fp});
    o.print("  File = \"{s}\"\n", .{fp});
    return fp;
}

const ConfigInfo = struct {
    pp_suffixes: ?[]const []const u8 = null,
    pp_defs: pp.Defs = .empty,
    include_dirs: []const []const u8 = &.{},
    /// `d_lines`: debug lines read as code
    d_lines_code: bool = false,
    /// `fixed_line_length`
    fixed_columns: ?usize = null,
};

/// The preprocessor options as the server takes them: the command line's
/// (`s`), the user's configuration file's over them, and the configuration
/// file's in `root` over those
fn readConfig(a: Allocator, io: Io, o: *Out, root: ?[]const u8, s: *const Settings) !ConfigInfo {
    var merged = try settings_mod.clone(a, s.*);
    if (paths.userConfigFile()) |u| if (paths.isFile(io, u)) {
        o.print("  User config file = {s}\n", .{u});
        try applyConfigFile(a, io, o, &merged, u, true);
    };
    if (root) |r| {
        const found = try config_file.find(a, io, r, s.config);
        const config_path: ?[]const u8 = if (found) |f| f.path else null;
        o.print("  Config file = {s}\n", .{config_path orelse "None"});
        if (config_path) |cp| try applyConfigFile(a, io, o, &merged, cp, false);
    }
    var info: ConfigInfo = .{};
    // an empty list is the default rule, as in the server
    if (merged.pp_suffixes) |l| if (l.len() > 0) {
        info.pp_suffixes = l.slice();
    };
    for (merged.pp_defs.items) |d| try info.pp_defs.put(a, d.name, .{ .value = d.value });
    try addPredefined(a, io, o, &merged, root, &info.pp_defs);
    var dirs: std.ArrayList([]const u8) = .empty;
    for (merged.include_dirs.slice()) |inc| {
        for (try glob.resolveGlobs(io, a, inc, root)) |d| if (paths.isDir(io, d)) try dirs.append(a, d);
    }
    info.include_dirs = dirs.items;
    info.d_lines_code = merged.dLinesCode();
    info.fixed_columns = merged.fixedColumns();
    return info;
}

/// The symbols `compiler_diagnostics`'s compiler predefines, as the server
/// adds them (server/compiler_macros.zig), to `defs`, those there kept
fn addPredefined(a: Allocator, io: Io, o: *Out, s: *const Settings, root: ?[]const u8, defs: *pp.Defs) !void {
    const name = s.compiler_diagnostics orelse return;
    const id = compilers.Id.fromName(std.mem.trim(u8, name, " ")) orelse return;
    if (!predefined.asks(id)) return;
    const configured = s.compiler_path orelse "";
    const exe = if (configured.len == 0) compilers.executables(id)[0] else if (root != null and !std.Io.Dir.path.isAbsolute(configured)) try paths.join(a, &.{ root.?, configured }) else configured;
    const base = paths.cacheDir() orelse root orelse ".";
    const found = predefined.ask(a, a, id, exe, .{ .io = io, .env = null, .work_dir = try paths.join(a, &.{ base, "work", "debug" }), .cwd = root, .openmp = !s.disable_openmp_conditional }) orelse {
        o.print("  Predefined symbols: {s} did not run\n", .{exe});
        return;
    };
    for (found) |d| if (!defs.contains(d.name)) try defs.put(a, d.name, .{ .value = d.value });
    o.print("  Predefined symbols of {s}: {d}\n", .{ exe, found.len });
}

/// The settings of the configuration file `path` over `s`; `trusted`: not
/// the workspace's own (which names no program to run)
fn applyConfigFile(a: Allocator, io: Io, o: *Out, s: *Settings, path: []const u8, trusted: bool) !void {
    const data = fsio.readFile(io, a, path, .limited(1 << 26)) catch return;
    switch (try config_file.parse(a, a, data, path)) {
        .ok => |loaded| {
            var ignored: std.ArrayList([]const u8) = .empty;
            if (trusted) try settings_mod.applyConfig(a, s, loaded.cfg) else try workspace_file.apply(a, s, loaded.cfg, &ignored);
        },
        .err => |msg| o.print("{s}\n", .{msg}),
    }
}

/// The children of `obj` at `depth` levels of indent, each followed by its
/// own, unless `seen` has it: what is under a scope is printed once, where
/// the scope is first reached
fn printChildren(a: Allocator, o: *Out, obj: *objects.Obj, depth: usize, seen: *std.AutoHashMapUnmanaged(*const objects.Obj, void)) !void {
    for (try obj.getChildren(a, false)) |child| {
        o.spaces(2 + 2 * depth);
        o.print("{d}: {s}{s}\n", .{ @backingInt(child.getType(false)), child.fqsn, groupMark(child) });
        if ((try seen.getOrPut(a, child)).found_existing) continue;
        try printChildren(a, o, child, depth + 1, seen);
    }
    // its COMMON blocks (#556)
    if (obj.data == .scope) for (obj.scopeData().commons.items) |c| {
        o.spaces(2 + 2 * depth);
        o.print("{d}: {s}{s}\n", .{ @backingInt(c.getType(false)), c.fqsn, groupMark(c) });
    };
}

/// After a COMMON block or NAMELIST group in the object tree: what it is
fn groupMark(obj: *const objects.Obj) []const u8 {
    if (obj.kind != .variable) return "";
    return switch (obj.varDataConst().group) {
        .none => "",
        .common => " COMMON",
        .namelist => " NAMELIST",
    };
}

fn debugParser(a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    o.print("\nTesting parser\n", .{});
    separator(o);
    const fp = try ensureFileAccessible(io, o, s.debug_filepath);
    const cfg = try readConfig(a, io, o, s.debug_rootpath, s);
    o.print("  File = \"{s}\"\n", .{fp});
    const file = try parser.FortranFile.create(a, fp, cfg.pp_suffixes);
    // as the server reads the file (workspace.loadFile)
    file.d_lines_code = cfg.d_lines_code;
    file.fixed_columns = cfg.fixed_columns;
    // as the options of `compiler_args` say (server/file_options.zig), for
    // the oracles
    if (s.compiler_args) |l| {
        const ro = command_options.parse(l.slice());
        if (ro.fixed) |fixed| file.command_form = if (fixed) .fixed else .free;
        if (ro.columns) |c| file.fixed_columns = switch (c) {
            .limit => |n| n,
            .none => null,
        };
        if (ro.d_lines_code) |code| file.d_lines_code = code;
        file.implicit_none = ro.implicit_none;
        file.default_kinds = default_kinds.parse(l.slice());
    }
    _ = file.loadFromDisk(io) catch |e| return fail(o, "Reading file failed: {s}", .{parser.describeFileError(e)});
    o.print("  Detected format: {s}\n", .{if (file.fixed) "fixed" else "free"});
    o.print("\n{s}\nParser Output\n{s}\n\n", .{ sep80, sep80 });
    const ast = try file.parse(io, &cfg.pp_defs, cfg.include_dirs, .{ .sort_keywords = true, .trace = traceTo(o) });
    if (ast.end_errors.items.len > 0) {
        o.print("\n=== Scope Errors ===\n\n", .{});
        for (ast.end_errors.items) |e| {
            if (e.end_line) |el| {
                o.print("{d}: Unexpected end of scope at line {d}\n", .{ e.scope_line, el });
            } else {
                o.print("{d}: Unexpected end statement: No open scopes\n", .{e.scope_line});
            }
        }
    }
    if (ast.parse_errors.items.len > 0) {
        o.print("\n=== Parsing Errors ===\n\n", .{});
        for (ast.parse_errors.items) |e| {
            o.print("{{'start': {{'line': {d}, 'character': {d}}}, 'end': {{'line': {d}, 'character': {d}}}}}: {s}\n", .{ e.sln, e.sch, e.eln orelse e.sln, e.ech orelse e.sch, e.message });
        }
    }
    o.print("\n{s}\nObject Tree\n{s}\n\n", .{ sep80, sep80 });
    // in blocks: thousands of nested scopes make a long tree
    o.holdOutput();
    defer o.release();
    var tree_seen: std.AutoHashMapUnmanaged(*const objects.Obj, void) = .empty;
    for (try ast.getScopes(a, null)) |obj| {
        // a scope in the tree of another was printed there
        if ((try tree_seen.getOrPut(a, obj)).found_existing) continue;
        o.print("{d}: {s}\n", .{ @backingInt(obj.getType(false)), obj.fqsn });
        try printChildren(a, o, obj, 0, &tree_seen);
    }
    // the ENTRY procedures of external procedures, in no scope's lines
    for (ast.entry_list.items) |e| if (e.parent == null) o.print("{d}: {s}\n", .{ @backingInt(e.getType(false)), e.fqsn });
    o.print("\n{s}\nExportable Objects\n{s}\n\n", .{ sep80, sep80 });
    var it = ast.global_dict.iterator();
    while (it.next()) |e| o.print("{d}: {s}\n", .{ @backingInt(e.value_ptr.*.getType(false)), e.value_ptr.*.fqsn });
    // the lines of each block of SELECT TYPE and RANK and of its SELECT,
    // for the oracles to tell the blocks' associate names apart (#715)
    o.print("\n{s}\nSelect Blocks\n{s}\n\n", .{ sep80, sep80 });
    var blocks_seen: std.AutoHashMapUnmanaged(*const objects.Obj, void) = .empty;
    for (try ast.getScopes(a, null)) |obj| try printConstructLines(a, o, obj, &blocks_seen, .select_block);
    // the line of each ASSOCIATE construct, for the oracles to pair its
    // names with their own construct's (#754)
    o.print("\n{s}\nAssociate Constructs\n{s}\n\n", .{ sep80, sep80 });
    var assoc_seen: std.AutoHashMapUnmanaged(*const objects.Obj, void) = .empty;
    for (try ast.getScopes(a, null)) |obj| try printConstructLines(a, o, obj, &assoc_seen, .associate);
    // what hover shows of each variable, for the oracles' types and kinds,
    // with the file's links resolved as a workspace of it alone would
    var tree: objects.ObjTree = .empty;
    try ast.resolveLinks(.{ .tree = &tree, .tmp = a }, 0);
    o.print("\n{s}\nDeclarations\n{s}\n\n", .{ sep80, sep80 });
    var seen: std.AutoHashMapUnmanaged(*const objects.Obj, void) = .empty;
    for (try ast.getScopes(a, null)) |obj| try printDeclarations(a, o, obj, &seen);
    separator(o);
}

/// Under `obj` (each once): `fqsn: SELECT_LINE LINE` of each TYPE IS,
/// CLASS IS, CLASS DEFAULT and RANK block, or `fqsn: LINE` of each
/// ASSOCIATE construct
fn printConstructLines(a: Allocator, o: *Out, obj: *objects.Obj, seen: *std.AutoHashMapUnmanaged(*const objects.Obj, void), which: enum { select_block, associate }) !void {
    for (try obj.getChildren(a, false)) |child| {
        if ((try seen.getOrPut(a, child)).found_existing) continue;
        switch (which) {
            .select_block => if (child.isTypeRegion()) o.print("{s}: {d} {d}\n", .{ child.fqsn, if (child.parent) |p| p.sline else 0, child.sline }),
            .associate => if (child.kind == .associate) o.print("{s}: {d}\n", .{ child.fqsn, child.sline }),
        }
        try printConstructLines(a, o, child, seen, which);
    }
}

/// `fqsn: declaration` of each variable under `obj` (each once), the
/// first line of its hover
fn printDeclarations(a: Allocator, o: *Out, obj: *objects.Obj, seen: *std.AutoHashMapUnmanaged(*const objects.Obj, void)) !void {
    for (try obj.getChildren(a, false)) |child| {
        if ((try seen.getOrPut(a, child)).found_existing) continue;
        if (child.kind == .variable) if ((try child.getHover(a, false, null)).msg) |msg| {
            o.print("{s}: {s}\n", .{ child.fqsn, msg[0 .. std.mem.findScalar(u8, msg, '\n') orelse msg.len] });
        };
        try printDeclarations(a, o, child, seen);
    }
}

fn debugPreprocessor(a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    o.print("\nTesting preprocessor\n", .{});
    separator(o);
    const fp = try ensureFileAccessible(io, o, s.debug_filepath);
    const data = fsio.readFile(io, a, fp, .limited(1 << 30)) catch return fail(o, "File '{s}' does not exist or is not accessible", .{fp});
    var lines = try parser.splitLines(a, data);
    // like Python's readlines(): no empty element after a final newline
    if (lines.len > 0 and lines[lines.len - 1].len == 0) lines = lines[0 .. lines.len - 1];
    const root = s.debug_rootpath orelse paths.dirname(fp);
    const cfg = try readConfig(a, io, o, root, s);
    const sep2 = sep75;
    o.print("\n{s}\nPreprocessor Pass:\n{s}\n", .{ sep2, sep2 });
    const res = try pp.preprocessFile(a, io, lines, fp, &cfg.pp_defs, cfg.include_dirs, .any, traceTo(o));
    o.print("\n{s}\nPreprocessor Skipped Lines:\n{s}\n", .{ sep2, sep2 });
    for (res.skips) |sk| o.print("  [{d}, {d}]\n", .{ sk.start, sk.end });
    o.print("\n{s}\nPreprocessor Macros:\n{s}\n", .{ sep2, sep2 });
    var it = res.defs.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.args) |args| {
            o.print("  {s} = ('{s}', '{s}')\n", .{ e.key_ptr.*, args, e.value_ptr.value });
        } else {
            o.print("  {s} = {s}\n", .{ e.key_ptr.*, e.value_ptr.value });
        }
    }
    o.print("\n{s}\nPreprocessor Defines (#define):\n{s}\n", .{ sep2, sep2 });
    for (res.defines) |d| o.print("  {d}\n", .{d});
    o.print("\n{s}\nPreprocessor Final Output:\n{s}\n", .{ sep2, sep2 });
    for (res.lines) |l| o.print("  {s}\n", .{str.rstrip(l)});
    separator(o);
}

// --------------------------------------------------------------------------
// LSP request debugging

const Req = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    o: *Out,
    s: *Settings,
    server: *server_mod.Server,
};

fn textDoc(a: Allocator, uri: []const u8) !Value {
    return json.from(a, .{ .textDocument = .{ .uri = uri } });
}

fn posParams(r: *Req) !Value {
    var p = try textDoc(r.a, r.s.debug_filepath.?);
    try p.object.put(r.a, "position", try json.from(r.a, .{
        .line = (r.s.debug_line orelse 1) - 1,
        .character = (r.s.debug_char orelse 1) - 1,
    }));
    return p;
}

fn checkRequestParams(r: *Req, loc_needed: bool) !void {
    _ = try ensureFileAccessible(r.io, r.o, r.s.debug_filepath);
    if (loc_needed) {
        const line = r.s.debug_line orelse return fail(r.o, "'debug_line' not specified for debug request", .{});
        r.o.print("  Line = {d}\n", .{line});
        const char = r.s.debug_char orelse return fail(r.o, "'debug_char' not specified for debug request", .{});
        r.o.print("  Char = {d}\n\n", .{char});
    }
}

fn save(r: *Req) !void {
    _ = try r.server.serveOnSave(r.a, .{ .textDocument = .{ .uri = r.s.debug_filepath.? } }, false, false);
}

fn printResults(r: *Req, results: Value, comptime fmtFn: fn (*Req, Value) anyerror!void) !void {
    if (results == .null) {
        r.o.print("    No result found!\n", .{});
        return;
    }
    if (r.s.debug_full_result) {
        r.o.print("{s}\n", .{try json.pretty(r.a, results)});
        return;
    }
    try fmtFn(r, results);
}

fn generic(r: *Req, label: []const u8, loc_needed: bool, comptime reqFn: fn (*Req) anyerror!Value, comptime fmtFn: fn (*Req, Value) anyerror!void) !void {
    r.o.print("\nTesting \"{s}\" request:\n", .{label});
    try checkRequestParams(r, loc_needed);
    const results = try reqFn(r);
    separator(r.o);
    try printResults(r, results, fmtFn);
}

fn debugLsp(gpa: Allocator, a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    var log = Logger.init(io);
    log.stderr_level = .off;
    defer log.deinit();
    const server = try server_mod.Server.create(gpa, io, s.*, &log);
    defer server.destroy();
    var r: Req = .{ .gpa = gpa, .a = a, .io = io, .o = o, .s = &server.s, .server = server };

    if (s.debug_rootpath) |rp| {
        if (!paths.isDir(io, rp)) return fail(o, "'debug_rootpath' not specified for debug request", .{});
        o.print("\nTesting \"initialize\" request:\n", .{});
        o.print("  Root = \"{s}\"\n", .{rp});
        _ = try server.dispatchPublic(a, "initialize", try json.from(a, .{ .rootPath = rp }));
        separator(o);
        if (server.post_messages.items.len == 0) {
            o.print("  Successful!\n", .{});
        } else {
            o.print("  Successful with errors:\n", .{});
            for (server.post_messages.items) |m| o.print("    {s}\n", .{m.message});
        }
        o.print("\n  Source directories:\n", .{});
        for (server.s.source_dirs.slice()) |d| o.print("    {s}\n", .{d});
        separator(o);
    }
    if (s.debug_diagnostics) {
        try generic(&r, "textDocument/publishDiagnostics", false, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return (try rq.server.getDiagnostics(rq.a, rq.s.debug_filepath.?)) orelse .null;
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                const sev_map = [_][]const u8{ "ERROR", "WARNING", "INFO" };
                if (json.items(res).len == 0) {
                    rq.o.print("No errors or warnings\n", .{});
                } else rq.o.print("Reported Diagnostics:\n", .{});
                for (json.items(res)) |d| {
                    const sline = json.int(json.path(d, &.{ "range", "start", "line" })) orelse 0;
                    const sev = json.int(json.get(d, "severity")) orelse 1;
                    const msg = json.str(json.get(d, "message")) orelse "";
                    rq.o.print("  {d:>5}:{s}  \"{s}\"\n", .{ sline, sev_map[@intCast(std.math.clamp(sev - 1, 0, 2))], msg });
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_symbols) {
        try generic(&r, "textDocument/documentSymbol", false, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/documentSymbol", try textDoc(rq.a, rq.s.debug_filepath.?));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (json.items(res)) |sym| {
                    const sline = json.int(json.path(sym, &.{ "location", "range", "start", "line" })) orelse 0;
                    const parent = json.str(json.get(sym, "containerName")) orelse "null";
                    const kind = json.int(json.get(sym, "kind")) orelse 0;
                    const name = json.str(json.get(sym, "name")) orelse "";
                    rq.o.print("  line {d:>5}  symbol -> {d:>3}:{s:<30} parent = {s}\n", .{ sline, kind, name, parent });
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_workspace_symbols) |_| {
        try generic(&r, "workspace/symbol", false, struct {
            fn req(rq: *Req) !Value {
                if (rq.s.debug_rootpath == null) return fail(rq.o, "'debug_rootpath' not specified for debug request", .{});
                return rq.server.dispatchPublic(rq.a, "workspace/symbol", try json.from(rq.a, .{ .query = rq.s.debug_workspace_symbols.? }));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (json.items(res)) |sym| {
                    const uri = json.str(json.path(sym, &.{ "location", "uri" })) orelse "";
                    const path = try paths.pathFromUri(rq.io, rq.a, uri);
                    const sline = json.int(json.path(sym, &.{ "location", "range", "start", "line" })) orelse 0;
                    const parent = json.str(json.get(sym, "containerName")) orelse "null";
                    const name = json.str(json.get(sym, "name")) orelse "";
                    const rel = std.Io.Dir.path.relativeAlloc(rq.a, paths.getCwd(), null, rq.s.debug_rootpath.?, path) catch path;
                    rq.o.print("  {s}::{d}  symbol -> {s:<30} parent = {s}\n", .{ parent, sline, name, rel });
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_completion) {
        try generic(&r, "textDocument/completion", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/completion", try posParams(rq));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (json.items(res)) |item| {
                    const kind = json.int(json.get(item, "kind")) orelse 0;
                    const label = json.str(json.get(item, "label")) orelse "";
                    const detail = json.str(json.get(item, "detail")) orelse "";
                    rq.o.print("    {d}: {s} -> {s}\n", .{ kind, label, detail });
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_hover) {
        try generic(&r, "textDocument/hover", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/hover", try posParams(rq));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                const contents = json.get(res, "contents") orelse .null;
                if (contents == .object) {
                    rq.o.print("{s}\n", .{json.str(json.get(contents, "value")) orelse ""});
                } else {
                    rq.o.print("{s}\n", .{try json.stringify(rq.a, contents)});
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_signature) {
        try generic(&r, "textDocument/signatureHelp", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/signatureHelp", try posParams(rq));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                const active_param = json.int(json.get(res, "activeParameter")) orelse 0;
                rq.o.print("    Active param = {d}\n", .{active_param});
                const active_sig = json.int(json.get(res, "activeSignature")) orelse 0;
                rq.o.print("    Active sig   = {d}\n", .{active_sig});
                for (json.items(json.get(res, "signatures")), 0..) |sig, i| {
                    rq.o.print("    {s}\n", .{json.str(json.get(sig, "label")) orelse ""});
                    for (json.items(json.get(sig, "parameters")), 0..) |p, j| {
                        const mark: []const u8 = if (i == active_sig and j == active_param) "*" else " ";
                        const label = json.str(json.get(p, "label")) orelse "";
                        if (json.get(p, "documentation")) |d| {
                            rq.o.print("{s}     {s} :: {s}\n", .{ mark, try json.stringify(rq.a, d), label });
                        } else {
                            rq.o.print("{s}     {s}\n", .{ mark, label });
                        }
                    }
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_definition) {
        try generic(&r, "textDocument/definition", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/definition", try posParams(rq));
            }
        }.req, printLocation);
        separator(o);
    }
    if (s.debug_references) {
        try generic(&r, "textDocument/references", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/references", try posParams(rq));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (json.items(res)) |loc| {
                    const uri = json.str(json.get(loc, "uri")) orelse "";
                    const line = json.int(json.path(loc, &.{ "range", "start", "line" })) orelse 0;
                    const char = json.int(json.path(loc, &.{ "range", "start", "character" })) orelse 0;
                    rq.o.print("  {s}  ({d}, {d})\n", .{ uri, line + 1, char + 1 });
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_implementation) {
        try generic(&r, "textDocument/implementation", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                return rq.server.dispatchPublic(rq.a, "textDocument/implementation", try posParams(rq));
            }
        }.req, printLocation);
        separator(o);
    }
    if (s.debug_rename) |_| {
        try generic(&r, "textDocument/rename", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                var p = try posParams(rq);
                try p.object.put(rq.a, "newName", try json.from(rq.a, rq.s.debug_rename.?));
                return rq.server.dispatchPublic(rq.a, "textDocument/rename", p);
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                const changes = json.get(res, "changes") orelse return;
                if (changes != .object) return;
                for (changes.object.keys(), changes.object.values()) |uri, edits| {
                    const path = try paths.pathFromUri(rq.io, rq.a, uri);
                    const file = rq.server.workspace.get(path) orelse {
                        rq.o.print("Unknown file: \"{s}\"\n", .{path});
                        continue;
                    };
                    try processFileChanges(rq, path, edits, file);
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_actions) {
        try generic(&r, "textDocument/getActions", true, struct {
            fn req(rq: *Req) !Value {
                try save(rq);
                const line = (rq.s.debug_line orelse 1) - 1;
                const char = (rq.s.debug_char orelse 1) - 1;
                var p = try textDoc(rq.a, rq.s.debug_filepath.?);
                try p.object.put(rq.a, "range", try json.from(rq.a, .{
                    .start = .{ .line = line, .character = char },
                    .end = .{ .line = line, .character = char },
                }));
                return rq.server.dispatchPublic(rq.a, "textDocument/codeAction", p);
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (json.items(res)) |act| {
                    rq.o.print("Kind = '{s}', Title = '{s}'\n", .{
                        json.str(json.get(act, "kind")) orelse "",
                        json.str(json.get(act, "title")) orelse "",
                    });
                    const changes = json.path(act, &.{ "edit", "changes" }) orelse continue;
                    if (changes != .object) continue;
                    for (changes.object.keys(), changes.object.values()) |uri, edits| {
                        rq.o.print("\nChange: URI = '{s}'\n", .{uri});
                        rq.o.print("{s}\n", .{try json.pretty(rq.a, edits)});
                    }
                    rq.o.print("\n", .{});
                }
            }
        }.f);
        separator(o);
    }
}

fn printLocation(rq: *Req, res: Value) !void {
    rq.o.print("    URI  = \"{s}\"\n", .{json.str(json.get(res, "uri")) orelse ""});
    rq.o.print("    Line = {d}\n", .{(json.int(json.path(res, &.{ "range", "start", "line" })) orelse 0) + 1});
    rq.o.print("    Char = {d}\n", .{(json.int(json.path(res, &.{ "range", "start", "character" })) orelse 0) + 1});
}

fn processFileChanges(rq: *Req, path: []const u8, changes: Value, file: *parser.FortranFile) !void {
    rq.o.print("File: \"{s}\"\n", .{path});
    for (json.items(changes)) |change| {
        const sl: usize = @intCast(@max(json.int(json.path(change, &.{ "range", "start", "line" })) orelse 0, 0));
        const el: usize = @intCast(@max(json.int(json.path(change, &.{ "range", "end", "line" })) orelse 0, 0));
        const sc: usize = @intCast(@max(json.int(json.path(change, &.{ "range", "start", "character" })) orelse 0, 0));
        const ec: usize = @intCast(@max(json.int(json.path(change, &.{ "range", "end", "character" })) orelse 0, 0));
        const new_text = json.str(json.get(change, "newText")) orelse "";
        rq.o.print("  {d}, {d}\n", .{ sl + 1, el + 1 });
        var new_contents: std.ArrayList([]const u8) = .empty;
        var i = sl;
        while (i <= el) : (i += 1) {
            const line = file.getLine(i, false) orelse "";
            rq.o.print("  - {s}\n", .{line});
            var content: []const u8 = line;
            if (i == sl) content = try std.mem.concat(rq.a, u8, &.{ line[0..str.utf16ToByte(line, sc)], new_text });
            if (i == el) content = try std.mem.concat(rq.a, u8, &.{ content, str.from(line, str.utf16ToByte(line, ec)) });
            try new_contents.append(rq.a, content);
        }
        for (new_contents.items) |l| rq.o.print("  + {s}\n", .{l});
        rq.o.print("\n", .{});
    }
}
