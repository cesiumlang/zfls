//! `zfls/buildCommand`: how to build a Fortran file into a program to run
//! or debug, for every editor (run/command.zig). Without a `textDocument`,
//! only what concerns the compiler.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const command = @import("../run/command.zig");
const kit = @import("../run/kit.zig");
const Value = json.Value;
const Server = @import("../server.zig").Server;

pub const Params = struct {
    textDocument: ?lsp.TextDocumentIdentifier = null,
    /// A name looked up on the `PATH`, or a path
    compiler: ?[]const u8 = null,
    /// The compiler's file or directory, relative to the workspace
    compilerPath: ?[]const u8 = null,
    /// The build's options in place of the compiler's defaults
    args: ?[]const []const u8 = null,
    /// Where the program goes, relative to the workspace
    outputDirectory: ?[]const u8 = null,
    /// Values in place of the environment's, for the additions the answer
    /// makes to it (`{"Path": "${env:Path}"}` for a tasks.json)
    env: ?std.json.ArrayHashMap([]const u8) = null,
};

pub fn serveBuildCommand(self: *Server, a: Allocator, params: Params) !Value {
    const source = if (params.textDocument) |d|
        paths.pathFromUri(self.io, a, d.uri) catch return error.InvalidParams
    else
        null;
    var env: std.process.Environ.Map = if (self.toolEnv()) |e| try e.clone(a) else .init(a);
    var base = try env.clone(a);
    if (params.env) |overlay| {
        var it = overlay.map.iterator();
        while (it.next()) |e| try base.put(e.key_ptr.*, e.value_ptr.*);
    }
    const root: ?[]const u8 = if (self.root_path.len > 0) self.root_path else null;
    const out_dir: ?[]const u8 = if (params.outputDirectory) |d| blk: {
        if (d.len == 0) break :blk null;
        if (std.Io.Dir.path.isAbsolute(d)) break :blk try paths.normpath(a, d);
        break :blk try paths.normpath(a, try std.Io.Dir.path.join(a, &.{ root orelse paths.dirname(source orelse break :blk d), d }));
    } else null;
    const answer = try command.plan(a, .{
        .io = self.io,
        .env = &env,
        .base_env = &base,
        .cache_dir = paths.cacheDir(),
        .kit_dir = try kit.find(a, self.io),
    }, .{
        .source = source,
        .compiler = if (params.compiler) |c| (if (c.len > 0) c else "gfortran") else "gfortran",
        .compiler_path = params.compilerPath orelse "",
        .base_dir = root,
        .args = params.args,
        .output_dir = out_dir,
    }) orelse return .null;
    if (answer.note) |n| self.log.info("zfls/buildCommand: {s}", .{n});
    return json.from(a, answer);
}
