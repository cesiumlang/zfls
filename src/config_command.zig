//! `zfls config [--root DIR] [OPTIONS]`: prints the options in effect for
//! the project at DIR (default: the current directory) and where each
//! came from: the defaults, the command line's OPTIONS, the user's
//! configuration file, the project's configuration file (`.zflsrc` or a
//! fortls name). What an editor sends (`initializationOptions`) is not
//! known here, and fpm.toml and compile_commands.json add include
//! directories and definitions when the server indexes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("json.zig");
const fsio = @import("fsio.zig");
const paths = @import("paths.zig");
const stdio = @import("stdio.zig");
const settings = @import("settings.zig");
const config_file = @import("settings/config_file.zig");
const workspace_file = @import("settings/workspace_file.zig");

const usage = "usage: zfls config [--root DIR] [options of the server]\n";

/// A configuration file read
pub const Input = struct { name: []const u8, text: []const u8 };

/// The options in effect, one `name = value  # source` line each, over the
/// command line's `cli`, the user's file and the project's
pub fn report(a: Allocator, cli: settings.Settings, user: ?Input, project: ?Input) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var merged = try settings.clone(a, cli);
    var sources: std.StringHashMapUnmanaged([]const u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    const defaults: settings.Settings = .{};
    try out.print(a, "# zfls options in effect\n# user file: {s}\n# project file: {s}\n", .{ if (user) |u| u.name else "none", if (project) |p| p.name else "none" });
    for (&settings.opts) |*o| {
        if (config_file.option(o.long) == null) continue;
        inline for (@typeInfo(settings.Settings).@"struct".field_names) |f| {
            if (std.mem.eql(u8, f, o.long) and !settings.sameValue(&defaults, &cli, f)) try sources.put(a, f, "command line");
        }
    }
    for ([_]?Input{ user, project }, 0..) |maybe, layer| {
        const in = maybe orelse continue;
        switch (try config_file.parse(a, a, in.text, in.name)) {
            .err => |msg| try notes.append(a, msg),
            .ok => |loaded| {
                for (loaded.problems) |p| try notes.append(a, try a.print("{s}: {s}", .{ in.name, p }));
                var ignored: std.ArrayList([]const u8) = .empty;
                if (layer == 0) try settings.applyConfig(a, &merged, loaded.cfg) else try workspace_file.apply(a, &merged, loaded.cfg, &ignored);
                for (loaded.cfg.object.keys()) |k| {
                    if (layer == 1 and isIn(ignored.items, k)) continue;
                    if (config_file.option(k) != null) try sources.put(a, k, if (layer == 0) "user file" else in.name);
                }
                for (ignored.items) |k| try notes.append(a, try a.print("{s}: {s} is not read from a project's file; set it in the user file or on the command line", .{ in.name, k }));
            },
        }
    }
    const values = (try settings.toJson(a, &merged)).object;
    for (&settings.opts) |*o| {
        if (config_file.option(o.long) == null) continue;
        const v = values.get(o.long) orelse continue;
        if (v == .null) {
            try out.print(a, "# {s} is not set  # {s}\n", .{ o.long, sources.get(o.long) orelse "default" });
            continue;
        }
        try out.print(a, "{s} = ", .{o.long});
        try writeToml(a, &out, v);
        try out.print(a, "  # {s}\n", .{sources.get(o.long) orelse "default"});
    }
    for (notes.items) |n| try out.print(a, "# warning: {s}\n", .{n});
    return out.items;
}

fn isIn(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// `v` as a TOML value
fn writeToml(a: Allocator, out: *std.ArrayList(u8), v: json.Value) Allocator.Error!void {
    switch (v) {
        .array => |items| {
            try out.append(a, '[');
            for (items.items, 0..) |x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeToml(a, out, x);
            }
            try out.append(a, ']');
        },
        .object => |m| {
            try out.appendSlice(a, "{ ");
            for (m.keys(), m.values(), 0..) |k, x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.print(a, "{s} = ", .{try json.stringify(a, .{ .string = k })});
                try writeToml(a, out, x);
            }
            try out.appendSlice(a, if (m.count() == 0) "}" else " }");
        },
        else => try out.appendSlice(a, try json.stringify(a, v)),
    }
}

/// Runs the command: its exit code
pub fn run(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            i += 1;
            root = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--root=")) {
            root = args[i]["--root=".len..];
        } else try rest.append(a, args[i]);
    }
    const cli = switch (try settings.parseArgs(a, rest.items, "")) {
        .run => |s| s,
        .exit_ok => |text| {
            try stdio.stdout().writeStreamingAll(io, text);
            return 0;
        },
        .exit_err => {
            try stdio.stderr().writeStreamingAll(io, usage);
            return 2;
        },
    };
    const dir = try paths.abspath(a, root orelse paths.getCwd());
    var user: ?Input = null;
    if (paths.userConfigFile()) |u| if (fsio.readFile(io, a, u, .limited(1 << 26))) |text| {
        user = .{ .name = u, .text = text };
    } else |_| {};
    var project: ?Input = null;
    if (try config_file.find(a, io, dir, cli.config)) |f| if (fsio.readFile(io, a, f.path, .limited(1 << 26))) |text| {
        project = .{ .name = f.name, .text = text };
    } else |_| {};
    try stdio.stdout().writeStreamingAll(io, try report(a, cli, user, project));
    return 0;
}

test "the options in effect and where each came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cli = (try settings.parseArgs(a, &.{ "--nthreads", "2", "--lowercase_hover" }, "")).run;
    const text = try report(a, cli, .{ .name = "config.json", .text = "{\"nthreads\": 3, \"source_dirs\": [\"u\"], \"compiler_path\": \"/u/gfortran\"}" }, .{ .name = ".zflsrc", .text = "source_dirs = [\"src\"]\ncompiler_path = \"./x\"\nbogus = 1\n[pp_defs]\nA = \"1\"\n" });
    const has = struct {
        fn in(t: []const u8, line: []const u8) bool {
            return std.mem.find(u8, t, line) != null;
        }
    }.in;
    try std.testing.expect(has(text, "nthreads = 3  # user file\n"));
    try std.testing.expect(has(text, "lowercase_hover = true  # command line\n"));
    try std.testing.expect(has(text, "source_dirs = [\"src\"]  # .zflsrc\n"));
    try std.testing.expect(has(text, "compiler_path = \"/u/gfortran\"  # user file\n"));
    try std.testing.expect(has(text, "pp_defs = { \"A\" = \"1\" }  # .zflsrc\n"));
    try std.testing.expect(has(text, "sort_keywords = false  # default\n"));
    try std.testing.expect(has(text, "# compiler_diagnostics is not set  # default\n"));
    try std.testing.expect(has(text, "# warning: .zflsrc: unknown option bogus\n"));
    try std.testing.expect(has(text, "# warning: .zflsrc: compiler_path is not read from a project's file"));
}
