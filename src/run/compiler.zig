//! How Run and Debug Fortran File build a program with a compiler: the
//! style of its options, its default options for a debug build, and the
//! debug information its programs have, per platform.

const std = @import("std");
const compilers = @import("../compilers.zig");
const debugger = @import("debugger.zig");
const Allocator = std.mem.Allocator;
const Os = std.Target.Os.Tag;

/// How a compiler takes its options
pub const Style = enum { gnu, intel_windows };

pub const Kind = struct {
    style: Style,
    debug_info: debugger.DebugInfo,
    /// The options when the user gives none: debug information, no
    /// optimization
    default_args: []const []const u8,
};

const gnu_debug = [_][]const u8{ "-g", "-O0" };

/// LLVM Flang's debug build on Windows: `-gdwarf-4` writes DWARF besides
/// Microsoft's debug information and links with lld-link, which
/// `-debug:dwarf` has keep it in the program (and still write the PDB)
pub const flang_dwarf_args = [_][]const u8{ "-gdwarf-4", "-O0", "-Wl,-debug:dwarf" };

/// MinGW's gfortran: its runtime linked in, since gdb reads no symbols of
/// libgfortran-5.dll and so cannot stop at the errors raised inside it
/// (`RANDOM_SEED`, `MATMUL`, I/O)
pub const gfortran_windows_args = [_][]const u8{ "-g", "-O0", "-static-libgfortran", "-static-libquadmath" };

/// How compiler `id` (null: one zfls does not know) builds on `os`.
/// `flang_dwarf`: LLVM Flang on Windows links with lld-link, so its
/// programs can have DWARF, for gdb; else they have Microsoft's debug
/// information only, for Windows's Debugger Engine.
pub fn kind(id: ?compilers.Id, os: Os, flang_dwarf: bool) Kind {
    const gnu: Kind = .{ .style = .gnu, .debug_info = .dwarf, .default_args = &gnu_debug };
    if (os != .windows) return switch (id orelse return gnu) {
        .lfortran => .{ .style = .gnu, .debug_info = .dwarf, .default_args = &.{"-g"} },
        else => gnu,
    };
    return switch (id orelse return gnu) {
        .ifx, .ifort => .{ .style = .intel_windows, .debug_info = .pdb, .default_args = &.{ "/Zi", "/Od" } },
        // conda-forge's LFortran for Windows is built without its runtime
        // stacktrace and refuses -g
        .lfortran => .{ .style = .gnu, .debug_info = .pdb, .default_args = &.{} },
        .flang => if (flang_dwarf)
            .{ .style = .gnu, .debug_info = .dwarf, .default_args = &flang_dwarf_args }
        else
            .{ .style = .gnu, .debug_info = .pdb, .default_args = &gnu_debug },
        .gfortran => .{ .style = .gnu, .debug_info = .dwarf, .default_args = &gfortran_windows_args },
        .nvfortran, .nagfor => gnu,
    };
}

/// The arguments that build `source` into `program`, run in the output
/// directory (where module and object files go): the user's (`user_args`,
/// else the kind's defaults), the linker's (`link_args`), the source's
/// directory on the include path, the program and the source
pub fn buildArgs(
    a: Allocator,
    k: Kind,
    source: []const u8,
    program: []const u8,
    user_args: ?[]const []const u8,
    link_args: []const []const u8,
) ![]const []const u8 {
    return argsOf(a, k, source, program, user_args, link_args, false);
}

/// The first of a build in two steps: as `buildArgs`, but compiling
/// `source` into the object file `object` only (`-c`)
pub fn compileArgs(
    a: Allocator,
    k: Kind,
    source: []const u8,
    object: []const u8,
    user_args: ?[]const []const u8,
    extra_args: []const []const u8,
) ![]const []const u8 {
    return argsOf(a, k, source, object, user_args, extra_args, true);
}

/// The second: `object` linked into `program`, with the user's options (or
/// the kind's defaults) and the linker's
pub fn linkArgs(
    a: Allocator,
    k: Kind,
    object: []const u8,
    program: []const u8,
    user_args: ?[]const []const u8,
    link_args: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (k.style == .intel_windows) try out.append(a, "/nologo");
    try out.appendSlice(a, user_args orelse k.default_args);
    try out.appendSlice(a, link_args);
    switch (k.style) {
        .intel_windows => try out.append(a, try a.print("/exe:{s}", .{program})),
        .gnu => try out.appendSlice(a, &.{ "-o", program }),
    }
    try out.append(a, object);
    return out.items;
}

