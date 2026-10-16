//! Debug command line modes (port of `fortls.debug`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const json = @import("json.zig");
const json5 = @import("json5.zig");
const paths = @import("paths.zig");
const glob = @import("glob.zig");
const parser = @import("parser.zig");
const pp = @import("preprocessor.zig");
const objects = @import("objects.zig");
const settings_mod = @import("settings.zig");
const server_mod = @import("server.zig");
const Logger = @import("logger.zig");
const Settings = settings_mod.Settings;
const Value = json.Value;

const sep80 = "================================================================================";
const sep75 = "===========================================================================";

pub const DebugError = error{ DebugFailed, OutOfMemory };

const Out = struct {
    io: Io,
    buf: std.ArrayList(u8) = .empty,
    a: Allocator,
    /// What `fail` reported
    fail_msg: []const u8 = "",

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        self.buf.print(self.a, fmt, args) catch {};
        self.flush();
    }

    fn flush(self: *Out) void {
        Io.File.stdout().writeStreamingAll(self.io, self.buf.items) catch {};
        self.buf.clearRetainingCapacity();
    }
};

fn fail(o: *Out, comptime fmt: []const u8, args: anytype) DebugError {
    o.fail_msg = std.fmt.allocPrint(o.a, fmt, args) catch "debug error";
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var o: Out = .{ .io = io, .a = a };
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
};

fn readConfig(a: Allocator, io: Io, o: *Out, root: ?[]const u8, input_config: []const u8) !ConfigInfo {
    var info: ConfigInfo = .{};
    const r = root orelse return info;
    const candidates = [_][]const u8{ input_config, ".fortlsrc", ".fortls.json5", ".fortls" };
    var config_path: ?[]const u8 = null;
    for (candidates) |f| {
        const p = try paths.join(a, &.{ r, f });
        if (paths.isFile(io, p)) {
            config_path = p;
            break;
        }
    }
    o.print("  Config file = {s}\n", .{config_path orelse "None"});
    const cp = config_path orelse return info;
    const data = Io.Dir.cwd().readFileAlloc(io, cp, a, .limited(1 << 26)) catch return info;
    var p: json5.Parser = .{ .a = a, .src = data };
    const cfg = p.parseDocument() catch {
        const msg = try settings_mod.json5ErrorMessage(a, data, p.err_pos);
        o.print("Error {s} while parsing '{s}' settings file\n", .{ msg, cp });
        return info;
    };
    var s: Settings = .{};
    try settings_mod.applyConfig(a, &s, cfg);
    if (s.pp_suffixes) |l| info.pp_suffixes = l.slice();
    for (s.pp_defs.items) |d| try info.pp_defs.put(a, d.name, .{ .value = d.value });
    var dirs: std.ArrayList([]const u8) = .empty;
    for (s.include_dirs.slice()) |inc| {
        for (try glob.resolveGlobs(io, a, inc, r)) |d| if (paths.isDir(io, d)) try dirs.append(a, d);
    }
    info.include_dirs = dirs.items;
    return info;
}

fn printChildren(a: Allocator, o: *Out, obj: *objects.Obj, indent: []const u8) !void {
    for (try obj.getChildren(a, false)) |child| {
        o.print("  {s}{d}: {s}\n", .{ indent, @intFromEnum(child.getType(false)), child.fqsn });
        try printChildren(a, o, child, try std.mem.concat(a, u8, &.{ indent, "  " }));
    }
}

fn debugParser(a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    o.print("\nTesting parser\n", .{});
    separator(o);
    const fp = try ensureFileAccessible(io, o, s.debug_filepath);
    const cfg = try readConfig(a, io, o, s.debug_rootpath, s.config);
    o.print("  File = \"{s}\"\n", .{fp});
    const file = try parser.FortranFile.create(a, fp, cfg.pp_suffixes);
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
    for (try ast.getScopes(a, null)) |obj| {
        o.print("{d}: {s}\n", .{ @intFromEnum(obj.getType(false)), obj.fqsn });
        try printChildren(a, o, obj, "");
    }
    o.print("\n{s}\nExportable Objects\n{s}\n\n", .{ sep80, sep80 });
    var it = ast.global_dict.iterator();
    while (it.next()) |e| o.print("{d}: {s}\n", .{ @intFromEnum(e.value_ptr.*.getType(false)), e.value_ptr.*.fqsn });
    separator(o);
}

fn debugPreprocessor(a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    o.print("\nTesting preprocessor\n", .{});
    separator(o);
    const fp = try ensureFileAccessible(io, o, s.debug_filepath);
    const data = Io.Dir.cwd().readFileAlloc(io, fp, a, .limited(1 << 30)) catch return fail(o, "File '{s}' does not exist or is not accessible", .{fp});
    var lines = try parser.splitLines(a, data);
    // like Python's readlines(): no empty element after a final newline
    if (lines.len > 0 and lines[lines.len - 1].len == 0) lines = lines[0 .. lines.len - 1];
    const root = s.debug_rootpath orelse paths.dirname(fp);
    const cfg = try readConfig(a, io, o, root, s.config);
    const sep2 = sep75;
    o.print("\n{s}\nPreprocessor Pass:\n{s}\n", .{ sep2, sep2 });
    const res = try pp.preprocessFile(a, io, lines, fp, &cfg.pp_defs, cfg.include_dirs, traceTo(o));
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
                    const rel = std.fs.path.relativeAlloc(rq.a, paths.getCwd(), null, rq.s.debug_rootpath.?, path) catch path;
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
