//! Reading a configuration file's text: TOML (`.zflsrc`) or JSON5
//! (`.fortlsrc`, `.fortls.json`, `.fortls`, the user's `config.json`),
//! told by the content. Both give the same JSON object of options, under
//! the names of the command line's. A TOML file is also checked: a key that
//! is no option, or a value of the wrong type, is a warning.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const json5 = @import("../json5.zig");
const toml = @import("../toml.zig");
const settings = @import("../settings.zig");
const paths = @import("../paths.zig");

pub const Found = struct { name: []const u8, path: []const u8 };

/// The configuration file of the project at `root`: the first of the names
/// (`config`, the one of `-c`, then the defaults) that is a file
pub fn find(a: Allocator, io: std.Io, root: []const u8, config: []const u8) Allocator.Error!?Found {
    for (settings.configFileNames(config)) |name| {
        const p = try paths.join(a, &.{ root, name });
        if (paths.isFile(io, p)) return .{ .name = name, .path = p };
    }
    return null;
}

pub const Format = enum { json5, toml };

/// What the text is written in: a file whose first token is a comment of
/// JSON5 or a brace is JSON5, any other with a token is TOML; a file with
/// none (empty) is left to JSON5, which says so
pub fn formatOf(text: []const u8) Format {
    var rest = text;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    for (rest) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        '/', '{' => return .json5,
        else => return .toml,
    };
    return .json5;
}

pub const Loaded = struct {
    cfg: json.Value,
    format: Format,
    /// The warnings of a TOML file, one line each
    problems: []const []const u8 = &.{},
};

/// The options of `text` (`name` is the file, for messages): the object in
/// `a`, or the message of an error, which is `scratch`'s
pub const Result = union(enum) { ok: Loaded, err: []const u8 };

pub fn parse(a: Allocator, scratch: Allocator, text: []const u8, name: []const u8) Allocator.Error!Result {
    // an empty `.zflsrc` is a TOML file of no options (#990); fortls's
    // JSON files say they are empty
    if (std.mem.eql(u8, std.Io.Dir.path.basename(name), ".zflsrc") and std.mem.trim(u8, text, " \t\r\n\xEF\xBB\xBF").len == 0)
        return .{ .ok = .{ .cfg = .{ .object = .empty }, .format = .toml } };
    const format = formatOf(text);
    var cfg: json.Value = undefined;
    switch (format) {
        .json5 => {
            var p: json5.Parser = .{ .a = a, .src = text };
            cfg = p.parseDocument() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SyntaxError => return .{ .err = try scratch.print("Error: \"{s}\" while reading \"{s}\" Configuration file", .{ try settings.json5ErrorMessage(scratch, text, p.err_pos), name }) },
            };
        },
        .toml => {
            var p: toml.Parser = .{ .a = a, .src = text };
            cfg = p.parseDocument() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SyntaxError => {
                    const at = p.errLocation();
                    return .{ .err = try scratch.print("Error: \"{d}:{d} {s}\" while reading \"{s}\" Configuration file", .{ at.line, at.col, p.err_msg, name }) };
                },
            };
        },
    }
    if (cfg != .object) return .{ .err = try scratch.print("Error: \"<string>:1 Unexpected value\" while reading \"{s}\" Configuration file", .{name}) };
    return .{ .ok = .{ .cfg = cfg, .format = format, .problems = if (format == .toml) try check(scratch, cfg) else &.{} } };
}

/// The option `key` is: one the command line has, but not the ones of a
/// file's own business or the debug requests'
pub fn option(key: []const u8) ?*const settings.Opt {
    for (&settings.opts) |*o| {
        if (!std.mem.eql(u8, o.long, key)) continue;
        return switch (o.kind) {
            .help, .debug_help, .version => null,
            else => if (o.debug or std.mem.eql(u8, o.long, "config")) null else o,
        };
    }
    return null;
}

/// Whether `v` is what option `o` takes
fn typeFits(o: *const settings.Opt, v: json.Value) bool {
    const args = std.mem.endsWith(u8, o.long, "_args");
    return switch (o.kind) {
        .flag => v == .bool,
        .int => v == .integer,
        .string => v == .string or (args and v == .array),
        .list => v == .array,
        .json => v == .object or (std.mem.eql(u8, o.long, "pp_defs") and v == .array),
        else => false,
    };
}

fn typeName(o: *const settings.Opt) []const u8 {
    return switch (o.kind) {
        .flag => "true or false",
        .int => "an integer",
        .string => if (std.mem.endsWith(u8, o.long, "_args")) "a string or an array of strings" else "a string",
        .list => "an array of strings",
        .json => "a table",
        else => "another value",
    };
}

/// The problems of the options in `cfg`
fn check(a: Allocator, cfg: json.Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cfg.object.keys(), cfg.object.values()) |k, v| {
        if (std.mem.eql(u8, k, "$schema")) continue;
        const o = option(k) orelse {
            try out.append(a, try a.print("unknown option {s}", .{k}));
            continue;
        };
        if (!typeFits(o, v)) try out.append(a, try a.print("{s} takes {s}", .{ k, typeName(o) }));
    }
    return out.items;
}

test "the format is told by the first token" {
    try std.testing.expectEqual(Format.json5, formatOf("{\"nthreads\": 2}"));
    try std.testing.expectEqual(Format.json5, formatOf("\n  // c\n{}"));
    try std.testing.expectEqual(Format.json5, formatOf("/* c */ {}"));
    try std.testing.expectEqual(Format.json5, formatOf(""));
    try std.testing.expectEqual(Format.toml, formatOf("# c\nnthreads = 2"));
    try std.testing.expectEqual(Format.toml, formatOf("\xEF\xBB\xBFnthreads = 2"));
    try std.testing.expectEqual(Format.toml, formatOf("[pp_defs]\nA = 1"));
}

test "a TOML file gives the options, and warns of what is not one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a, a, "nthreads = 3\nsource_dirs = [\"src\"]\nnthread = 2\nnotify_init = 1\n[pp_defs]\nA = 1\n", ".zflsrc");
    try std.testing.expectEqual(@as(i64, 3), json.int(json.get(r.ok.cfg, "nthreads")).?);
    try std.testing.expectEqual(@as(usize, 2), r.ok.problems.len);
    try std.testing.expectEqualStrings("unknown option nthread", r.ok.problems[0]);
    try std.testing.expectEqualStrings("notify_init takes true or false", r.ok.problems[1]);
}

test "errors name the file and the place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try parse(a, a, "nthreads = \n", ".zflsrc");
    try std.testing.expectEqualStrings("Error: \"1:12 expected a value\" while reading \".zflsrc\" Configuration file", t.err);
    const j = try parse(a, a, "{\"nthreads\": tru }", ".fortlsrc");
    try std.testing.expect(std.mem.startsWith(u8, j.err, "Error: \"<string>:1 Unexpected"));
    const w = try parse(a, a, "[1, 2]", ".fortlsrc");
    try std.testing.expect(w == .err);
}

test "an empty .zflsrc is no options; an empty .fortlsrc an error (#990)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "\n\n", "\xEF\xBB\xBF" }) |text| {
        const r = try parse(a, a, text, "/w/.zflsrc");
        try std.testing.expectEqual(@as(usize, 0), r.ok.cfg.object.count());
    }
    try std.testing.expect((try parse(a, a, "", "/w/.fortlsrc")) == .err);
}