fn argsOf(
    a: Allocator,
    k: Kind,
    source: []const u8,
    out_file: []const u8,
    user_args: ?[]const []const u8,
    extra_args: []const []const u8,
    compile_only: bool,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const dir = std.Io.Dir.path.dirname(source) orelse ".";
    if (k.style == .intel_windows) try out.append(a, "/nologo");
    try out.appendSlice(a, user_args orelse k.default_args);
    try out.appendSlice(a, extra_args);
    switch (k.style) {
        .intel_windows => {
            if (compile_only) try out.append(a, "/c");
            try out.appendSlice(a, &.{ try a.print("/I{s}", .{dir}), try a.print("/{s}{s}", .{ if (compile_only) "Fo" else "exe:", out_file }) });
        },
        .gnu => {
            if (compile_only) try out.append(a, "-c");
            try out.appendSlice(a, &.{ try a.print("-I{s}", .{dir}), "-o", out_file });
        },
    }
    try out.append(a, source);
    return out.items;
}

const testing = std.testing;

fn expectArgs(expected: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "the kinds of compilers" {
    try testing.expectEqualDeep(Kind{ .style = .intel_windows, .debug_info = .pdb, .default_args = &.{ "/Zi", "/Od" } }, kind(.ifx, .windows, true));
    try testing.expectEqualDeep(Kind{ .style = .gnu, .debug_info = .dwarf, .default_args = &gnu_debug }, kind(.ifx, .linux, true));
    try testing.expectEqual(.dwarf, kind(.gfortran, .windows, true).debug_info);
    // MinGW's gfortran: its runtime linked in, for gdb's stops in it
    try expectArgs(&gfortran_windows_args, kind(.gfortran, .windows, true).default_args);
    try expectArgs(&gnu_debug, kind(.gfortran, .linux, true).default_args);
    // LLVM Flang on Windows: DWARF for gdb, kept by lld-link; without an
    // lld-link, Microsoft's debug information only
    try testing.expectEqualDeep(Kind{ .style = .gnu, .debug_info = .dwarf, .default_args = &flang_dwarf_args }, kind(.flang, .windows, true));
    try testing.expectEqualDeep(Kind{ .style = .gnu, .debug_info = .pdb, .default_args = &gnu_debug }, kind(.flang, .windows, false));
    try testing.expectEqualDeep(Kind{ .style = .gnu, .debug_info = .dwarf, .default_args = &gnu_debug }, kind(.flang, .linux, true));
    try testing.expectEqual(.dwarf, kind(.flang, .macos, true).debug_info);
    try expectArgs(&.{"-g"}, kind(.lfortran, .linux, true).default_args);
    // LFortran for Windows refuses -g
    try expectArgs(&.{}, kind(.lfortran, .windows, true).default_args);
    try testing.expectEqualDeep(Kind{ .style = .gnu, .debug_info = .dwarf, .default_args = &gnu_debug }, kind(null, .windows, true));
}

test "build arguments, GNU style" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gnu = kind(.gfortran, .linux, true);
    const src = try std.Io.Dir.path.join(a, &.{ "p", "src", "main.f90" });
    const dir = std.Io.Dir.path.dirname(src).?;
    const inc = try a.print("-I{s}", .{dir});
    try expectArgs(&.{ "-g", "-O0", inc, "-o", "out/main", src }, try buildArgs(a, gnu, src, "out/main", null, &.{}));
    try expectArgs(&.{ "-O2", "-fcheck=all", inc, "-o", "out/main", src }, try buildArgs(a, gnu, src, "out/main", &.{ "-O2", "-fcheck=all" }, &.{}));
    try expectArgs(&.{ inc, "-o", "out/main", src }, try buildArgs(a, gnu, src, "out/main", &.{}, &.{}));
    // the linker's after the build's, before the source
    const flang = kind(.flang, .windows, true);
    try expectArgs(&.{ "-gdwarf-4", "-O0", "-Wl,-debug:dwarf", "-fuse-ld=lld", inc, "-o", "a.exe", src }, try buildArgs(a, flang, src, "a.exe", null, &.{"-fuse-ld=lld"}));
}

test "build arguments, Intel on Windows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ "p q", "main.f90" });
    const dir = std.Io.Dir.path.dirname(src).?;
    try expectArgs(
        &.{ "/nologo", "/Zi", "/Od", try a.print("/I{s}", .{dir}), "/exe:out/main.exe", src },
        try buildArgs(a, kind(.ifx, .windows, true), src, "out/main.exe", null, &.{}),
    );
}

test "build arguments in two steps: compile, then link" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gnu = kind(.gfortran, .macos, true);
    const src = try std.Io.Dir.path.join(a, &.{ "p", "main.f90" });
    const inc = try a.print("-I{s}", .{std.Io.Dir.path.dirname(src).?});
    try expectArgs(&.{ "-g", "-O0", "-c", inc, "-o", "out/main.o", src }, try compileArgs(a, gnu, src, "out/main.o", null, &.{}));
    try expectArgs(&.{ "-g", "-O0", "-o", "out/main", "out/main.o" }, try linkArgs(a, gnu, "out/main.o", "out/main", null, &.{}));
    try expectArgs(&.{ "-O2", "-lblas", "-o", "out/main", "out/main.o" }, try linkArgs(a, gnu, "out/main.o", "out/main", &.{ "-O2", "-lblas" }, &.{}));
}
