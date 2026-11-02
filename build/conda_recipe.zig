//! Build-time generator of the conda-forge recipe (`zig build conda-recipe`)
//! from the template in packaging/conda-forge.
//!
//! The template leaves empty (`""`) the values of its `context:` that are
//! known elsewhere, `version` and `zfls_sha256`, and this fills them in from
//! the zfls source archive given (which has every dependency, as
//! submodules). The template's leading comment, about the template, is left
//! out.
//!
//! With `--release` the recipe is the one for conda-forge, building the
//! archive attached to the GitHub release; with `--local` its first source
//! is the archive itself, and `variants.yaml` stands in for conda-forge's
//! global pinning (a build of an unreleased zfls, in CI).
//!
//! Usage: conda_recipe TEMPLATE_DIR (--release | --local) ARCHIVE OUT_DIR

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What conda-forge's global pinning provides on its build machines
const variants =
    \\c_stdlib:
    \\  - if: osx
    \\    then: macosx_deployment_target
    \\c_stdlib_version:
    \\  - if: osx and x86_64
    \\    then: "10.13"
    \\  - if: osx and arm64
    \\    then: "11.0"
    \\
;

const Mode = enum { release, local };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);

    const mode: ?Mode = if (argv.len == 5) std.meta.stringToEnum(Mode, std.mem.trimStart(u8, argv[2], "-")) else null;
    if (mode == null) {
        std.log.err("usage: zig build conda-recipe -- (--release | --local) ARCHIVE OUT_DIR", .{});
        std.process.exit(2);
    }
    const template_dir = argv[1];
    const archive = argv[3];
    const out_path = argv[4];
    const cwd = Io.Dir.cwd();

    const version = archiveVersion(std.Io.Dir.path.basename(archive)) orelse {
        std.log.err("not a zfls source archive (zfls-vX.Y.Z-src.tar.gz): {s}", .{archive});
        std.process.exit(2);
    };
    var values: std.array_hash_map.String([]const u8) = .empty;
    try values.put(a, "version", try a.print("\"{s}\"", .{version}));
    try values.put(a, "zfls_sha256", try sha256Hex(a, try cwd.readFileAlloc(io, archive, a, .limited(1 << 30))));

    var tdir = try cwd.openDir(io, template_dir, .{});
    defer tdir.close(io);
    const template = try tdir.readFileAlloc(io, "recipe.yaml", a, .limited(1 << 20));
    const archive_path = if (mode.? == .local) try absolute(a, io, archive) else null;
    var name: []const u8 = "";
    const recipe = fill(a, template, &values, archive_path, &name) catch |e| {
        std.log.err("packaging/conda-forge/recipe.yaml: {s} {s}", .{ @errorName(e), name });
        std.process.exit(1);
    };

    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);
    try out.writeFile(io, .{ .sub_path = "recipe.yaml", .data = recipe });
    for ([_][]const u8{ "build.sh", "build.bat" }) |f|
        try out.writeFile(io, .{ .sub_path = f, .data = try tdir.readFileAlloc(io, f, a, .limited(1 << 20)) });
    if (mode.? == .local) try out.writeFile(io, .{ .sub_path = "variants.yaml", .data = variants });
    std.log.info("wrote {s}/recipe.yaml", .{out_path});
}

fn sha256Hex(a: Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// `X.Y.Z` of `zfls-vX.Y.Z-src.tar.gz`
fn archiveVersion(name: []const u8) ?[]const u8 {
    const prefix = "zfls-v";
    const suffix = "-src.tar.gz";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
    const v = name[prefix.len .. name.len - suffix.len];
    var parts = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (p.len == 0) return null;
        for (p) |c| if (!std.ascii.isDigit(c)) return null;
    }
    return if (n == 3) v else null;
}

fn absolute(a: Allocator, io: Io, path: []const u8) ![]const u8 {
    const full = try Io.Dir.cwd().realPathFileAlloc(io, path, a);
    // forward slashes, which the recipe takes on Windows too
    return std.mem.replaceOwned(u8, a, full, "\\", "/");
}

