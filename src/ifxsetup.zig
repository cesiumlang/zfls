//! `zfls setup-ifx`: Intel's ifx on Windows without Intel's installer or
//! Visual Studio. Intel's offline installer (downloaded by the user from
//! Intel) is a zip behind a program; its compiler packages
//! (`packages/<name>/cupPayload.cup`) are zips too. This unpacks the ones
//! a Fortran compiler needs, without the parts Fortran on the CPU does not
//! use (OpenCL, SYCL, GPU offload, debug and static runtimes), with Intel's
//! license and notices; copies the ifx kit next to it (build/ifxkit.zig:
//! the startup code and import libraries that stand for Visual Studio's);
//! and writes `bin/ifx.cfg`, so that the ifx works by itself: `/MD`, Intel's
//! lld-link, and the kit. Intel's license must be accepted first
//! (`--accept-intel-license`, after reading it with `--show-license`):
//! Intel's installer would have shown it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A zip archive in memory or in a file; it may follow other data (a
/// self-extracting program), whose length its offsets leave out. No zip64,
/// no encryption: Intel's packages need neither.
pub const Zip = struct {
    src: Source,
    entries: []Entry,

    pub const Entry = struct {
        name: []const u8,
        method: u16,
        compressed: u64,
        size: u64,
        /// Where its local header is, from the start of the source
        local: u64,
    };

    pub const Source = union(enum) {
        mem: []const u8,
        file: struct { io: Io, file: Io.File, len: u64 },

        fn len(s: Source) u64 {
            return switch (s) {
                .mem => |m| m.len,
                .file => |f| f.len,
            };
        }

        fn readAt(s: Source, a: Allocator, offset: u64, n: usize) ![]u8 {
            if (offset + n > s.len()) return error.ZipTruncated;
            const out = try a.alloc(u8, n);
            switch (s) {
                .mem => |m| @memcpy(out, m[@intCast(offset)..][0..n]),
                .file => |f| if (try f.file.readPositionalAll(f.io, out, offset) != n) return error.ZipTruncated,
            }
            return out;
        }
    };

    pub fn open(a: Allocator, src: Source) !Zip {
        // the end record: in the last 64 KiB (its comment) and 22 bytes
        const size = src.len();
        if (size < 22) return error.NotAZip;
        const tail_len: usize = @intCast(@min(size, 0xffff + 22));
        const tail = try src.readAt(a, size - tail_len, tail_len);
        var at: usize = tail_len - 22;
        const end = while (true) : (at -= 1) {
            if (std.mem.eql(u8, tail[at..][0..4], "PK\x05\x06")) break tail[at..];
            if (at == 0) return error.NotAZip;
        };
        const count = u16At(end, 10);
        const cd_size: u64 = u32At(end, 12);
        const cd_offset: u64 = u32At(end, 16);
        if (count == 0xffff or cd_size == 0xffffffff or cd_offset == 0xffffffff) return error.Zip64;
        const end_pos = size - tail_len + at;
        if (cd_size + cd_offset > end_pos) return error.NotAZip;
        // what precedes the archive (a program), which its offsets leave out
        const prefix = end_pos - cd_size - cd_offset;
        const cd = try src.readAt(a, prefix + cd_offset, @intCast(cd_size));
        const entries = try a.alloc(Entry, count);
        var p: usize = 0;
        for (entries) |*e| {
            if (p + 46 > cd.len or !std.mem.eql(u8, cd[p..][0..4], "PK\x01\x02")) return error.ZipCorrupt;
            const name_len = u16At(cd, p + 28);
            const extra_len = u16At(cd, p + 30);
            const comment_len = u16At(cd, p + 32);
            if (p + 46 + name_len > cd.len) return error.ZipCorrupt;
            e.* = .{
                .name = cd[p + 46 ..][0..name_len],
                .method = u16At(cd, p + 10),
                .compressed = u32At(cd, p + 20),
                .size = u32At(cd, p + 24),
                .local = prefix + u32At(cd, p + 42),
            };
            if (e.compressed == 0xffffffff or e.size == 0xffffffff) return error.Zip64;
            p += 46 + name_len + extra_len + comment_len;
        }
        return .{ .src = src, .entries = entries };
    }

    pub fn find(z: Zip, name: []const u8) ?Entry {
        for (z.entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// An entry's contents
    pub fn read(z: Zip, a: Allocator, e: Entry) ![]u8 {
        const header = try z.src.readAt(a, e.local, 30);
        defer a.free(header);
        if (!std.mem.eql(u8, header[0..4], "PK\x03\x04")) return error.ZipCorrupt;
        const data_at = e.local + 30 + u16At(header, 26) + u16At(header, 28);
        const raw = try z.src.readAt(a, data_at, @intCast(e.compressed));
        switch (e.method) {
            0 => return raw,
            8 => {
                defer a.free(raw);
                const out = try a.alloc(u8, @intCast(e.size));
                errdefer a.free(out);
                var in: Io.Reader = .fixed(raw);
                // no buffer: it writes straight into `out`
                var inflate: std.compress.flate.Decompress = .init(&in, .raw, &.{});
                var w: Io.Writer = .fixed(out);
                const n = inflate.reader.streamRemaining(&w) catch return error.ZipCorrupt;
                if (n != out.len) return error.ZipCorrupt;
                return out;
            },
            // LZMA, as Intel's packages are: a version (2 bytes), the size of
            // the properties (2), the properties (5), then the stream, whose
            // size the directory gives
            14 => {
                defer a.free(raw);
                if (raw.len < 9 or std.mem.readInt(u16, raw[2..4], .little) != 5) return error.ZipCorrupt;
                const out = try a.alloc(u8, @intCast(e.size));
                errdefer a.free(out);
                var in: Io.Reader = .fixed(raw[4..]);
                const lzma = std.compress.lzma;
                const params = lzma.Decode.Params.readHeader(&in, .{ .unpacked_size = .{ .use_provided = e.size } }) catch
                    return error.ZipCorrupt;
                var unlzma = lzma.Decompress.initParams(&in, a, &.{}, params, 1 << 30) catch return error.ZipCorrupt;
                defer unlzma.deinit();
                var w: Io.Writer = .fixed(out);
                const n = unlzma.reader.streamRemaining(&w) catch return error.ZipCorrupt;
                if (n != out.len) return error.ZipCorrupt;
                return out;
            },
            else => return error.ZipMethod,
        }
    }

    fn u16At(b: []const u8, i: usize) u16 {
        return std.mem.readInt(u16, b[i..][0..2], .little);
    }

    fn u32At(b: []const u8, i: usize) u32 {
        return std.mem.readInt(u32, b[i..][0..4], .little);
    }
};

/// The packages of a Fortran compiler, by the start of their names
pub const packages = [_][]const u8{
    "intel.oneapi.win.ifort-compiler,",
    "intel.oneapi.win.compilers-common,",
    "intel.oneapi.win.compilers-common-runtime,",
    "intel.oneapi.win.openmp,",
    "intel.oneapi.win.tcm,",
    "intel.oneapi.win.umf,",
};

/// Where a file of a package goes, relative to the destination, or null
/// to leave it out: `_installdir/compiler/2026.2/bin/ifx.exe` ->
/// `bin/ifx.exe`, `_installdir/tcm/1.6/bin/x.dll` -> `tcm/bin/x.dll`
pub fn destination(a: Allocator, name: []const u8) !?[]const u8 {
    const prefix = "_installdir/";
    if (!std.mem.startsWith(u8, name, prefix) or std.mem.endsWith(u8, name, "/")) return null;
    var parts = std.mem.splitScalar(u8, name[prefix.len..], '/');
    const product = parts.next() orelse return null;
    _ = parts.next() orelse return null; // its version
    const rest = parts.rest();
    if (rest.len == 0 or std.mem.startsWith(u8, rest, ".toolkit_linking_tool")) return null;
    const rel = if (std.mem.eql(u8, product, "compiler")) try a.dupe(u8, rest) else try std.fmt.allocPrint(a, "{s}/{s}", .{ product, rest });
    if (leftOut(rel)) return null;
    return rel;
}

/// The files Fortran on the CPU with `/MD` does not need: OpenCL and SYCL,
/// GPU offload, the other names of lld, LLVM tools ifx does not run, the
/// C/C++ drivers, debug (`*mdd`) and static (`/MT`) runtimes
fn leftOut(rel: []const u8) bool {
    const bin_prefixes = [_][]const u8{
        "common_clang64",   "intelocl64", "opencl",  "omptarget", "ur_", "xptifw", "sycl-ls", "syclbin-dump",
        "qkmalloc",         "libocl_svml", "icx-cc", "icx-cl", "cl.cfg", "icx.cfg", "clbltfn", "cllibrary",
    };
    const tool_prefixes = [_][]const u8{
        "lld.exe",        "ld.lld.exe",    "llc.exe",       "modularize",  "llvm-spirv", "sycl-post-link",
        "llvm-profgen",   "llvm-profdata", "clang-offload", "file-table-tform", "spirv-to-ir", "llvm-foreach",
        "append-file",    "llvm-cov",      "llvm-symbolizer", "yaml2obj", "llvm-link", "llvm-objcopy",
        "llvm-nm",        "llvm-ar",       "llvm-ml",
    };
    const static_libs = [_][]const u8{
        "svml_dispmt", "libmmt", "libmmds", "libm", "libifcoremt", "libifcore", "libifport", "libirc",
        "libdecimal", "libistrconv", "libirng", "intelocl64", "opencl",
    };
    var buf: [512]u8 = undefined;
    if (rel.len > buf.len) return false;
    const r = std.ascii.lowerString(&buf, rel);
    if (std.mem.startsWith(u8, r, "lib/clang/")) return true;
    if (std.mem.startsWith(u8, r, "bin/compiler/")) {
        const f = r["bin/compiler/".len..];
        for (tool_prefixes) |t| if (std.mem.startsWith(u8, f, t)) return true;
        return false;
    }
    if (std.mem.startsWith(u8, r, "bin/") and std.mem.indexOfScalar(u8, r["bin/".len..], '/') == null) {
        const f = r["bin/".len..];
        for (bin_prefixes) |p| if (std.mem.startsWith(u8, f, p)) return true;
        return std.mem.endsWith(u8, f, "mdd.dll") or std.mem.endsWith(u8, f, ".pdb");
    }
    if (std.mem.startsWith(u8, r, "lib/") and std.mem.indexOfScalar(u8, r["lib/".len..], '/') == null) {
        const f = r["lib/".len..];
        if (std.mem.endsWith(u8, f, "mdd.lib")) return true;
        for ([_][]const u8{ "sycl", "omptarget", "ur_" }) |p| if (std.mem.startsWith(u8, f, p) and std.mem.endsWith(u8, f, ".lib")) return true;
        for (static_libs) |s| if (std.mem.endsWith(u8, f, ".lib") and std.mem.eql(u8, f[0 .. f.len - 4], s)) return true;
    }
    return false;
}

/// The compiler's version from its package's name:
/// `intel.oneapi.win.ifort-compiler,v=2026.2.0+864` -> `2026.2.0`
pub fn versionOf(package: []const u8) ?[]const u8 {
    const v = std.mem.indexOf(u8, package, ",v=") orelse return null;
    const s = package[v + 3 ..];
    return s[0 .. std.mem.indexOfScalar(u8, s, '+') orelse s.len];
}

/// `bin/ifx.cfg`: the options of every ifx command, for the kit in `kit`
/// and ifx's libraries in `lib`
pub fn config(a: Allocator, lib: []const u8, kit: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\/MD /fuse-ld=lld "/Qoption,link,/LIBPATH:{s}" "/Qoption,link,/LIBPATH:{s}" "/Qoption,link,{s}\zfls_ifx_shim.obj"
        \\
    , .{ lib, kit, kit });
}

const usage =
    \\usage: zfls setup-ifx <Intel's Fortran offline installer .exe> [options]
    \\
    \\Sets up Intel's ifx without running Intel's installer and without Visual
    \\Studio: unpacks the compiler from the installer (download it from Intel:
    \\https://www.intel.com/content/www/us/en/developer/tools/oneapi/fortran-compiler-download.html,
    \\Windows, offline installer) and configures it to link with its own
    \\lld-link and zfls's ifx kit.
    \\
    \\  --show-license          print Intel's license from the installer, and stop
    \\  --accept-intel-license  accept Intel's license (required to set up)
    \\  --dest <dir>            where to put ifx (default: %LOCALAPPDATA%\zfls\ifx\<version>)
    \\  --kit <dir>             zfls's ifx kit (default: next to zfls)
    \\  --json                  print the result as JSON
    \\
;

/// Runs `zfls setup-ifx`: its exit code
pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var installer: ?[]const u8 = null;
    var dest: ?[]const u8 = null;
    var kit: ?[]const u8 = null;
    var accept = false;
    var show_license = false;
    var as_json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--accept-intel-license")) {
            accept = true;
        } else if (std.mem.eql(u8, arg, "--show-license")) {
            show_license = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if ((std.mem.eql(u8, arg, "--dest") or std.mem.eql(u8, arg, "--kit")) and i + 1 < args.len) {
            i += 1;
            if (arg[2] == 'd') dest = args[i] else kit = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try toStdout(io, usage);
            return 0;
        } else if (installer == null and !std.mem.startsWith(u8, arg, "--")) {
            installer = arg;
        } else {
            try toStderr(io, usage);
            return 2;
        }
    }
    const path = installer orelse {
        try toStderr(io, usage);
        return 2;
    };
    if (builtin.os.tag != .windows and !show_license) {
        try toStderr(io, "zfls setup-ifx: ifx without Visual Studio is for Windows\n");
        return 2;
    }

    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| return fail(io, a, "cannot open {s}: {s}", .{ path, @errorName(e) });
    defer file.close(io);
    const zip = Zip.open(a, .{ .file = .{ .io = io, .file = file, .len = try file.length(io) } }) catch |e|
        return fail(io, a, "{s} is not Intel's offline installer ({s})", .{ path, @errorName(e) });
    const license = if (zip.find("license.txt")) |e| try zip.read(a, e) else return fail(io, a, "{s} has no license.txt: not Intel's offline installer?", .{path});
    if (show_license) {
        try toStdout(io, license);
        return 0;
    }
    if (!accept) {
        try toStderr(io,
            \\zfls setup-ifx: Intel's license must be accepted first. Read it with
            \\  zfls setup-ifx <installer> --show-license
            \\then, if you accept it, run again with --accept-intel-license.
            \\
        );
        return 3;
    }

    // the packages, and the compiler's version
    var payloads: std.ArrayList(Zip.Entry) = .empty;
    var version: ?[]const u8 = null;
    for (zip.entries) |e| {
        if (!std.mem.startsWith(u8, e.name, "packages/") or !std.mem.endsWith(u8, e.name, "/cupPayload.cup")) continue;
        const package = e.name["packages/".len .. e.name.len - "/cupPayload.cup".len];
        for (packages) |p| if (std.mem.startsWith(u8, package, p)) {
            try payloads.append(a, e);
            if (std.mem.startsWith(u8, package, packages[0])) version = versionOf(package);
        };
    }
    if (version == null) return fail(io, a, "{s} has no Fortran compiler package: is it Intel's Fortran offline installer?", .{path});

    const root = if (dest) |d| try std.fs.path.resolve(a, &.{d}) else blk: {
        const base = env.get("LOCALAPPDATA") orelse return fail(io, a, "LOCALAPPDATA is not set: give --dest", .{});
        break :blk try std.fs.path.join(a, &.{ base, "zfls", "ifx", version.? });
    };
    const kit_dir = kit orelse try findKit(io, a) orelse
        return fail(io, a, "zfls's ifx kit is not next to zfls (ifx-kit, or ../lib/ifx): give --kit", .{});

    var files: usize = 0;
    var bytes: u64 = 0;
    for (payloads.items) |p| {
        var pa: std.heap.ArenaAllocator = .init(gpa);
        defer pa.deinit();
        const b = pa.allocator();
        const inner = try Zip.open(b, .{ .mem = try zip.read(b, p) });
        for (inner.entries) |e| {
            const rel = try destination(b, e.name) orelse continue;
            const target = try std.fs.path.join(b, &.{ root, rel });
            try writeFile(io, target, try inner.read(b, e));
            files += 1;
            bytes += e.size;
        }
    }
    // Intel's license and notices go with it
    try writeFile(io, try std.fs.path.join(a, &.{ root, "license.txt" }), license);
    if (zip.find("third-party-programs.txt")) |e| try writeFile(io, try std.fs.path.join(a, &.{ root, "third-party-programs.txt" }), try zip.read(a, e));

    // the kit, and ifx's configuration to use it
    const kit_dest = try std.fs.path.join(a, &.{ root, "zfls" });
    var kit_files: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, kit_dir, .{ .iterate = true }) catch |e| return fail(io, a, "cannot read the ifx kit {s}: {s}", .{ kit_dir, @errorName(e) });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try dir.readFileAlloc(io, entry.name, a, .limited(64 << 20));
        try writeFile(io, try std.fs.path.join(a, &.{ kit_dest, entry.name }), data);
        kit_files += 1;
    }
    if (kit_files == 0) return fail(io, a, "the ifx kit {s} is empty", .{kit_dir});
    const lib = try std.fs.path.join(a, &.{ root, "lib" });
    try writeFile(io, try std.fs.path.join(a, &.{ root, "bin", "ifx.cfg" }), try config(a, lib, kit_dest));

    const ifx = try std.fs.path.join(a, &.{ root, "bin", "ifx.exe" });
    if (as_json) {
        var w: Io.Writer.Allocating = .init(a);
        try std.json.Stringify.value(.{ .ifx = ifx, .version = version.?, .dest = root, .files = files }, .{}, &w.writer);
        try w.writer.writeByte('\n');
        try toStdout(io, w.written());
    } else {
        try toStdout(io, try std.fmt.allocPrint(a, "ifx {s} is ready: {s}\n({d} files, {d} MB; Intel's license is in {s})\n", .{
            version.?, ifx, files, bytes >> 20, root,
        }));
    }
    return 0;
}

