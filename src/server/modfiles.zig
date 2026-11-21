//! LLVM Flang's module files (#395): a `.mod` of Flang's is the module's
//! interface as free-form Fortran (after a UTF-8 BOM, a `!mod$ v1 sum:`
//! line and `!need$` lines, comments), so zfls indexes it as it does an
//! included file (not a source of the workspace, whose diagnostics are not
//! published unless it is open). For each module that a USE names and
//! that nothing defines (the workspace's sources, zfls's table of
//! intrinsic modules), zfls reads `<module>.mod` of the first directory
//! that has one of Flang's: the include directories (`include_dirs`, and
//! those of the build files), then, when the compiler check is LLVM
//! Flang's (`compiler_diagnostics`), the directory of its intrinsic
//! modules (`cudadevice`, `__fortran_builtins`, ...); then the modules
//! that those use. The `.mod` files of other compilers (gfortran's are
//! compressed, Intel's binary) are not read, but the sources Intel's
//! compilers ship are (compiler_sources.zig).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const parser = @import("../parser.zig");
const FortranFile = parser.FortranFile;
const compilers = @import("../compilers.zig");

const Server = @import("../server.zig").Server;
const compile_args = @import("compile_args.zig");
const compiler_version = @import("compiler_version.zig");
const definition = @import("definition.zig");
const linking = @import("linking.zig");
const workspace = @import("workspace.zig");
const cache = @import("cache.zig");
const compiler_sources = @import("compiler_sources.zig");
const shipped = @import("../compilers/shipped.zig");

/// Whether `head`, the beginning of a file, is that of a module file of
/// LLVM Flang's: `!mod$`, after a UTF-8 BOM or not
pub fn isFlangModuleFile(head: []const u8) bool {
    const text = if (std.mem.startsWith(u8, head, "\xEF\xBB\xBF")) head[3..] else head;
    return std.mem.startsWith(u8, text, "!mod$");
}

/// Whether the file at `path` is a module file of LLVM Flang's
fn isFlangModulePath(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buf: [8]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return false;
    return isFlangModuleFile(buf[0..n]);
}

/// The directories of module files: the include directories, then that of
/// LLVM Flang's intrinsic modules when the compiler check is Flang's
pub fn searchDirs(self: *Server, a: Allocator) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.appendSlice(a, try definition.includeDirs(self, a));
    for ([_]bool{ false, true }) |fixed| {
        if (compile_args.compilerOf(self, fixed) != .flang) continue;
        const exes = try compile_args.executables(self, a, .flang, compile_args.compilerPath(self, fixed), null);
        const known = compiler_version.of(self, a, .flang, exes);
        const dir = known.module_dir orelse continue;
        const listed = for (dirs.items) |d| {
            if (std.mem.eql(u8, d, dir)) break true;
        } else false;
        if (!listed) try dirs.append(a, dir);
    }
    return dirs.items;
}

/// The module file of Flang's for module `name` (lowercase) in `dirs`
fn find(io: Io, a: Allocator, dirs: []const []const u8, name: []const u8) !?[]const u8 {
    const base = try a.print("{s}.mod", .{name});
    for (dirs) |d| {
        const p = try std.Io.Dir.path.join(a, &.{ d, base });
        if (isFlangModulePath(io, p)) return try parser.normPath(a, p);
    }
    return null;
}

/// Reads and parses a module file (`module_file`), as free-form source, or
/// a compiler's module source in the form of its name
fn load(self: *Server, path: []const u8, module_file: bool) parser.FileError!*FortranFile {
    const f = try FortranFile.create(self.gpa, path, null);
    errdefer f.destroy();
    if (module_file) f.forced_form = .free;
    f.comment_markers = self.s.comment_markers.slice();
    f.openmp_conditional = !self.s.disable_openmp_conditional;
    _ = try f.setTextOwned(try cache.read(self, path));
    const opts = workspace.parseOptions(self);
    const prepared = f.prepare(self.io, &self.pp_defs, &.{}, opts) catch return error.ParseFailed;
    f.ast = cache.parseFile(self, f, prepared, opts, false) catch return error.ParseFailed;
    return f;
}

/// The module files (else the compiler's module sources) that the USE
/// statements of `of` (else of every file) need, and those that theirs
/// need, read and put in the tree: whether one was added (which a relink
/// then links in)
pub fn add(self: *Server, a: Allocator, of: ?*FortranFile) !bool {
    var todo: std.ArrayList(*FortranFile) = .empty;
    if (of) |f| try todo.append(a, f) else try todo.appendSlice(a, self.workspace.values());
    var dirs: ?[]const []const u8 = null;
    var added = false;
    while (todo.pop()) |f| {
        const ast = f.ast orelse continue;
        for (ast.scope_list.items) |scope| for (scope.scopeDataConst().use.items) |u| {
            if (u.is_import) continue;
            // zfls's table's OpenMP modules give way to the compiler's own
            const table = if (self.obj_tree.get(u.mod_name)) |e| (if (e.path == null) true else continue) else false;
            if (table and !shipped.replacesTable(u.mod_name)) continue;
            if (dirs == null) dirs = try searchDirs(self, a);
            const module_file = if (table) null else try find(self.io, a, dirs.?, u.mod_name);
            const path = module_file orelse (try compiler_sources.find(self, a, u.mod_name)) orelse continue;
            if (self.workspace.contains(path)) continue;
            const nf = load(self, path, module_file != null) catch |e| {
                self.log.info("{s}, the module file of {s}: {s}", .{ path, u.mod_name, parser.describeFileError(e) });
                continue;
            };
            nf.included = true;
            {
                errdefer nf.destroy();
                try self.workspace.put(self.gpa, nf.path, nf);
            }
            try linking.addToTree(self, nf);
            self.log.info("{s}: module {s} from its {s}", .{ path, u.mod_name, if (module_file != null) "module file" else "compiler's source" });
            try todo.append(a, nf);
            added = true;
        };
    }
    return added;
}

test "a module file of LLVM Flang's, by its first line" {
    try std.testing.expect(isFlangModuleFile("\xEF\xBB\xBF!mod$ v1 sum:4fadcad3a42bb497\n"));
    try std.testing.expect(isFlangModuleFile("!mod$ v1 sum:4fadcad3a42bb497\n"));
    // gfortran's (gzip), and source
    try std.testing.expect(!isFlangModuleFile("\x1f\x8b\x08\x00"));
    try std.testing.expect(!isFlangModuleFile("module m\n"));
    try std.testing.expect(!isFlangModuleFile(""));
}
