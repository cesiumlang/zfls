//! The compiler check's command line (compile.zig): the compiler of a
//! file's form, its executables and its arguments.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const paths = @import("../paths.zig");
const parser = @import("../parser.zig");
const compilers = @import("../compilers.zig");
const project = @import("../project.zig");
const definition = @import("definition.zig");

const FortranFile = parser.FortranFile;
const Server = @import("../server.zig").Server;

const is_windows = builtin.target.os.tag == .windows;

/// The setting of the compiler of a form's files: `compiler_diagnostics`,
/// or for fixed form `compiler_diagnostics_fixed` when it is set
pub fn compilerName(self: *const Server, fixed: bool) ?[]const u8 {
    if (fixed) if (self.s.compiler_diagnostics_fixed) |n| return n;
    return self.s.compiler_diagnostics;
}

/// The compiler of a form's files, null when it is off or unknown
pub fn compilerOf(self: *const Server, fixed: bool) ?compilers.Id {
    const name = compilerName(self, fixed) orelse return null;
    return compilers.Id.fromName(std.mem.trim(u8, name, " "));
}

/// Whether a compiler checks the files of either form
pub fn anyCompiler(self: *const Server) bool {
    return compilerOf(self, false) != null or compilerOf(self, true) != null;
}

/// `compiler_args`, or for fixed form `compiler_args_fixed` when it is set
/// (empty: the compiler's defaults, for a compiler that `compiler_args` is
/// not for)
pub fn userArgs(self: *const Server, fixed: bool) ?[]const []const u8 {
    if (fixed) if (self.s.compiler_args_fixed) |l| return if (l.len() == 0) null else l.slice();
    return if (self.s.compiler_args) |l| l.slice() else null;
}

/// `compiler_path`, or for fixed form `compiler_path_fixed` when it is set
pub fn compilerPath(self: *const Server, fixed: bool) ?[]const u8 {
    if (fixed) if (self.s.compiler_path_fixed) |p| return p;
    return self.s.compiler_path;
}

/// Warns about a `compiler_diagnostics` (or `compiler_diagnostics_fixed`)
/// that is no compiler zfls knows
pub fn checkSetting(self: *Server, a: Allocator) !void {
    for ([_]struct { []const u8, ?[]const u8 }{
        .{ "compiler_diagnostics", self.s.compiler_diagnostics },
        .{ "compiler_diagnostics_fixed", self.s.compiler_diagnostics_fixed },
    }) |setting| {
        const name = setting[1] orelse continue;
        const trimmed = std.mem.trim(u8, name, " ");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none") or compilers.Id.fromName(trimmed) != null) continue;
        self.postMessage(a, try a.print("{s}: unknown compiler \"{s}\"; it is one of gfortran, ifx, ifort, flang, nvfortran, nagfor or lfortran", .{ setting[0], name }), 2);
    }
}

/// The executables to try: those of `compiler_path` (`configured`: a file,
/// or a directory that holds the compiler), else the compiler of the
/// file's command (`cmd`) when it is one of the compiler's names (with a
/// version or not: `unversionedName`), then those names, found on the PATH
pub fn executables(self: *Server, a: Allocator, id: compilers.Id, configured_path: ?[]const u8, cmd: ?project.Command) ![]const []const u8 {
    const names = compilers.executables(id);
    const configured = configured_path orelse {
        const c = cmd orelse return names;
        if (c.args.len == 0) return names;
        const exe = c.args[0];
        const base = unversionedName(exe);
        for (names) |n| if (std.mem.eql(u8, n, base)) {
            const has_dir = std.mem.findAny(u8, exe, "/\\") != null;
            const path = if (has_dir and !std.Io.Dir.path.isAbsolute(exe)) try paths.join(a, &.{ c.dir, exe }) else exe;
            const out = try a.alloc([]const u8, names.len + 1);
            out[0] = path;
            @memcpy(out[1..], names);
            return out;
        };
        return names;
    };
    if (configured.len == 0) return names;
    const p = if (std.Io.Dir.path.isAbsolute(configured)) configured else try paths.join(a, &.{ self.root_path, configured });
    if (!paths.isDir(self.io, p)) return a.dupe([]const u8, &.{p});
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| try out.append(a, try paths.join(a, &.{ p, if (is_windows) try a.print("{s}.exe", .{n}) else n }));
    return out.items;
}

/// The name of a compiler's executable without its directory, `.exe` and
/// version: `C:\x\flang-new-23.exe` and `flang-21` are flang-new and flang
/// (Ubuntu's and Nix's names), `gfortran-14` is gfortran
pub fn unversionedName(exe: []const u8) []const u8 {
    var base = exe[if (std.mem.findLastAny(u8, exe, "/\\")) |i| i + 1 else 0..];
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    // `-N`, `-N.N`, ...: digits and dots after the last `-`, starting and
    // ending with a digit
    const dash = std.mem.findScalarLast(u8, base, '-') orelse return base;
    const version = base[dash + 1 ..];
    if (version.len == 0 or !std.ascii.isDigit(version[0]) or !std.ascii.isDigit(version[version.len - 1])) return base;
    for (version) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return base;
    return base[0..dash];
}

