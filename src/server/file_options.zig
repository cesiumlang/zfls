//! A file read as its compiler reads it (#542): the source form, fixed-form
//! line length, debug lines and `-fimplicit-none` of its command in
//! `compile_commands.json`, else of `compiler_args`, over zfls's settings.
//! A command of gfortran without a line length has gfortran's 72 columns
//! when `fixed_line_length` is not set.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const parser = @import("../parser.zig");
const project = @import("../project.zig");
const command_options = @import("../command_options.zig");
const compiler_names = @import("../compiler_names.zig");

const FortranFile = parser.FortranFile;
const Server = @import("../server.zig").Server;

/// Sets how `f` is read from its options, before its text is read
pub fn apply(self: *Server, f: *FortranFile) error{OutOfMemory}!void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
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
    } else if (cmd) |c| if (c.args.len > 0 and self.s.fixedColumns() == null and
        compiler_names.namesCompiler(compiler_names.unversionedName(c.args[0]), "gfortran"))
    {
        f.fixed_columns = 72;
    };
    if (o.d_lines_code) |code| f.d_lines_code = code;
    f.implicit_none = o.implicit_none;
}