/// The ifx kit next to zfls: `ifx-kit` beside it (release packages), or
/// `../lib/ifx` (zig build's prefix)
fn findKit(io: Io, a: Allocator) !?[]const u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, a) catch return null;
    for ([_][]const []const u8{ &.{ exe_dir, "ifx-kit" }, &.{ exe_dir, "..", "lib", "ifx" } }) |parts| {
        const dir = try std.fs.path.join(a, parts);
        const shim = try std.fs.path.join(a, &.{ dir, "zfls_ifx_shim.obj" });
        if (Io.Dir.cwd().access(io, shim, .{})) |_| return dir else |_| {}
    }
    return null;
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn toStdout(io: Io, text: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, text);
}

fn toStderr(io: Io, text: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, text);
}

fn fail(io: Io, a: Allocator, comptime fmt: []const u8, args: anytype) !u8 {
    try toStderr(io, try std.fmt.allocPrint(a, "zfls setup-ifx: " ++ fmt ++ "\n", args));
    return 1;
}

// Tests

/// A zip of stored entries (and one deflated), after `prefix`, for tests
fn testZip(a: Allocator, prefix: []const u8, files: []const struct { []const u8, []const u8 }) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, prefix);
    var cd: std.ArrayList(u8) = .empty;
    const start = buf.items.len;
    for (files) |f| {
        const name, const data = f;
        const local: u32 = @intCast(buf.items.len - start);
        try buf.appendSlice(a, "PK\x03\x04");
        try buf.appendNTimes(a, 0, 22); // version .. sizes (unused by the reader)
        try appendInt(a, &buf, u16, @intCast(name.len));
        try appendInt(a, &buf, u16, 0);
        try buf.appendSlice(a, name);
        try buf.appendSlice(a, data);
        try cd.appendSlice(a, "PK\x01\x02");
        try cd.appendNTimes(a, 0, 6);
        try appendInt(a, &cd, u16, 0); // stored
        try cd.appendNTimes(a, 0, 8);
        try appendInt(a, &cd, u32, @intCast(data.len));
        try appendInt(a, &cd, u32, @intCast(data.len));
        try appendInt(a, &cd, u16, @intCast(name.len));
        try cd.appendNTimes(a, 0, 12);
        try appendInt(a, &cd, u32, local);
        try cd.appendSlice(a, name);
    }
    const cd_offset: u32 = @intCast(buf.items.len - start);
    try buf.appendSlice(a, cd.items);
    try buf.appendSlice(a, "PK\x05\x06");
    try buf.appendNTimes(a, 0, 4);
    try appendInt(a, &buf, u16, @intCast(files.len));
    try appendInt(a, &buf, u16, @intCast(files.len));
    try appendInt(a, &buf, u32, @intCast(cd.items.len));
    try appendInt(a, &buf, u32, cd_offset);
    try appendInt(a, &buf, u16, 0);
    return buf.items;
}

