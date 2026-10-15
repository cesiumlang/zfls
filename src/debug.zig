//! Debug command line modes (port of `fortls.debug`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const json = @import("json.zig");
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

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        self.buf.print(self.a, fmt, args) catch {};
        self.flush();
    }

    fn flush(self: *Out) void {
        Io.File.stdout().writeStreamingAll(self.io, self.buf.items) catch {};
        self.buf.clearRetainingCapacity();
    }
};

var out_global: ?*Out = null;
var fail_msg: []const u8 = "";

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) DebugError {
    fail_msg = std.fmt.allocPrint(a, fmt, args) catch "debug error";
    return error.DebugFailed;
}

fn separator(o: *Out) void {
    o.print("{s}\n", .{sep80});
}

fn parserTrace(msg: []const u8) void {
    if (out_global) |o| o.print("{s}\n", .{msg});
}

/// Run the requested debug mode; returns the process exit code
pub fn run(gpa: Allocator, io: Io, s_in: Settings) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var o: Out = .{ .io = io, .a = a };
    out_global = &o;
    defer out_global = null;
    var s = s_in;
    const result = blk: {
        if (s.debug_parser) break :blk debugParser(a, io, &o, &s);
        if (s.debug_preproc) break :blk debugPreprocessor(a, io, &o, &s);
        break :blk debugLsp(gpa, a, io, &o, &s);
    };
    result catch |e| switch (e) {
        error.DebugFailed => {
            o.print("ERROR: {s}\n", .{fail_msg});
            return 255;
        },
        else => return e,
    };
    return 0;
}

fn ensureFileAccessible(a: Allocator, io: Io, o: *Out, filepath: ?[]const u8) DebugError![]const u8 {
    const fp = filepath orelse return fail(a, "File 'None' does not exist or is not accessible", .{});
    if (!paths.isFile(io, fp)) return fail(a, "File '{s}' does not exist or is not accessible", .{fp});
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
    var p: json.Parser = .{ .a = a, .src = data };
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
        o.print("  {s}{d}: {s}\n", .{ indent, child.getType(false), child.fqsn });
        try printChildren(a, o, child, try std.mem.concat(a, u8, &.{ indent, "  " }));
    }
}

