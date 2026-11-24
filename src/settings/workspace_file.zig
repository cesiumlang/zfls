//! The settings of a workspace's own configuration file (`.fortlsrc`,
//! `.fortls`, `.fortls.json`). A repository can ship that file, so what it
//! says never chooses a program zfls runs: those settings are read only
//! from the user's configuration file, the command line and the editor.
//! The flags it gives a compiler or fypp are filtered to an allow-list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const settings = @import("../settings.zig");
const compile_flags = @import("../compile_flags.zig");

/// The settings that name a program (or a directory that holds it)
pub const program_keys = [_][]const u8{
    "compiler_path", "compiler_path_fixed", "compiler_fypp", "bind_c_clangd", "formatter_path", "fortitude_path", "codee_path",
};

/// Flags of fypp that stay: the include directories and definitions
const fypp_flags = [_][]const u8{ "-I", "-D", "-U" };

/// `args` as a command's flags that pass `compile_flags`, a placeholder in
/// the place of the compiler
fn compilerFlags(a: Allocator, args: []const []const u8) ![]const []const u8 {
    var with_exe: std.ArrayList([]const u8) = .empty;
    try with_exe.append(a, "");
    try with_exe.appendSlice(a, args);
    return (try compile_flags.safeArgs(a, with_exe.items))[1..];
}

/// fypp's `-I` and `-D` (and `-U`) options, attached or with the value as
/// the next argument
fn fyppFlags(a: Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        for (fypp_flags) |f| {
            if (!std.mem.startsWith(u8, x, f)) continue;
            try out.append(a, x);
            if (x.len == f.len and i + 1 < args.len) {
                i += 1;
                try out.append(a, args[i]);
            }
            break;
        }
    }
    return out.items;
}

const Filter = *const fn (Allocator, []const []const u8) anyerror![]const []const u8;

/// Applies `cfg`, the workspace's file, to `s`, leaving out the settings of
/// `program_keys` and the flags that are not allowed (`compiler_args`,
/// `compiler_args_fixed`, `compiler_fypp_args`). The names of the settings
/// changed that way are added to `ignored`.
pub fn apply(a: Allocator, s: *settings.Settings, cfg: json.Value, ignored: *std.ArrayList([]const u8)) !void {
    if (cfg != .object) return settings.applyConfig(a, s, cfg);
    var out: json.ObjectMap = .empty;
    var it = cfg.object.iterator();
    next: while (it.next()) |e| {
        for (program_keys) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) {
            try ignored.append(a, k);
            continue :next;
        };
        const filters = [_]struct { []const u8, Filter }{
            .{ "compiler_args", compilerFlags },
            .{ "compiler_args_fixed", compilerFlags },
            .{ "compiler_fypp_args", fyppFlags },
        };
        for (filters) |f| if (std.mem.eql(u8, f[0], e.key_ptr.*)) {
            const list = (try settings.argList(a, e.value_ptr.*)) orelse break;
            const kept = try f[1](a, list.slice());
            if (kept.len != list.len()) try ignored.append(a, f[0]);
            try out.put(a, f[0], try json.from(a, kept));
            continue :next;
        };
        try out.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    try settings.applyConfig(a, s, .{ .object = out });
}

test "a workspace's file does not choose the programs that run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try json.parse(a,
        \\{"compiler_diagnostics": "gfortran", "compiler_path": "./x", "compiler_path_fixed": "./x", "compiler_fypp": "./f",
        \\ "bind_c_clangd": "./c", "formatter_path": "./p", "fortitude_path": "./p", "codee_path": "./p",
        \\ "compiler_args": ["-Wall", "-wrapper", "a,b", "-Iinc"], "compiler_fypp_args": ["-Iinc", "-m", "os", "-DX=1"],
        \\ "formatter": "findent"}
    );
    var s: settings.Settings = .{};
    var ignored: std.ArrayList([]const u8) = .empty;
    try apply(a, &s, cfg, &ignored);
    try std.testing.expectEqualStrings("gfortran", s.compiler_diagnostics.?);
    try std.testing.expectEqualStrings("findent", s.formatter.?);
    try std.testing.expect(s.compiler_path == null and s.compiler_path_fixed == null and s.compiler_fypp == null);
    try std.testing.expect(s.bind_c_clangd == null and s.formatter_path == null and s.fortitude_path == null and s.codee_path == null);
    try std.testing.expectEqual(@as(usize, 9), ignored.items.len);
    const args = s.compiler_args.?.slice();
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("-Wall", args[0]);
    try std.testing.expectEqualStrings("-Iinc", args[1]);
    const fypp = s.compiler_fypp_args.slice();
    try std.testing.expectEqual(@as(usize, 2), fypp.len);
    try std.testing.expectEqualStrings("-DX=1", fypp[1]);
}

test "the settings of another source keep the programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: settings.Settings = .{};
    try settings.applyConfig(a, &s, try json.parse(a, "{\"compiler_path\": \"/opt/gfortran\"}"));
    try std.testing.expectEqualStrings("/opt/gfortran", s.compiler_path.?);
}