fn appendInt(a: Allocator, buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try buf.appendSlice(a, &b);
}

test "a zip behind a program, and a zip in it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inner = try testZip(a, "", &.{
        .{ "_installdir/compiler/2026.2/bin/ifx.exe", "MZ ifx" },
        .{ "_installdir/compiler/2026.2/bin/common_clang64.dll", "OpenCL" },
        .{ "filelist.json", "{}" },
    });
    const outer = try testZip(a, "MZ a self-extracting program\x00\x01\x02", &.{
        .{ "license.txt", "Intel End User License Agreement" },
        .{ "packages/intel.oneapi.win.ifort-compiler,v=2026.2.0+864/cupPayload.cup", inner },
    });
    const z = try Zip.open(a, .{ .mem = outer });
    try std.testing.expectEqual(@as(usize, 2), z.entries.len);
    try std.testing.expectEqualStrings("Intel End User License Agreement", try z.read(a, z.find("license.txt").?));
    const pkg = z.entries[1];
    try std.testing.expectEqualStrings("2026.2.0", versionOf(pkg.name["packages/".len..]).?);
    const in = try Zip.open(a, .{ .mem = try z.read(a, pkg) });
    try std.testing.expectEqualStrings("MZ ifx", try in.read(a, in.entries[0]));
    try std.testing.expectEqualStrings("bin/ifx.exe", (try destination(a, in.entries[0].name)).?);
    // left out: OpenCL, the package's own files
    try std.testing.expectEqual(@as(?[]const u8, null), try destination(a, in.entries[1].name));
    try std.testing.expectEqual(@as(?[]const u8, null), try destination(a, in.entries[2].name));
}

