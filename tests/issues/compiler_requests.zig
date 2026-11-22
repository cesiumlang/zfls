//! The compiler check's own requests (#740): `zfls/compilerCheck` checks a
//! file now, and `zfls/compilerClear` drops the compiler's diagnostics and
//! deletes the cache's `mod` and `work` directories. With a stand-in
//! gfortran that reports one error.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

const fake: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho a.f90:2:3: Error: said by the stand-in 1>&2\r\nexit /b 1\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\necho 'a.f90:2:3: Error: said by the stand-in' >&2\nexit 1\n" };

const source = h.File{ .name = "a.f90", .text = "program p\n  x = 1\nend program p\n" };
// what earlier checks left in the cache (not Fortran, so not indexed)
const stale_mod = h.File{ .name = ".zfls/mod/stale.txt", .text = "stale\n" };
const stale_work = h.File{ .name = ".zfls/work/stale.txt", .text = "stale\n" };

const said = "said by the stand-in";

fn start() !*h.Workspace {
    const w = try h.Workspace.init(&.{ source, fake, stale_mod, stale_work }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    errdefer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    return w;
}

/// The last diagnostics published for `name`, as JSON text
fn lastPublished(w: *h.Workspace, name: []const u8) !?[]const u8 {
    const quoted = try w.a().print("\"{s}\"", .{try w.uri(name)});
    w.server.send_lock.lockUncancelable(io);
    defer w.server.send_lock.unlock(io);
    var last: ?[]const u8 = null;
    for (w.sent.items) |m| if (std.mem.find(u8, m, "textDocument/publishDiagnostics") != null and std.mem.find(u8, m, quoted) != null) {
        last = m;
    };
    return last;
}

test "zfls/compilerCheck checks a file that is neither open nor saved (#740)" {
    const w = try start();
    defer w.deinit();
    // nothing checks it on its own
    try std.testing.expect((try w.waitForSent("textDocument/publishDiagnostics", said, 1)) == null);
    _ = try w.zflsRequest("zfls/compilerCheck", .{ .textDocument = .{ .uri = try w.uri("a.f90") } });
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", said, 60)) orelse return error.NoCompilerDiagnostics;
    try std.testing.expect(std.mem.find(u8, sent, "a.f90") != null);
}

test "zfls/compilerClear drops the compiler's diagnostics and the cache's mod and work directories (#740)" {
    const w = try start();
    defer w.deinit();
    _ = try w.zflsRequest("zfls/compilerCheck", .{ .textDocument = .{ .uri = try w.uri("a.f90") } });
    _ = (try w.waitForSent("textDocument/publishDiagnostics", said, 60)) orelse return error.NoCompilerDiagnostics;
    try std.testing.expect(std.mem.find(u8, (try lastPublished(w, "a.f90")).?, said) != null);
    _ = try w.zflsRequest("zfls/compilerClear", .{});
    // published again, without the compiler's error
    const last = (try lastPublished(w, "a.f90")).?;
    if (std.mem.find(u8, last, said) != null) {
        std.debug.print("\nstill published after zfls/compilerClear: {s}\n", .{last});
        return error.DiagnosticsKept;
    }
    for ([_][]const u8{ ".zfls/mod", ".zfls/work" }) |d| {
        if (w.tmp.dir.access(io, d, .{})) |_| {
            std.debug.print("\n{s} is still there after zfls/compilerClear\n", .{d});
            return error.CacheKept;
        } else |_| {}
    }
}
