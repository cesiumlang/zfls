//! A Fortran file built with the command that `zfls build-command`
//! answers, and its program run with the answered environment: gfortran
//! by default, LLVM Flang, ifx or another with --compiler (on Windows x64
//! linked with the ifx kit of --kit; ifx's own modules found, as
//! conda-forge's does not) (`zig build test-build-command`). Skipped
//! without the compiler.
//!
//!     build_command --zfls ZFLS [--compiler C] [--kit DIR]

const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const source =
    \\module greeting
    \\  implicit none
    \\contains
    \\  subroutine greet()
    \\    use, intrinsic :: iso_fortran_env, only: output_unit
    \\    write (output_unit, '(a)') 'hello from zfls build-command'
    \\  end subroutine greet
    \\end module greeting
    \\
    \\program hello
    \\  use greeting
    \\  call greet()
    \\end program hello
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var compiler: []const u8 = "gfortran";
    var kit: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--compiler")) {
            compiler = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--kit")) {
            kit = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: build_command --zfls ZFLS [--compiler C] [--kit DIR]\n", .{});
        return 2;
    }

    const dir = try a.print(".zig-cache/tmp/build-command-{s}", .{std.Io.Dir.path.stem(compiler)});
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const file = try std.Io.Dir.path.join(a, &.{ dir, "hello.f90" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = source });

    var cmd: std.ArrayList([]const u8) = .empty;
    try cmd.appendSlice(a, &.{ zfls_exe.?, "build-command", file, "--compiler", compiler, "--output-dir", try std.Io.Dir.path.join(a, &.{ dir, "out" }) });
    if (kit) |k| try cmd.appendSlice(a, &.{ "--kit", k });
    const answered = try std.process.run(a, io, .{ .argv = cmd.items });
    if (!answered.term.success()) {
        if (std.mem.find(u8, answered.stderr, "was not found") != null) {
            std.debug.print("skipped: no {s}\n", .{compiler});
            return 0;
        }
        std.debug.print("FAIL zfls build-command: {s}\n", .{answered.stderr});
        return 1;
    }
    const answer = try json.parseFromSliceLeaky(json.Value, a, answered.stdout, .{});
    std.debug.print("{s}\n", .{answered.stdout});

    // the build, in its directory, with its environment
    var build_argv: std.ArrayList([]const u8) = .empty;
    try build_argv.append(a, str(answer, "compiler"));
    for (answer.object.get("args").?.array.items) |arg| try build_argv.append(a, arg.string);
    const build_env = try withVars(a, init.environ_map, answer.object.get("env").?);
    const built = try std.process.run(a, io, .{ .argv = build_argv.items, .cwd = .{ .path = str(answer, "cwd") }, .environ_map = &build_env });
    if (!built.term.success()) {
        std.debug.print("FAIL the build: {s}{s}\n", .{ built.stdout, built.stderr });
        return 1;
    }

    // the program, with its environment
    const run_env = try withVars(a, init.environ_map, answer.object.get("runEnv").?);
    const ran = try std.process.run(a, io, .{ .argv = &.{str(answer, "program")}, .environ_map = &run_env });
    if (!ran.term.success() or std.mem.find(u8, ran.stdout, "hello from zfls build-command") == null) {
        std.debug.print("FAIL the program: {s}{s}\n", .{ ran.stdout, ran.stderr });
        return 1;
    }
    const debugger = str(answer, "debugger");
    for ([_][]const u8{ "gdb", "lldb", "dbgeng" }) |d| {
        if (std.mem.eql(u8, d, debugger)) break;
    } else {
        std.debug.print("FAIL no debugger of zfls dap: {s}\n", .{debugger});
        return 1;
    }
    std.debug.print("ok   {s} built hello.f90 and its program ran ({s}, {s})\n", .{ compiler, str(answer, "debugInfo"), debugger });
    return 0;
}

fn str(v: json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

/// `base` with the variables of a JSON object
fn withVars(a: Allocator, base: *const std.process.Environ.Map, vars: json.Value) !std.process.Environ.Map {
    var env = try base.clone(a);
    var it = vars.object.iterator();
    while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.string);
    return env;
}