test "a deflated entry" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "program hello\n  print *, \"hello, hello, hello\"\nend program\n";
    const deflated = [_]u8{
        0x2b, 0x28, 0xca, 0x4f, 0x2f, 0x4a, 0xcc, 0x55, 0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0xe7, 0x52, 0x50, 0x28, 0x28, 0xca, 0xcc, 0x2b, 0x51,
        0xd0, 0xd2, 0x51, 0x50, 0x02, 0x8b, 0xe8, 0x28, 0x20, 0x53, 0x4a, 0x5c, 0xa9, 0x79, 0x29, 0x40, 0x25, 0x60, 0x2d, 0x5c, 0x00,
    };
    var z = try Zip.open(a, .{ .mem = try testZip(a, "", &.{.{ "hello.f90", &deflated }}) });
    z.entries[0].method = 8;
    z.entries[0].size = plain.len;
    try std.testing.expectEqualStrings(plain, try z.read(a, z.entries[0]));
}

test "an LZMA entry (Intel's packages)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "program hello\n  print *, \"hello, hello, hello\"\nend program\n";
    // Python's zipfile, ZIP_LZMA
    const lzma = [_]u8{
        0x09, 0x04, 0x05, 0x00, 0x5d, 0x00, 0x00, 0x80, 0x00, 0x00, 0x38, 0x1c, 0x8a, 0x21, 0xf9, 0x21, 0xba, 0x2d, 0x02, 0x3b,
        0x87, 0xc9, 0x3b, 0xfd, 0x37, 0x7e, 0xcb, 0xb6, 0xdf, 0xa7, 0x85, 0x97, 0x94, 0xff, 0xe6, 0x54, 0x24, 0xca, 0x08, 0x3d,
        0xd8, 0x73, 0x99, 0x69, 0x20, 0xb4, 0x56, 0x7b, 0xb4, 0x33, 0x0f, 0x24, 0x5b, 0x96, 0xff, 0xff, 0xe8, 0xc7, 0x60, 0x00,
    };
    var z = try Zip.open(a, .{ .mem = try testZip(a, "", &.{.{ "hello.f90", &lzma }}) });
    z.entries[0].method = 14;
    z.entries[0].size = plain.len;
    try std.testing.expectEqualStrings(plain, try z.read(a, z.entries[0]));
}

