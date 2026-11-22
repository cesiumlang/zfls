//! gdb's exception filters of C++ (`throw`, `rethrow`, `catch`), shown
//! only for a program that links a C++ runtime (libstdc++, libc++, MSVC's
//! `msvcp140.dll`), or with the configuration's `cppExceptionFilters: true`
//! (#747): `initialize` leaves them out, as it does Ada's, and a launch or
//! attach that wants them gives them back in a `capabilities` event (the
//! client has the filters before it has the program).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const Session = @import("session.zig").Session;
const gdb_entry = @import("gdb_entry.zig");

/// gdb's filters of C++
pub const names = [_][]const u8{ "throw", "rethrow", "catch" };

pub fn isCpp(filter: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, filter)) return true;
    return false;
}

/// What a program's file has when it links a C++ runtime: the library's
/// name (a DLL's import, an ELF's `DT_NEEDED`, a Mach-O's load command), or
/// the runtime's throw (statically linked)
const runtime_marks = [_][]const u8{ "libstdc++-6.dll", "libstdc++.so.6", "libc++.so.1", "libc++.1.dylib", "libc++.dll", "msvcp140.dll", "MSVCP140.dll", "__cxa_throw" };

/// Whether the program at `path` links a C++ runtime
pub fn linksCpp(io: Io, path: []const u8) bool {
    for (runtime_marks) |m| if (gdb_entry.programHas(io, path, m)) return true;
    return false;
}

/// Keeps gdb's C++ filters of `initialize`, which the client is not given
/// there
pub fn keep(s: *Session, a: Allocator, filters: []const Value) !void {
    if (s.g.cpp_filters.len > 0) s.gpa.free(s.g.cpp_filters);
    s.g.cpp_filters = "";
    s.g.cpp_shown = false;
    if (filters.len == 0) return;
    var list: json.Array = .init(a);
    try list.appendSlice(filters);
    s.g.cpp_filters = try s.gpa.dupe(u8, try json.stringify(a, .{ .array = list }));
}

/// At a launch or attach of the program `program`: the C++ filters for the
/// client when it links a C++ runtime or the configuration wants them
/// (`cppExceptionFilters: true`), else not, in a `capabilities` event when
/// that changes; `shown` the filters the client was given at `initialize`
pub fn atLaunch(s: *Session, a: Allocator, args: ?Value, program: ?[]const u8, shown: []const Value) !void {
    if (s.g.cpp_filters.len == 0) return;
    const forced = if (json.get(args, "cppExceptionFilters")) |v| v == .bool and v.bool else false;
    const want = forced or (if (program) |p| linksCpp(s.io, p) else false);
    if (want == s.g.cpp_shown) return;
    s.g.cpp_shown = want;
    var all: json.Array = .init(a);
    try all.appendSlice(shown);
    if (want) try all.appendSlice(json.items(try json.parse(a, s.g.cpp_filters)));
    s.event(a, "capabilities", .{ .capabilities = .{ .exceptionBreakpointFilters = Value{ .array = all } } });
}

test "a C++ runtime in a program's file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { []const u8, bool }{
        // MinGW's g++: the DLL's import
        .{ "x\x00libgfortran-5.dll\x00libstdc++-6.dll\x00x", true },
        // Linux: DT_NEEDED
        .{ "x\x00libgfortran.so.5\x00libstdc++.so.6\x00", true },
        // MSVC's
        .{ "x\x00MSVCP140.dll\x00VCRUNTIME140.dll\x00", true },
        // libstdc++ linked statically
        .{ "x\x00__cxa_throw\x00", true },
        // gfortran's alone
        .{ "x\x00libgfortran-5.dll\x00KERNEL32.dll\x00_gfortran_st_write\x00", false },
    };
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "p", .data = c[0] });
        const path = try tmp.dir.realPathFileAlloc(io, "p", std.testing.allocator);
        defer std.testing.allocator.free(path);
        try std.testing.expectEqual(c[1], linksCpp(io, path));
    }
}
