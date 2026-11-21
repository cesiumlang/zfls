//! Which debugger a `launch` or `attach` uses when the configuration does
//! not say `dbgeng`: by the program's debug information (run/debugger.zig,
//! the rule `zfls/buildCommand` answers with too). A program with
//! Microsoft's debug information only (ifx's, ifort's, LLVM Flang's `-g` on
//! Windows) is Windows's Debugger Engine's, whatever else is configured:
//! gdb and lldb-dap cannot read it. A DWARF program is the configured
//! debugger's (`gdb`, `lldb`), else the platform's.
//! Part of `Session` (session.zig): each function takes it as `self`.

const std = @import("std");
const sysinfo = @import("builtin");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const paths = @import("../paths.zig");
const debugger = @import("../run/debugger.zig");
const debug_info = @import("../run/debug_info.zig");
const Session = @import("session.zig").Session;
const Value = json.Value;

/// Whether the configuration's program is for Windows's Debugger Engine, by
/// its debug information; the choice is said in an `output` event. False
/// when the configuration has `dbgeng` (either way), names no program, or
/// the program's debug information is not known.
pub fn engineFits(self: *Session, a: Allocator, args: ?Value) bool {
    if (json.get(args, "dbgeng") != null) return false;
    const program = json.str(json.get(args, "program")) orelse return false;
    if (program.len == 0) return false;
    const cwd = json.str(json.get(args, "cwd")) orelse paths.getCwd();
    const path = if (std.Io.Dir.path.isAbsolute(program)) program else std.Io.Dir.path.join(a, &.{ cwd, program }) catch return false;
    const info = debug_info.ofFile(self.io, path) orelse return false;
    const engine = debugger.fits(info, sysinfo.target.os.tag) == .dbgeng;
    // a DWARF program: the configuration's debugger, said when it names none
    if (!engine and (json.get(args, "gdb") != null or json.get(args, "lldb") != null)) return false;
    const what = if (engine) "Microsoft's debug information (a PDB)" else "DWARF debug information";
    const with = if (engine) "Windows's Debugger Engine" else if (self.default == .lldb) "lldb-dap" else "gdb";
    const name = std.Io.Dir.path.basename(path);
    self.output(a, a.print("zfls dap: {s} has {s}: debugging with {s}\n", .{ name, what, with }) catch return engine);
    return engine;
}