test "what a Fortran compiler needs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kept = [_][]const u8{
        "bin/ifx.exe",               "bin/compiler/xfortcom.exe", "bin/compiler/lld-link.exe", "bin/libifcoremd.dll",
        "bin/libmmd.dll",            "bin/svml_dispmd.dll",       "bin/libiomp5md.dll",        "lib/libifcoremd.lib",
        "lib/libifportmd.lib",       "lib/libircmt.lib",          "lib/libmmd.lib",            "lib/svml_dispmd.lib",
        "opt/compiler/include/intel64/omp_lib.mod",
    };
    for (kept) |k| {
        const name = try std.fmt.allocPrint(a, "_installdir/compiler/2026.2/{s}", .{k});
        try std.testing.expectEqualStrings(k, (try destination(a, name)) orelse return error.LeftOut);
    }
    const out_ = [_][]const u8{
        "bin/common_clang64.dll", "bin/libifcoremdd.dll", "bin/compiler/lld.exe",  "bin/compiler/llvm-spirv.exe",
        "lib/svml_dispmt.lib",    "lib/libifcoremt.lib",  "lib/libmmdd.lib",       "lib/clang/23/lib/x.a",
        "lib/sycl9.lib",          "bin/libiomp5md.pdb",
    };
    for (out_) |o| {
        const name = try std.fmt.allocPrint(a, "_installdir/compiler/2026.2/{s}", .{o});
        try std.testing.expectEqual(@as(?[]const u8, null), try destination(a, name));
    }
    try std.testing.expectEqualStrings("tcm/bin/tcm.dll", (try destination(a, "_installdir/tcm/1.6/bin/tcm.dll")).?);
    const cfg = try config(a, "C:\\ifx\\lib", "C:\\ifx\\zfls");
    try std.testing.expect(std.mem.indexOf(u8, cfg, "/fuse-ld=lld") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"/Qoption,link,C:\\ifx\\zfls\\zfls_ifx_shim.obj\"") != null);
}