fn debugParser(a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    o.print("\nTesting parser\n", .{});
    separator(o);
    const fp = try ensureFileAccessible(a, io, o, s.debug_filepath);
    const cfg = try readConfig(a, io, o, s.debug_rootpath, s.config);
    o.print("  File = \"{s}\"\n", .{fp});
    const file = try parser.FortranFile.create(a, fp, cfg.pp_suffixes);
    const lr = file.loadFromDisk(io);
    if (lr.err) |e| return fail(a, "Reading file failed: {s}", .{e});
    o.print("  Detected format: {s}\n", .{if (file.fixed) "fixed" else "free"});
    o.print("\n{s}\nParser Output\n{s}\n\n", .{ sep80, sep80 });
    parser.debug_hook = parserTrace;
    defer parser.debug_hook = null;
    const ast = try file.parse(io, &cfg.pp_defs, cfg.include_dirs);
    parser.debug_hook = null;
    if (ast.end_errors.items.len > 0) {
        o.print("\n=== Scope Errors ===\n\n", .{});
        for (ast.end_errors.items) |e| {
            if (e[0] >= 0) {
                o.print("{d}: Unexpected end of scope at line {d}\n", .{ e[1], e[0] });
            } else {
                o.print("{d}: Unexpected end statement: No open scopes\n", .{e[1]});
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
        o.print("{d}: {s}\n", .{ obj.getType(false), obj.fqsn });
        try printChildren(a, o, obj, "");
    }
    o.print("\n{s}\nExportable Objects\n{s}\n\n", .{ sep80, sep80 });
    var it = ast.global_dict.iterator();
    while (it.next()) |e| o.print("{d}: {s}\n", .{ e.value_ptr.*.getType(false), e.value_ptr.*.fqsn });
    separator(o);
}

fn debugPreprocessor(a: Allocator, io: Io, o: *Out, s: *Settings) !void {
    o.print("\nTesting preprocessor\n", .{});
    separator(o);
    const fp = try ensureFileAccessible(a, io, o, s.debug_filepath);
    const data = Io.Dir.cwd().readFileAlloc(io, fp, a, .limited(1 << 30)) catch return fail(a, "File '{s}' does not exist or is not accessible", .{fp});
    var lines = try parser.splitLines(a, data);
    // like Python's readlines(): no empty element after a final newline
    if (lines.len > 0 and lines[lines.len - 1].len == 0) lines = lines[0 .. lines.len - 1];
    const root = s.debug_rootpath orelse paths.dirname(fp);
    const cfg = try readConfig(a, io, o, root, s.config);
    const sep2 = sep75;
    o.print("\n{s}\nPreprocessor Pass:\n{s}\n", .{ sep2, sep2 });
    parser.debug_hook = parserTrace;
    defer parser.debug_hook = null;
    const res = try pp.preprocessFile(a, io, lines, fp, &cfg.pp_defs, cfg.include_dirs);
    parser.debug_hook = null;
    o.print("\n{s}\nPreprocessor Skipped Lines:\n{s}\n", .{ sep2, sep2 });
    for (res.skips) |sk| o.print("  [{d}, {d}]\n", .{ sk[0], sk[1] });
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
    try json.put(r.a, &p, "position", try json.from(r.a, .{
        .line = (r.s.debug_line orelse 1) - 1,
        .character = (r.s.debug_char orelse 1) - 1,
    }));
    return p;
}

fn checkRequestParams(r: *Req, loc_needed: bool) !void {
    _ = try ensureFileAccessible(r.a, r.io, r.o, r.s.debug_filepath);
    if (loc_needed) {
        const line = r.s.debug_line orelse return fail(r.a, "'debug_line' not specified for debug request", .{});
        r.o.print("  Line = {d}\n", .{line});
        const char = r.s.debug_char orelse return fail(r.a, "'debug_char' not specified for debug request", .{});
        r.o.print("  Char = {d}\n\n", .{char});
    }
}

fn save(r: *Req) !void {
    _ = try r.server.serveOnSave(r.a, try textDoc(r.a, r.s.debug_filepath.?), false, false);
}

fn printResults(r: *Req, results: Value, comptime fmtFn: fn (*Req, Value) anyerror!void) !void {
    if (results == .null) {
        r.o.print("    No result found!\n", .{});
        return;
    }
    if (r.s.debug_full_result) {
        var buf: std.ArrayList(u8) = .empty;
        try json.writePretty(&buf, r.a, results, 0);
        r.o.print("{s}\n", .{buf.items});
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
        if (!paths.isDir(io, rp)) return fail(a, "'debug_rootpath' not specified for debug request", .{});
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
                if (res.items().len == 0) {
                    rq.o.print("No errors or warnings\n", .{});
                } else rq.o.print("Reported Diagnostics:\n", .{});
                for (res.items()) |d| {
                    const sline = (d.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse 0;
                    const sev = (d.get("severity") orelse json.null_value).asInt() orelse 1;
                    const msg = (d.get("message") orelse json.null_value).asStr() orelse "";
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
                for (res.items()) |sym| {
                    const sline = (sym.path(&.{ "location", "range", "start", "line" }) orelse json.null_value).asInt() orelse 0;
                    const parent = if (sym.get("containerName")) |c| c.asStr() orelse "null" else "null";
                    const kind = (sym.get("kind") orelse json.null_value).asInt() orelse 0;
                    const name = (sym.get("name") orelse json.null_value).asStr() orelse "";
                    rq.o.print("  line {d:>5}  symbol -> {d:>3}:{s:<30} parent = {s}\n", .{ sline, kind, name, parent });
                }
            }
        }.f);
        separator(o);
    }
    if (s.debug_workspace_symbols) |_| {
        try generic(&r, "workspace/symbol", false, struct {
            fn req(rq: *Req) !Value {
                if (rq.s.debug_rootpath == null) return fail(rq.a, "'debug_rootpath' not specified for debug request", .{});
                return rq.server.dispatchPublic(rq.a, "workspace/symbol", try json.from(rq.a, .{ .query = rq.s.debug_workspace_symbols.? }));
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (res.items()) |sym| {
                    const uri = (sym.path(&.{ "location", "uri" }) orelse json.null_value).asStr() orelse "";
                    const path = try paths.pathFromUri(rq.io, rq.a, uri);
                    const sline = (sym.path(&.{ "location", "range", "start", "line" }) orelse json.null_value).asInt() orelse 0;
                    const parent = if (sym.get("containerName")) |c| c.asStr() orelse "null" else "null";
                    const name = (sym.get("name") orelse json.null_value).asStr() orelse "";
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
                for (res.items()) |item| {
                    const kind = (item.get("kind") orelse json.null_value).asInt() orelse 0;
                    const label = (item.get("label") orelse json.null_value).asStr() orelse "";
                    const detail = (item.get("detail") orelse json.null_value).asStr() orelse "";
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
                const contents = res.get("contents") orelse json.null_value;
                if (contents == .object) {
                    rq.o.print("{s}\n", .{(contents.get("value") orelse json.null_value).asStr() orelse ""});
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
                const active_param = (res.get("activeParameter") orelse json.integer(0)).asInt() orelse 0;
                rq.o.print("    Active param = {d}\n", .{active_param});
                const active_sig = (res.get("activeSignature") orelse json.integer(0)).asInt() orelse 0;
                rq.o.print("    Active sig   = {d}\n", .{active_sig});
                for ((res.get("signatures") orelse json.null_value).items(), 0..) |sig, i| {
                    rq.o.print("    {s}\n", .{(sig.get("label") orelse json.null_value).asStr() orelse ""});
                    for ((sig.get("parameters") orelse json.null_value).items(), 0..) |p, j| {
                        const mark: []const u8 = if (i == active_sig and j == active_param) "*" else " ";
                        const label = (p.get("label") orelse json.null_value).asStr() orelse "";
                        if (p.get("documentation")) |d| {
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
                for (res.items()) |loc| {
                    const uri = (loc.get("uri") orelse json.null_value).asStr() orelse "";
                    const line = (loc.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse 0;
                    const char = (loc.path(&.{ "range", "start", "character" }) orelse json.null_value).asInt() orelse 0;
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
                try json.put(rq.a, &p, "newName", json.string(rq.s.debug_rename.?));
                return rq.server.dispatchPublic(rq.a, "textDocument/rename", p);
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                const changes = res.get("changes") orelse return;
                if (changes != .object) return;
                for (changes.object.entries.items) |e| {
                    const path = try paths.pathFromUri(rq.io, rq.a, e.key);
                    const file = rq.server.workspace.get(path) orelse {
                        rq.o.print("Unknown file: \"{s}\"\n", .{path});
                        continue;
                    };
                    try processFileChanges(rq, path, e.value, file);
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
                try json.put(rq.a, &p, "range", try json.from(rq.a, .{
                    .start = .{ .line = line, .character = char },
                    .end = .{ .line = line, .character = char },
                }));
                return rq.server.dispatchPublic(rq.a, "textDocument/codeAction", p);
            }
        }.req, struct {
            fn f(rq: *Req, res: Value) !void {
                for (res.items()) |act| {
                    rq.o.print("Kind = '{s}', Title = '{s}'\n", .{
                        (act.get("kind") orelse json.null_value).asStr() orelse "",
                        (act.get("title") orelse json.null_value).asStr() orelse "",
                    });
                    const changes = act.path(&.{ "edit", "changes" }) orelse continue;
                    if (changes != .object) continue;
                    for (changes.object.entries.items) |e| {
                        rq.o.print("\nChange: URI = '{s}'\n", .{e.key});
                        var buf: std.ArrayList(u8) = .empty;
                        try json.writePretty(&buf, rq.a, e.value, 0);
                        rq.o.print("{s}\n", .{buf.items});
                    }
                    rq.o.print("\n", .{});
                }
            }
        }.f);
        separator(o);
    }
}

fn printLocation(rq: *Req, res: Value) !void {
    rq.o.print("    URI  = \"{s}\"\n", .{(res.get("uri") orelse json.null_value).asStr() orelse ""});
    rq.o.print("    Line = {d}\n", .{((res.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse 0) + 1});
    rq.o.print("    Char = {d}\n", .{((res.path(&.{ "range", "start", "character" }) orelse json.null_value).asInt() orelse 0) + 1});
}

fn processFileChanges(rq: *Req, path: []const u8, changes: Value, file: *parser.FortranFile) !void {
    rq.o.print("File: \"{s}\"\n", .{path});
    for (changes.items()) |change| {
        const sl = (change.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse 0;
        const el = (change.path(&.{ "range", "end", "line" }) orelse json.null_value).asInt() orelse 0;
        const sc = (change.path(&.{ "range", "start", "character" }) orelse json.null_value).asInt() orelse 0;
        const ec = (change.path(&.{ "range", "end", "character" }) orelse json.null_value).asInt() orelse 0;
        const new_text = (change.get("newText") orelse json.null_value).asStr() orelse "";
        rq.o.print("  {d}, {d}\n", .{ sl + 1, el + 1 });
        var new_contents: std.ArrayList([]const u8) = .empty;
        var i = sl;
        while (i <= el) : (i += 1) {
            const line = file.getLine(i, false) orelse "";
            rq.o.print("  - {s}\n", .{line});
            var content: []const u8 = line;
            if (i == sl) content = try std.mem.concat(rq.a, u8, &.{ line[0..str.utf16ToByte(line, @intCast(@max(sc, 0)))], new_text });
            if (i == el) content = try std.mem.concat(rq.a, u8, &.{ content, str.from(line, str.utf16ToByte(line, @intCast(@max(ec, 0)))) });
            try new_contents.append(rq.a, content);
        }
        for (new_contents.items) |l| rq.o.print("  + {s}\n", .{l});
        rq.o.print("\n", .{});
    }
}
