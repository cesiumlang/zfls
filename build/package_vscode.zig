//! `package_vscode VERSION DIST` (`zig build package-vscode`), run at the
//! root of the repository: packages the VS Code extension (editors/vscode)
//! once per VS Code platform, each with the matching zfls release binary in
//! bin/, plus a universal VSIX without one (it runs zfls.path or zfls from
//! the PATH).
//!
//! DIST holds the release archives (zfls-vVERSION-TARGET.tar.gz/.zip); the
//! VSIX files are written there too, as zfls-vscode-vVERSION-PLATFORM.vsix.
//! npm builds the extension and `npx vsce package` packages it, with
//! VERSION set in its package.json for the packaging only.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const ext_path = "editors/vscode";

/// VS Code platform and zfls release target (the Linux binaries are static,
/// so they also run on Alpine)
const targets = [_]struct { []const u8, []const u8 }{
    .{ "win32-x64", "x86_64-windows" },
    .{ "win32-arm64", "aarch64-windows" },
    .{ "linux-x64", "x86_64-linux" },
    .{ "linux-arm64", "aarch64-linux" },
    .{ "alpine-x64", "x86_64-linux" },
    .{ "alpine-arm64", "aarch64-linux" },
    .{ "darwin-x64", "x86_64-macos" },
    .{ "darwin-arm64", "aarch64-macos" },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 3) {
        std.debug.print("usage: zig build package-vscode -- DIST\n", .{});
        return 2;
    }
    const version = argv[1];
    const cwd = Io.Dir.cwd();
    const dist_path = cwd.realPathFileAlloc(io, argv[2], a) catch |e| {
        std.debug.print("{s}: {s}\n", .{ argv[2], @errorName(e) });
        return 1;
    };
    var dist = try cwd.openDir(io, dist_path, .{});
    defer dist.close(io);
    var ext = try cwd.openDir(io, ext_path, .{});
    defer ext.close(io);

    try run(io, &.{ "npm", "ci", "--no-audit", "--no-fund" });
    try run(io, &.{ "npm", "run", "build" });
    // the version is set for packaging only
    const package_json = try ext.readFileAlloc(io, "package.json", a, .limited(1 << 20));
    defer ext.writeFile(io, .{ .sub_path = "package.json", .data = package_json }) catch |e|
        std.debug.print("restoring {s}/package.json: {s}\n", .{ ext_path, @errorName(e) });
    defer ext.deleteTree(io, "bin") catch {};
    try run(io, &.{ "npm", "pkg", "set", try a.print("version={s}", .{version}) });
    try Io.Dir.copyFile(cwd, "LICENSE", ext, "LICENSE", io, .{});

    var written: std.ArrayList([]const u8) = .empty;
    for (targets) |t| {
        const name = try a.print("zfls-v{s}-{s}", .{ version, t[1] });
        try ext.deleteTree(io, "bin");
        extractBinary(io, a, dist, name, ext) catch |e| {
            std.debug.print("{s}/{s}: {s}\n", .{ dist_path, name, @errorName(e) });
            return 1;
        };
        const vsix = try vsixPath(a, dist_path, version, t[0]);
        try run(io, &.{ "npx", "vsce", "package", "--no-dependencies", "--target", t[0], "--out", vsix });
        try written.append(a, vsix);
    }

    try ext.deleteTree(io, "bin");
    const vsix = try vsixPath(a, dist_path, version, "universal");
    try run(io, &.{ "npx", "vsce", "package", "--no-dependencies", "--out", vsix });
    try written.append(a, vsix);
    for (written.items) |path| {
        const st = try cwd.statFile(io, path, .{});
        std.debug.print("{d:>10} {s}\n", .{ st.size, path });
    }
    return 0;
}

/// Runs `argv` in the extension's directory, which must succeed
fn run(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = ext_path }, .stdin = .ignore });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("{s} {s} failed: {f}\n", .{ argv[0], argv[1], term });
        return error.CommandFailed;
    }
}

fn vsixPath(a: Allocator, dist: []const u8, version: []const u8, platform: []const u8) ![]const u8 {
    return a.print("{s}{c}zfls-vscode-v{s}-{s}.vsix", .{ dist, Io.Dir.path.sep, version, platform });
}

