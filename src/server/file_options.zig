//! A file read as its compiler reads it (#542): the source form, fixed-form
//! line length, debug lines and `-fimplicit-none` of its command in
//! `compile_commands.json`, else of `compiler_args`, over zfls's settings.
//! A command of gfortran, ifx or ifort without a line length has their 72
//! columns when `fixed_line_length` is not set.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const parser = @import("../parser.zig");
const project = @import("../project.zig");
const command_options = @import("../command_options.zig");
const default_kinds = @import("../default_kinds.zig");
const compiler_names = @import("../compiler_names.zig");
const source_form = @import("source_form.zig");

const FortranFile = parser.FortranFile;
const Server = @import("../server.zig").Server;

/// Sets how `f` is read from its options, before its text is read
/// Whether the compiler `exe` reads fixed form to column 72 without an
/// option: gfortran, ifx and ifort (ifx 2026.2.0's listing has no name
/// past it)
fn fixed72(exe: []const u8) bool {
    const base = compiler_names.unversionedName(exe);
    for ([_][]const u8{ "gfortran", "ifx", "ifort" }) |n| if (compiler_names.namesCompiler(base, n)) return true;
    return false;
}

pub fn apply(self: *Server, f: *FortranFile) error{OutOfMemory}!void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    // the editor's file association, over the command's form (#686)
    f.associated_form = try source_form.association(self, arena.allocator(), f.path);
    const cmd = try project.commandFor(arena.allocator(), &self.compile_commands, f.path);
    const args: []const []const u8 = if (cmd) |c| c.args else if (self.s.compiler_args) |l| l.slice() else return;
    const o = command_options.parse(args);
    // the form only from the file's own command
    if (cmd != null) if (o.fixed) |fixed| {
        f.command_form = if (fixed) .fixed else .free;
    };
    if (o.columns) |c| {
        f.fixed_columns = switch (c) {
            .limit => |n| n,
            .none => null,
        };
    } else if (cmd) |c| if (c.args.len > 0 and self.s.fixedColumns() == null and fixed72(c.args[0])) {
        f.fixed_columns = 72;
    };
    // a TAB-format line's TAB against the line length, as the command's
    // compiler counts it (#585)
    if (cmd) |c| if (c.args.len > 0) if (compiler_names.idOf(c.args[0])) |id| {
        f.fixed_tab_wide = id == .gfortran or id == .flang;
    };
    if (o.d_lines_code) |code| f.d_lines_code = code;
    f.implicit_none = o.implicit_none;
    f.default_kinds = default_kinds.parse(args);
}
