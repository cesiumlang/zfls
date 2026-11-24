//! `zfls/fpmTargets`: the fpm projects of the workspace, each with its
//! executables, tests and examples (the tables of fpm.toml, and the main
//! programs fpm finds by itself in `app/`, `test/` and `example/`) and the
//! auto-discovery switches of its `[build]`, for an editor's tasks and its
//! Run and Debug of fpm targets (fpm.zig). The test explorer has
//! `zfls/fpmTests` (tests.zig), with test-drive's suites.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("../json.zig");
const paths = @import("../paths.zig");
const project = @import("../project.zig");
const fpm = @import("../fpm.zig");
const tests = @import("tests.zig");
const Value = json.Value;
const Server = @import("../server.zig").Server;
const fsio = @import("../fsio.zig");

const Target = struct {
    /// `executable`, `test` or `example`
    kind: []const u8,
    name: []const u8,
    /// Its main program's file
    uri: []const u8,
    /// fpm finds it by itself: a program of `app/`, `test/` or `example/`
    auto: bool,
};

const Project = struct {
    /// fpm.toml's `name`, else the directory's
    name: []const u8,
    /// The directory of its fpm.toml
    uri: []const u8,
    /// `auto-executables`, `auto-tests` and `auto-examples` of `[build]`
    auto: struct { executable: bool, @"test": bool, example: bool },
    targets: []const Target,
};

pub fn serveFpmTargets(self: *Server, a: Allocator) !Value {
    var sources: tests.Sources = .{ .server = self, .a = a };
    var manifests: std.ArrayList([]const u8) = .empty;
    try tests.filesBelow(self, a, self.root_path, tests.isManifest, &manifests, 0);
    var out: std.ArrayList(Project) = .empty;
    for (manifests.items) |path| {
        const text = fsio.readFile(self.io, a, path, .limited(1 << 24)) catch continue;
        const root = paths.dirname(path);
        const m = try fpm.parseManifest(a, text);
        var targets: std.ArrayList(Target) = .empty;
        for (std.enums.values(fpm.TargetKind)) |kind| {
            // the main programs of the kind's directory, which fpm makes targets of
            var programs: std.ArrayList([]const u8) = .empty;
            if (m.auto.get(kind)) {
                var files: std.ArrayList([]const u8) = .empty;
                try tests.filesBelow(self, a, try paths.join(a, &.{ root, fpm.default_dirs.get(kind) }), project.isFortran, &files, 0);
                for (files.items) |f| {
                    const src = (try sources.get(f)) orelse continue;
                    if (fpm.mainProgram(src.ast) != null) try programs.append(a, f);
                }
            }
            for (try fpm.targetsOf(a, m, kind, root, programs.items)) |t| try targets.append(a, .{
                .kind = @tagName(kind),
                .name = t.name,
                .uri = try paths.pathToUri(a, t.main),
                .auto = t.auto,
            });
        }
        try out.append(a, .{
            .name = m.name orelse std.Io.Dir.path.basename(root),
            .uri = try paths.pathToUri(a, root),
            .auto = .{ .executable = m.auto.get(.executable), .@"test" = m.auto.get(.@"test"), .example = m.auto.get(.example) },
            .targets = targets.items,
        });
    }
    return json.from(a, out.items);
}
