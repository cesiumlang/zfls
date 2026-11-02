//! `source_archive VERSION [OUT_DIR]` (`zig build source-archive`), run at
//! the root of the repository: writes OUT_DIR/zfls-vVERSION-src.tar.gz
//! (OUT_DIR: dist), the working tree's files that git tracks, submodules
//! included (GitHub's own source archives leave vendor/rstd out), in the
//! directory zfls-vVERSION-src. The conda-forge recipe builds from it.
//!
//! The archive is reproducible: same tree, same bytes. The files are in the
//! order of `git ls-files`, with the mode git gives them (0755 or 0644),
//! owner and group 0 and the time of the last commit, and the gzip header
//! has no time.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Header = std.tar.Writer.Header;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 2 and argv.len != 3) {
        std.debug.print("usage: zig build source-archive -- [OUT_DIR]\n", .{});
        return 2;
    }
    const name = try archiveName(a, argv[1]);
    const out_path = if (argv.len == 3) argv[2] else "dist";

    // the working tree's files, so a version set in build.zig.zon for this
    // build is the one archived
    const files = parseLsFiles(a, try git(a, io, &.{ "ls-files", "-s", "-z", "--recurse-submodules" })) catch |e| {
        std.debug.print("git ls-files: {s}\n", .{@errorName(e)});
        return 1;
    };
    const mtime = try std.fmt.parseInt(u64, std.mem.trim(u8, try git(a, io, &.{ "log", "-1", "--format=%ct" }), " \r\n"), 10);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    const archive = try a.print("{s}/{s}.tar.gz", .{ out_path, name });
    const out = try cwd.createFile(io, archive, .{});
    defer out.close(io);
    var buf: [64 << 10]u8 = undefined;
    var fw = out.writer(io, &buf);
    var where: []const u8 = "";
    writeArchive(io, a, cwd, &fw.interface, name, files, mtime, &where) catch |e| {
        std.debug.print("{s}: {s}\n", .{ where, @errorName(e) });
        return 1;
    };
    try fw.end();
    std.log.info("wrote {s}", .{archive});
    return 0;
}

/// `zfls-vVERSION-src`, the archive's name without `.tar.gz` and its top
/// directory
fn archiveName(a: Allocator, version: []const u8) ![]const u8 {
    return a.print("zfls-v{s}-src", .{version});
}

/// stdout of `git ARGS`, which must succeed
fn git(a: Allocator, io: Io, args: []const []const u8) ![]const u8 {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{"git"}, args });
    const r = try std.process.run(a, io, .{ .argv = argv });
    if (!r.term.success()) {
        std.debug.print("git {s} failed:\n{s}", .{ args[0], r.stderr });
        return error.GitFailed;
    }
    return r.stdout;
}

const File = struct { path: []const u8, mode: u32 };

/// The files of `git ls-files -s -z` (`MODE OBJECT STAGE\tPATH\0`...) with
/// their tar modes
fn parseLsFiles(a: Allocator, out: []const u8) ![]const File {
    var files: std.ArrayList(File) = .empty;
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.findScalar(u8, line, '\t') orelse return error.MalformedLsFiles;
        const space = std.mem.findScalar(u8, line, ' ') orelse return error.MalformedLsFiles;
        const git_mode = line[0..space];
        // regular files only: no symbolic links (120000) to archive
        const mode: u32 = if (std.mem.eql(u8, git_mode, "100644"))
            0o644
        else if (std.mem.eql(u8, git_mode, "100755"))
            0o755
        else
            return error.UnsupportedFileMode;
        try files.append(a, .{ .path = line[tab + 1 ..], .mode = mode });
    }
    return files.items;
}

/// The tar.gz of `files` (paths relative to `root`) in the directory `top`.
/// On an error about a file, `where` is its path.
fn writeArchive(io: Io, a: Allocator, root: Io.Dir, out: *Io.Writer, top: []const u8, files: []const File, mtime: u64, where: *[]const u8) !void {
    const window = try a.alloc(u8, flate.max_window_len);
    const gz = try a.create(flate.Compress);
    gz.* = try .init(out, window, .gzip, .best);
    const w = &gz.writer;
    var buf: [64 << 10]u8 = undefined;
    for (files) |f| {
        where.* = f.path;
        const file = try root.openFile(io, f.path, .{});
        defer file.close(io);
        const size = try file.length(io);
        var h = try header(top, f.path, f.mode, size, mtime);
        try h.write(w);
        var r = file.reader(io, &buf);
        try r.interface.streamExact64(w, size);
        try w.splatByteAll(0, padding(size));
    }
    where.* = top;
    // the end of the archive: two empty blocks
    try w.splatByteAll(0, 2 * @sizeOf(Header));
    try gz.finish();
}

