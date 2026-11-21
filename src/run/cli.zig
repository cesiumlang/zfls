//! `zfls build-command FILE [--compiler C] [--compiler-path P]
//! [--output-dir D] [--kit DIR] [-- ARGS...]`: `zfls/buildCommand`'s answer
//! as JSON on standard output, for scripts and editors that do not send
//! zfls's own requests. `--kit`: zfls's ifx kit, when it is not next to
//! zfls.

const std = @import("std");
const json = @import("../json.zig");
const paths = @import("../paths.zig");
const stdio = @import("../stdio.zig");
const command = @import("command.zig");
const kit = @import("kit.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const usage = "usage: zfls build-command FILE [--compiler C] [--compiler-path P] [--output-dir D] [-- ARGS...]\n";

/// Runs it: its exit code
pub fn run(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r: command.Request = .{};
    var file: ?[]const u8 = null;
    var kit_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = i + 1 < args.len;
        if (std.mem.eql(u8, arg, "--")) {
            r.args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--compiler") and value) {
            i += 1;
            r.compiler = args[i];
        } else if (std.mem.eql(u8, arg, "--compiler-path") and value) {
            i += 1;
            r.compiler_path = args[i];
        } else if (std.mem.eql(u8, arg, "--output-dir") and value) {
            i += 1;
            r.output_dir = try paths.abspath(a, args[i]);
        } else if (std.mem.eql(u8, arg, "--kit") and value) {
            i += 1;
            kit_dir = try paths.abspath(a, args[i]);
        } else if (file == null and !std.mem.startsWith(u8, arg, "-")) {
            file = arg;
        } else {
            try stdio.stderr().writeStreamingAll(io, usage);
            return 2;
        }
    }
    r.source = try paths.abspath(a, file orelse {
        try stdio.stderr().writeStreamingAll(io, usage);
        return 2;
    });
    r.base_dir = paths.getCwd();
    const answer = try command.plan(a, .{
        .io = io,
        .env = environ,
        .base_env = environ,
        .cache_dir = paths.cacheDir(),
        .kit_dir = kit_dir orelse try kit.find(a, io),
    }, r) orelse {
        try stdio.stderr().writeStreamingAll(io, try a.print("zfls build-command: the compiler {s} was not found\n", .{r.compiler}));
        return 1;
    };
    const text = try json.pretty(a, try json.from(a, answer));
    try stdio.stdout().writeStreamingAll(io, try a.print("{s}\n", .{text}));
    return 0;
}