/// Where `path`, a file or directory of the release archive `name`, goes in
/// bin/, if it does: the zfls binary, and the ifx kit next to it, which
/// `zfls setup-ifx` finds there (x86_64 Windows only)
fn binPath(name: []const u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, name) or path.len <= name.len or path[name.len] != '/') return null;
    const sub = path[name.len + 1 ..];
    if (std.mem.eql(u8, sub, "zfls") or std.mem.eql(u8, sub, "zfls.exe")) return sub;
    if (std.mem.eql(u8, sub, "ifx-kit/") or std.mem.startsWith(u8, sub, "ifx-kit/")) return sub;
    return null;
}

/// Writes ext/bin/, from the release archive `name` of `dist`: a .zip on
/// Windows, a .tar.gz elsewhere
fn extractBinary(io: Io, a: Allocator, dist: Io.Dir, name: []const u8, ext: Io.Dir) !void {
    var bin = try ext.createDirPathOpen(io, "bin", .{});
    defer bin.close(io);
    const windows = std.mem.endsWith(u8, name, "-windows");
    const archive = try dist.openFile(io, try a.print("{s}.{s}", .{ name, if (windows) "zip" else "tar.gz" }), .{});
    defer archive.close(io);
    var buf: [64 << 10]u8 = undefined;
    var fr = archive.reader(io, &buf);
    var found = false;
    if (windows) {
        var it = try std.zip.Iterator.init(&fr);
        var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        while (try it.next()) |entry| {
            const sub = binPath(name, try entry.getFilename(&fr, &name_buf, .{})) orelse continue;
            if (std.mem.endsWith(u8, sub, "/")) {
                try bin.createDirPath(io, sub);
                continue;
            }
            found = found or std.mem.eql(u8, sub, "zfls.exe");
            const out = try createFile(io, bin, sub, .default_file);
            defer out.close(io);
            var wbuf: [64 << 10]u8 = undefined;
            var fw = out.writer(io, &wbuf);
            try entry.extractTo(&fr, &fw.interface);
            try fw.end();
        }
    } else {
        const window = try a.alloc(u8, flate.max_window_len);
        var gunzip: flate.Decompress = .init(&fr.interface, .gzip, window);
        var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var it: std.tar.Iterator = .init(&gunzip.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
        while (try it.next()) |f| {
            if (f.kind != .file) continue;
            const sub = binPath(name, f.name) orelse continue;
            if (!std.mem.eql(u8, sub, "zfls")) continue;
            found = true;
            const out = try createFile(io, bin, sub, .executable_file);
            defer out.close(io);
            var wbuf: [64 << 10]u8 = undefined;
            var fw = out.writer(io, &wbuf);
            try it.streamRemaining(f, &fw.interface);
            try fw.end();
        }
    }
    if (!found) return error.NoZflsBinary;
}

fn createFile(io: Io, dir: Io.Dir, sub: []const u8, permissions: Io.File.Permissions) !Io.File {
    if (Io.Dir.path.dirnamePosix(sub)) |parent| try dir.createDirPath(io, parent);
    return dir.createFile(io, sub, .{ .permissions = permissions });
}

const testing = std.testing;

test binPath {
    const name = "zfls-v0.4.0-x86_64-windows";
    try testing.expectEqualStrings("zfls.exe", binPath(name, name ++ "/zfls.exe").?);
    try testing.expectEqualStrings("zfls", binPath(name, name ++ "/zfls").?);
    try testing.expectEqualStrings("ifx-kit/", binPath(name, name ++ "/ifx-kit/").?);
    try testing.expectEqualStrings("ifx-kit/lib/x.lib", binPath(name, name ++ "/ifx-kit/lib/x.lib").?);
    try testing.expect(binPath(name, name ++ "/zfls.pdb") == null);
    try testing.expect(binPath(name, name ++ "/LICENSE") == null);
    try testing.expect(binPath(name, name ++ "/") == null);
    try testing.expect(binPath(name, name ++ "x/zfls.exe") == null);
    try testing.expect(binPath(name, "zfls.exe") == null);
}

test vsixPath {
    const path = try vsixPath(testing.allocator, "dist", "0.4.0", "win32-x64");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("dist" ++ [_]u8{Io.Dir.path.sep} ++ "zfls-vscode-v0.4.0-win32-x64.vsix", path);
}

test extractBinary {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // a release archive of a Linux target: zfls only, executable
    const name = "zfls-v0.4.0-x86_64-linux";
    var tar: Io.Writer.Allocating = .init(a);
    var tw: std.tar.Writer = .{ .underlying_writer = &tar.writer };
    try tw.writeFileBytes(name ++ "/LICENSE", "license\n", .{});
    try tw.writeFileBytes(name ++ "/zfls", "binary", .{ .mode = 0o755 });
    try tw.finishPedantically();
    var gz: Io.Writer.Allocating = try .initCapacity(a, 1 << 16);
    var window: [flate.max_window_len]u8 = undefined;
    var c: flate.Compress = try .init(&gz.writer, &window, .gzip, .default);
    try c.writer.writeAll(tar.written());
    try c.finish();
    try tmp.dir.writeFile(io, .{ .sub_path = name ++ ".tar.gz", .data = gz.written() });

    try extractBinary(io, a, tmp.dir, name, tmp.dir);
    try testing.expectEqualStrings("binary", try tmp.dir.readFileAlloc(io, "bin/zfls", a, .limited(1 << 10)));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "bin/LICENSE", .{}));
    if (Io.File.Permissions.has_executable_bit) {
        const st = try tmp.dir.statFile(io, "bin/zfls", .{});
        try testing.expect(@backingInt(st.permissions) & 0o100 != 0);
    }

    // a release archive of x86_64 Windows: zfls.exe and the ifx kit
    const win = "zfls-v0.4.0-x86_64-windows";
    const entries = [_]struct { []const u8, []const u8 }{
        .{ win ++ "/", "" },
        .{ win ++ "/zfls.exe", "exe" },
        .{ win ++ "/zfls.pdb", "pdb" },
        .{ win ++ "/ifx-kit/", "" },
        .{ win ++ "/ifx-kit/lib/", "" },
        .{ win ++ "/ifx-kit/lib/kernel32.lib", "lib" },
    };
    try tmp.dir.writeFile(io, .{ .sub_path = win ++ ".zip", .data = try storedZip(a, &entries) });
    try tmp.dir.deleteTree(io, "bin");
    try extractBinary(io, a, tmp.dir, win, tmp.dir);
    try testing.expectEqualStrings("exe", try tmp.dir.readFileAlloc(io, "bin/zfls.exe", a, .limited(1 << 10)));
    try testing.expectEqualStrings("lib", try tmp.dir.readFileAlloc(io, "bin/ifx-kit/lib/kernel32.lib", a, .limited(1 << 10)));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "bin/zfls.pdb", .{}));
}