test "a compiler's name, without its directory, .exe and version" {
    try std.testing.expectEqualStrings("flang-new", unversionedName("C:\\x\\bin\\flang-new-23.exe"));
    try std.testing.expectEqualStrings("flang-new", unversionedName("/usr/bin/flang-new-19"));
    try std.testing.expectEqualStrings("flang", unversionedName("/nix/store/x-flang-21.1.8/bin/flang-21"));
    try std.testing.expectEqualStrings("flang", unversionedName("flang-23.1.EXE"));
    try std.testing.expectEqualStrings("gfortran", unversionedName("gfortran-14"));
    try std.testing.expectEqualStrings("flang", unversionedName("C:/x/flang.exe"));
    try std.testing.expectEqualStrings("flang-new", unversionedName("flang-new"));
    // no version
    try std.testing.expectEqualStrings("flang-", unversionedName("flang-"));
    try std.testing.expectEqualStrings("flang-1.", unversionedName("flang-1."));
    try std.testing.expectEqualStrings("flang-x1", unversionedName("flang-x1"));
}

/// The command of `file` in compile_commands.json (or of another file in
/// its directory) whose arguments the compiler check uses: none when
/// `compiler_args` (`user`) is set or `compiler_no_compile_commands` is
pub fn commandOf(self: *Server, a: Allocator, file: *const FortranFile, user: ?[]const []const u8) !?project.Command {
    if (user != null or self.s.compiler_no_compile_commands) return null;
    return project.commandFor(a, &self.compile_commands, file.path);
}

/// What a compiler run is for
pub const Role = enum {
    /// The file checked, whose messages are published
    check,
    /// A module the file checked uses, compiled first for its .mod files
    dependency,
};

/// The compiler's arguments for `file`: syntax only (or, for a module the
/// file checked uses, what writes its .mod files), its form and line
/// length, the preprocessor and zfls's definitions when zfls preprocesses
/// it, the .mod directory, the include directories, then `user`
/// (`compiler_args` of the form checked, or the arguments of the file's
/// command `cmd`, which has its own definitions, or the compiler's
/// defaults), the file's language for a compiler that needs it, and the
/// file, last. Relative directories in `user` are relative to
/// `base`, the directory of the file checked, and those of `cmd` to its
/// directory.
pub fn argsOf(self: *Server, a: Allocator, id: compilers.Id, role: Role, file: *const FortranFile, user: ?[]const []const u8, cmd: ?project.Command, base: []const u8, o: compilers.Options) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, switch (role) {
        .check => try compilers.syntaxOnly(a, id, o),
        .dependency => try compilers.moduleOnly(a, id, o),
    });
    try args.appendSlice(a, if (file.declared_fixed) compilers.fixedForm(id, o) else compilers.freeForm(id, o));
    // the line length zfls reads, unless `compiler_args` sets one
    const user_sets = if (user) |u| for (u) |x| {
        if (compilers.isLineLength(id, file.declared_fixed, x)) break true;
    } else false else false;
    if (!user_sets) try args.appendSlice(a, try compilers.lineLength(a, id, file.declared_fixed, self.fixedLimit(), o));
    // debug lines as zfls reads them, unless `user` says
    if (file.declared_fixed) {
        for (user orelse &.{}) |x| {
            if (compilers.isDLinesArg(x)) break;
        } else try args.appendSlice(a, compilers.dLines(id, self.s.dLinesCode(), o));
    }
    if (file.preproc) {
        try args.appendSlice(a, compilers.preprocess(id, o));
        if (cmd == null) for (self.s.pp_defs.items) |d| try args.append(a, try compilers.define(a, id, d.name, d.value, o));
    }
    try args.appendSlice(a, try compilers.modOutput(a, id, o.mod_dir, o));
    // Flang's intrinsic modules where its driver does not look (#438)
    if (id == .flang) if (o.intrinsic_modules) |d| try args.appendSlice(a, &.{ "-fintrinsic-modules-path", try a.dupe(u8, d) });
    try args.appendSlice(a, try compilers.include(a, id, try a.dupe(u8, paths.dirname(file.path)), o));
    for (try definition.includeDirs(self, a)) |d| try args.appendSlice(a, try compilers.include(a, id, try a.dupe(u8, d), o));
    for (self.s.compiler_include_dirs.slice()) |d| {
        const dir = if (std.Io.Dir.path.isAbsolute(d)) d else try paths.join(a, &.{ self.root_path, d });
        try args.appendSlice(a, try compilers.include(a, id, try a.dupe(u8, dir), o));
    }
    const own = if (user) |u|
        try compilers.absoluteDirs(a, id, u, base, o)
    else if (cmd) |c|
        try compilers.absoluteDirs(a, id, try project.compilerArgs(a, c), c.dir, o)
    else
        compilers.defaultArgs(id, o);
    // the standard's implicit typing and interfaces, unless `own` says
    try args.appendSlice(a, compilers.implicitRules(id, own));
    for (own) |x| try args.append(a, try a.dupe(u8, x));
    try args.appendSlice(a, compilers.language(id, o));
    try args.append(a, try a.dupe(u8, file.path));
    return args.items;
}