/// The template with its empty `context:` values filled in from `values`
/// (each of which it must use), without its leading comment, and with
/// `archive_path` as the first source in place of its `url` and `sha256`.
/// On an error about a value, `name` is its name. The lines are written
/// with `\n` (a checkout on Windows may give the template `\r\n`).
fn fill(a: Allocator, template: []const u8, values: *const std.array_hash_map.String([]const u8), archive_path: ?[]const u8, name: *[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var section: []const u8 = "";
    var in_first_source = false;
    var sources: usize = 0;
    var lines = std.mem.splitScalar(u8, template, '\n');
    var first = true;
    var header = true;
    while (lines.next()) |crlf_line| {
        const line = std.mem.trimEnd(u8, crlf_line, "\r");
        if (header and std.mem.startsWith(u8, line, "#")) continue;
        header = false;
        if (line.len > 0 and line[0] != ' ' and line[0] != '#') section = line;
        if (archive_path) |path| if (std.mem.eql(u8, section, "source:")) {
            if (std.mem.startsWith(u8, line, "  - ")) sources += 1;
            if (sources == 1 and std.mem.startsWith(u8, line, "  - url: ")) {
                in_first_source = true;
                try appendLine(a, &out, &first, try a.print("  - path: {s}", .{path}));
                continue;
            }
            if (in_first_source) {
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "sha256: ")) in_first_source = false;
                continue;
            }
        };
        if (std.mem.eql(u8, section, "context:") and std.mem.startsWith(u8, line, "  ") and line.len > 2 and line[2] != ' ' and line[2] != '#') {
            const colon = std.mem.find(u8, line, ": ") orelse return error.MalformedContext;
            name.* = line[2..colon];
            if (std.mem.eql(u8, std.mem.trim(u8, line[colon + 2 ..], " "), "\"\"")) {
                const value = values.get(name.*) orelse return error.UnfilledContextValue;
                try used.put(a, name.*, {});
                try appendLine(a, &out, &first, try a.print("  {s}: {s}", .{ name.*, value }));
                continue;
            }
        }
        try appendLine(a, &out, &first, line);
    }
    if (in_first_source) return error.FirstSourceHasNoSha256;
    for (values.keys()) |k| if (!used.contains(k)) {
        name.* = k;
        return error.UnusedValue;
    };
    return out.items;
}

fn appendLine(a: Allocator, out: *std.ArrayList(u8), first: *bool, line: []const u8) !void {
    if (!first.*) try out.append(a, '\n');
    first.* = false;
    try out.appendSlice(a, line);
}

test archiveVersion {
    try std.testing.expectEqualStrings("0.4.0", archiveVersion("zfls-v0.4.0-src.tar.gz").?);
    try std.testing.expect(archiveVersion("zfls-v0.4-src.tar.gz") == null);
    try std.testing.expect(archiveVersion("zfls-v0.4.0.tar.gz") == null);
}

test fill {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var values: std.array_hash_map.String([]const u8) = .empty;
    var name: []const u8 = "";
    try values.put(a, "version", "\"0.4.0\"");
    try values.put(a, "zfls_sha256", "abc");
    const template =
        \\# about the template,
        \\# left out
        \\context:
        \\  name: zfls
        \\  # comment
        \\  version: ""
        \\  zfls_sha256: ""
        \\
        \\source:
        \\  - url: https://example.com/zfls-v${{ version }}-src.tar.gz
        \\    # a comment
        \\    sha256: ${{ zfls_sha256 }}
        \\  - url: https://example.com/dep.tar.gz
        \\    sha256: def
        \\
    ;
    try std.testing.expectEqualStrings(
        \\context:
        \\  name: zfls
        \\  # comment
        \\  version: "0.4.0"
        \\  zfls_sha256: abc
        \\
        \\source:
        \\  - url: https://example.com/zfls-v${{ version }}-src.tar.gz
        \\    # a comment
        \\    sha256: ${{ zfls_sha256 }}
        \\  - url: https://example.com/dep.tar.gz
        \\    sha256: def
        \\
    , try fill(a, template, &values, null, &name));
    try std.testing.expectEqualStrings(
        \\context:
        \\  name: zfls
        \\  # comment
        \\  version: "0.4.0"
        \\  zfls_sha256: abc
        \\
        \\source:
        \\  - path: /tmp/zfls-v0.4.0-src.tar.gz
        \\  - url: https://example.com/dep.tar.gz
        \\    sha256: def
        \\
    , try fill(a, template, &values, "/tmp/zfls-v0.4.0-src.tar.gz", &name));
    // a template checked out with CRLF line endings
    const crlf = try std.mem.replaceOwned(u8, a, template, "\n", "\r\n");
    try std.testing.expectEqualStrings(
        try fill(a, template, &values, "/tmp/zfls-v0.4.0-src.tar.gz", &name),
        try fill(a, crlf, &values, "/tmp/zfls-v0.4.0-src.tar.gz", &name),
    );
    // every value is used, and every empty value filled
    try values.put(a, "extra", "x");
    try std.testing.expectError(error.UnusedValue, fill(a, template, &values, null, &name));
    try std.testing.expectEqualStrings("extra", name);
    _ = values.orderedRemove("extra");
    _ = values.orderedRemove("zfls_sha256");
    try std.testing.expectError(error.UnfilledContextValue, fill(a, template, &values, null, &name));
}