/// A zip of `entries` (name, data), stored, as `zip -r` writes them (a
/// directory's name ends with `/`)
fn storedZip(a: Allocator, entries: []const struct { []const u8, []const u8 }) ![]const u8 {
    const zip = std.zip;
    var local: Io.Writer.Allocating = .init(a);
    var central: Io.Writer.Allocating = .init(a);
    for (entries) |e| {
        const offset: u32 = @intCast(local.written().len);
        const lh: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = 0,
            .compressed_size = @intCast(e[1].len),
            .uncompressed_size = @intCast(e[1].len),
            .filename_len = @intCast(e[0].len),
            .extra_len = 0,
        };
        try local.writer.writeStruct(lh, .little);
        try local.writer.writeAll(e[0]);
        try local.writer.writeAll(e[1]);
        const ch: zip.CentralDirectoryFileHeader = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = 0,
            .compressed_size = @intCast(e[1].len),
            .uncompressed_size = @intCast(e[1].len),
            .filename_len = @intCast(e[0].len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = offset,
        };
        try central.writer.writeStruct(ch, .little);
        try central.writer.writeAll(e[0]);
    }
    const end: zip.EndRecord = .{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(entries.len),
        .record_count_total = @intCast(entries.len),
        .central_directory_size = @intCast(central.written().len),
        .central_directory_offset = @intCast(local.written().len),
        .comment_len = 0,
    };
    try local.writer.writeAll(central.written());
    try local.writer.writeStruct(end, .little);
    return local.written();
}