/// The ustar header of the regular file `top/path`, owned by user and group 0
fn header(top: []const u8, path: []const u8, mode: u32, size: u64, mtime: u64) !Header {
    var h: Header = .init(.regular);
    try h.setPath(top, path);
    try h.setMode(mode);
    try h.setSize(size);
    try h.setMtime(mtime);
    h.uid = "0000000".*;
    h.gid = "0000000".*;
    return h;
}

/// The zero bytes after `size` bytes of data, to the end of their block
fn padding(size: u64) usize {
    const block = @sizeOf(Header);
    return @intCast((block - size % block) % block);
}

const testing = std.testing;

test archiveName {
    const name = try archiveName(testing.allocator, "0.4.0");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("zfls-v0.4.0-src", name);
}

test parseLsFiles {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try parseLsFiles(a, "100644 1dfc 0\ta b.txt\x00100755 9a32 0\tvendor/x/run.sh\x00");
    try testing.expectEqual(2, files.len);
    try testing.expectEqualStrings("a b.txt", files[0].path);
    try testing.expectEqual(0o644, files[0].mode);
    try testing.expectEqualStrings("vendor/x/run.sh", files[1].path);
    try testing.expectEqual(0o755, files[1].mode);
    try testing.expectError(error.UnsupportedFileMode, parseLsFiles(a, "120000 1dfc 0\tlink\x00"));
    try testing.expectError(error.MalformedLsFiles, parseLsFiles(a, "100644 1dfc 0 a\x00"));
}

test header {
    var h = try header("zfls-v0.4.0-src", "src/main.zig", 0o755, 1234, 1700000000);
    try h.updateChecksum();
    const bytes = std.mem.asBytes(&h);
    try testing.expectEqualStrings("zfls-v0.4.0-src/src/main.zig", std.mem.sliceTo(bytes[0..100], 0));
    try testing.expectEqualStrings("0000755\x00", bytes[100..108]);
    try testing.expectEqualStrings("0000000\x00", bytes[108..116]);
    try testing.expectEqualStrings("0000000\x00", bytes[116..124]);
    try testing.expectEqualStrings("00000002322\x00", bytes[124..136]);
    try testing.expectEqualStrings("14524770400\x00", bytes[136..148]);
    try testing.expectEqual('0', bytes[156]);
    try testing.expectEqualStrings("ustar\x0000", bytes[257..265]);
    var sum: u32 = 0;
    for (bytes, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
    try testing.expectEqual(sum, try std.fmt.parseInt(u32, std.mem.trimStart(u8, bytes[148..155], " "), 8));
}

test padding {
    try testing.expectEqual(0, padding(0));
    try testing.expectEqual(511, padding(1));
    try testing.expectEqual(0, padding(512));
    try testing.expectEqual(312, padding(1224));
}

test writeArchive {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/run.sh", .data = "echo hi\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    // longer than a header's name: split between its prefix and name
    const dirs: [60][2]u8 = @splat("d/".*);
    const long = @as(*const [120]u8, @ptrCast(&dirs)) ++ "file.f90";
    try tmp.dir.createDirPath(io, long[0..120]);
    try tmp.dir.writeFile(io, .{ .sub_path = long, .data = "end\n" });
    const files: []const File = &.{
        .{ .path = "sub/run.sh", .mode = 0o755 },
        .{ .path = "empty", .mode = 0o644 },
        .{ .path = long, .mode = 0o644 },
    };

    var where: []const u8 = "";
    var gz1: Io.Writer.Allocating = try .initCapacity(a, 1 << 16);
    try writeArchive(io, a, tmp.dir, &gz1.writer, "top", files, 1700000000, &where);
    // reproducible
    var gz2: Io.Writer.Allocating = try .initCapacity(a, 1 << 16);
    try writeArchive(io, a, tmp.dir, &gz2.writer, "top", files, 1700000000, &where);
    try testing.expectEqualSlices(u8, gz1.written(), gz2.written());
    // no time in the gzip header
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, gz1.written()[4..8]);

    var in: Io.Reader = .fixed(gz1.written());
    var window: [flate.max_window_len]u8 = undefined;
    var gunzip: flate.Decompress = .init(&in, .gzip, &window);
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gunzip.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    const expected = [_]struct { []const u8, u32, []const u8 }{
        .{ "top/sub/run.sh", 0o755, "echo hi\n" },
        .{ "top/empty", 0o644, "" },
        .{ "top/" ++ long, 0o644, "end\n" },
    };
    for (expected) |e| {
        const f = (try it.next()).?;
        try testing.expectEqualStrings(e[0], f.name);
        try testing.expectEqual(e[1], f.mode);
        var data: Io.Writer.Allocating = .init(a);
        try it.streamRemaining(f, &data.writer);
        try testing.expectEqualStrings(e[2], data.written());
    }
    try testing.expect(try it.next() == null);
}
