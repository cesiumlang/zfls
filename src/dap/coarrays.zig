//! A program of coarrays whose images are processes of their own: gfortran's
//! `-fcoarray=lib -lcaf_shmem` (GCC 16), whose program starts each image as
//! a child process and waits for them (`CreateProcessA` on Windows). Its
//! breakpoints, runtime errors and ERROR STOP happen in the images, which
//! gdb and lldb-dap do not follow (gdb on Windows debugs no child process),
//! so `zfls dap` says so at the launch, and that a build with
//! `-lcaf_single` (one image, in the program's own process) is debugged.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const paths = @import("../paths.zig");
const gdb_entry = @import("gdb_entry.zig");
const Session = @import("session.zig").Session;
const Value = json.Value;

/// A function of libcaf_shmem's own, in the symbol table of a program
/// linked with it (GCC 16.1); libcaf_single has none of its names
pub const shmem_symbol = "caf_shmem_mutex_lock";

/// At a `launch`: the note in the Debug Console when the configuration's
/// program is linked with libcaf_shmem
pub fn noteImages(s: *Session, a: Allocator, args: ?Value) void {
    const program = json.str(json.get(args, "program")) orelse return;
    if (program.len == 0) return;
    const cwd = json.str(json.get(args, "cwd")) orelse paths.getCwd();
    const path = if (std.Io.Dir.path.isAbsolute(program)) program else std.Io.Dir.path.join(a, &.{ cwd, program }) catch return;
    if (!gdb_entry.programHas(s.io, path, shmem_symbol)) return;
    const name = std.Io.Dir.path.basename(path);
    s.output(a, a.print("zfls dap: {s} runs its coarray images as processes of their own (gfortran's -lcaf_shmem), which the debugger does not follow: its breakpoints, runtime errors and ERROR STOP in the images do not stop. Build it with -lcaf_single to debug one image.\n", .{name}) catch return);
}
