//! `zfls/fpmTests` and `zfls/pfunitTests`: the tests of the workspace, for
//! an editor's test explorer, which runs them. For fpm, each project's test
//! targets with test-drive's suites and tests below them (fpm.zig); for
//! pFUnit, each test program of `add_pfunit_ctest` with the suite of each
//! of its `.pf` files and their tests, and the suites of the `.pf` files no
//! program lists (pfunit.zig). Each has its URI and range. The procedures
//! and modules are those of the files' ASTs: the workspace's (with the
//! editor's text of open files), else parsed for the request.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const str = @import("../str.zig");
const glob = @import("../glob.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const project = @import("../project.zig");
const fpm = @import("../fpm.zig");
const pfunit = @import("../pfunit.zig");
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");

/// A test, or a suite of test-drive: its name and where it is
const Item = struct { name: []const u8, uri: []const u8, range: lsp.Range };

const FpmSuite = struct { name: []const u8, uri: []const u8, range: lsp.Range, tests: []const Item };

const FpmTarget = struct {
    name: []const u8,
    /// Its main program, when the file is found
    uri: ?[]const u8 = null,
    range: ?lsp.Range = null,
    /// The program takes a suite and a test on its command line
    selectsTests: bool = false,
    suites: []const FpmSuite = &.{},
};

const FpmProject = struct {
    /// fpm.toml's `name`, else the directory's
    name: []const u8,
    /// The directory of its fpm.toml
    uri: []const u8,
    targets: []const FpmTarget,
};

const PfTest = struct { name: []const u8, uri: []const u8, range: lsp.Range, parameterized: bool };

const PfSuite = struct { name: []const u8, uri: []const u8, range: lsp.Range, tests: []const PfTest };

const PfProgram = struct {
    name: []const u8,
    /// The CMakeLists.txt, and its name in the `add_pfunit_ctest` call
    uri: []const u8,
    range: lsp.Range,
    suites: []const PfSuite,
};

/// The files of the workspace that `wanted` takes, in `dir` and below, but
/// in hidden directories and those of builds (fpm's dependencies are in
/// build/dependencies, CMake's fetched ones in _deps)
fn filesBelow(self: *Server, a: Allocator, dir: []const u8, wanted: *const fn ([]const u8) bool, out: *std.ArrayList([]const u8), depth: usize) !void {
    if (depth > 32) return;
    const entries = glob.listEntries(self.io, a, dir) catch return;
    for (entries) |e| {
        if (e.is_file) {
            if (wanted(e.name)) try out.append(a, try paths.join(a, &.{ dir, e.name }));
            continue;
        }
        if (!e.is_dir or e.is_symlink or e.name.len == 0 or e.name[0] == '.') continue;
        const skipped = for ([_][]const u8{ "build", "_deps", "node_modules" }) |s| {
            if (std.mem.eql(u8, e.name, s)) break true;
        } else false;
        if (!skipped) try filesBelow(self, a, try paths.join(a, &.{ dir, e.name }), wanted, out, depth + 1);
    }
}

fn isManifest(name: []const u8) bool {
    return std.mem.eql(u8, name, "fpm.toml");
}

fn isPfOrCmake(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".pf") or std.mem.eql(u8, name, "CMakeLists.txt");
}

/// A file and its AST
const Source = struct { file: *FortranFile, ast: *Ast };

/// The sources the request reads: the workspace's, else parsed once
const Sources = struct {
    server: *Server,
    a: Allocator,
    parsed: std.StringHashMapUnmanaged(?Source) = .empty,

    /// The file, or null when it cannot be read or parsed
    fn get(s: *Sources, path: []const u8) !?Source {
        if (s.server.workspace.get(path)) |f| if (f.ast) |ast| return .{ .file = f, .ast = ast };
        const gop = try s.parsed.getOrPut(s.a, path);
        if (!gop.found_existing) gop.value_ptr.* = s.parse(path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        return gop.value_ptr.*;
    }

    /// Owned by the request's arena, as everything it parses
    fn parse(s: *Sources, path: []const u8) !Source {
        const self = s.server;
        const f = try FortranFile.create(s.a, path, workspace.ppSuffixes(self));
        f.comment_markers = self.s.comment_markers.slice();
        _ = try f.loadFromDisk(self.io);
        const ast = try f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice(), workspace.parseOptions(self));
        return .{ .file = f, .ast = ast };
    }
};

/// The range of a line's bytes `start..end`
fn rangeOn(file: *const FortranFile, line: usize, start: usize, end: usize) lsp.Range {
    return .{
        .start = .{ .line = line, .character = Server.toLspCol(file, line, start) },
        .end = .{ .line = line, .character = Server.toLspCol(file, line, end) },
    };
}

/// The range of `name` on a line, or the line's start
fn nameRange(file: *const FortranFile, line: usize, name: []const u8) lsp.Range {
    const text = file.getLine(line, false) orelse "";
    const col = fpm.findWord(text, name) orelse return rangeOn(file, line, 0, 0);
    return rangeOn(file, line, col, col + name.len);
}

pub fn serveFpmTests(self: *Server, a: Allocator) !Value {
    var sources: Sources = .{ .server = self, .a = a };
    var manifests: std.ArrayList([]const u8) = .empty;
    try filesBelow(self, a, self.root_path, isManifest, &manifests, 0);
    var out: std.ArrayList(FpmProject) = .empty;
    for (manifests.items) |path| {
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(1 << 24)) catch continue;
        const root = paths.dirname(path);
        const m = try fpm.parseManifest(a, text);
        // the main programs of test/, which fpm makes targets of
        var programs: std.ArrayList([]const u8) = .empty;
        if (m.auto.get(.@"test")) {
            var files: std.ArrayList([]const u8) = .empty;
            try filesBelow(self, a, try paths.join(a, &.{ root, fpm.default_dirs.get(.@"test") }), project.isFortran, &files, 0);
            for (files.items) |f| {
                const src = (try sources.get(f)) orelse continue;
                if (fpm.mainProgram(src.ast) != null) try programs.append(a, f);
            }
        }
        var targets: std.ArrayList(FpmTarget) = .empty;
        for (try fpm.testTargets(a, m, root, programs.items)) |t| try targets.append(a, try fpmTarget(self, a, &sources, t));
        try out.append(a, .{
            .name = m.name orelse std.Io.Dir.path.basename(root),
            .uri = try paths.pathToUri(a, root),
            .targets = targets.items,
        });
    }
    return json.from(a, out.items);
}

/// A test target, with the suites its program makes and the tests their
/// collect procedures return, in the sources next to the program
fn fpmTarget(self: *Server, a: Allocator, sources: *Sources, t: fpm.TestTarget) !FpmTarget {
    const src = (try sources.get(t.main)) orelse return .{ .name = t.name };
    const uri = try paths.pathToUri(a, t.main);
    const program = fpm.mainProgram(src.ast);
    var target: FpmTarget = .{
        .name = t.name,
        .uri = uri,
        .range = if (program) |p| nameRange(src.file, p.sline - 1, p.name) else rangeOn(src.file, 0, 0, 0),
        .selectsTests = fpm.selectsTests(src.file),
    };
    const suites = try fpm.testDriveSuites(a, src.file);
    if (suites.len == 0) return target;
    var tests: std.StringHashMapUnmanaged(std.ArrayList(Item)) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    try filesBelow(self, a, paths.dirname(t.main), project.isFortran, &files, 0);
    for (files.items) |f| {
        const s = (try sources.get(f)) orelse continue;
        const file_uri = try paths.pathToUri(a, f);
        for (try fpm.testDriveTests(a, s.file, s.ast)) |u| {
            const collect = u.collect orelse continue;
            const gop = try tests.getOrPut(a, collect);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, .{ .name = u.name, .uri = file_uri, .range = rangeOn(s.file, u.line, u.start, u.end) });
        }
    }
    const out = try a.alloc(FpmSuite, suites.len);
    for (suites, out) |s, *o| o.* = .{
        .name = s.name,
        .uri = uri,
        .range = rangeOn(src.file, s.line, s.start, s.end),
        .tests = if (tests.get(s.collect)) |l| l.items else &.{},
    };
    target.suites = out;
    return target;
}

pub fn servePfunitTests(self: *Server, a: Allocator) !Value {
    var sources: Sources = .{ .server = self, .a = a };
    var found: std.ArrayList([]const u8) = .empty;
    try filesBelow(self, a, self.root_path, isPfOrCmake, &found, 0);
    var programs: std.ArrayList(PfProgram) = .empty;
    var unlisted: std.ArrayList(PfSuite) = .empty;
    var pf_files: std.ArrayList([]const u8) = .empty;
    for (found.items) |f| if (std.ascii.endsWithIgnoreCase(f, ".pf")) try pf_files.append(a, f);
    // the .pf files the programs list
    var listed: std.ArrayList([]const u8) = .empty;
    if (pf_files.items.len > 0) for (found.items) |cmake| {
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(cmake), "CMakeLists.txt")) continue;
        const text = Io.Dir.cwd().readFileAlloc(self.io, cmake, a, .limited(1 << 24)) catch continue;
        if (std.ascii.findIgnoreCase(text, "add_pfunit_ctest") == null) continue;
        const uri = try paths.pathToUri(a, cmake);
        for (try pfunit.parseAddPfunitCtest(a, text)) |p| {
            var suites: std.ArrayList(PfSuite) = .empty;
            for (p.sources) |rel| {
                const file = try std.Io.Dir.path.resolveAlloc(a, &.{ paths.dirname(cmake), rel });
                if (!paths.isFile(self.io, file)) continue;
                try listed.append(a, file);
                if (try pfSuite(a, &sources, file)) |s| try suites.append(a, s);
            }
            try programs.append(a, .{ .name = p.name, .uri = uri, .range = offsetRange(text, p.offset, p.name.len), .suites = suites.items });
        }
    };
    for (pf_files.items) |f| {
        const known = for (listed.items) |l| {
            if (fpm.samePath(l, f)) break true;
        } else false;
        if (!known) if (try pfSuite(a, &sources, f)) |s| try unlisted.append(a, s);
    }
    return json.from(a, .{ .programs = programs.items, .unlisted = unlisted.items });
}

/// The suite of a `.pf` file, when it can be read
fn pfSuite(a: Allocator, sources: *Sources, path: []const u8) !?PfSuite {
    const src = (try sources.get(path)) orelse return null;
    const base = std.Io.Dir.path.basename(path);
    const s = try pfunit.parsePf(a, src.file, src.ast, base[0 .. base.len - std.Io.Dir.path.extension(base).len]);
    const uri = try paths.pathToUri(a, path);
    const tests = try a.alloc(PfTest, s.tests.len);
    for (s.tests, tests) |t, *o| o.* = .{
        .name = t.name,
        .uri = uri,
        .range = rangeOn(src.file, t.line, t.start, t.end),
        .parameterized = t.parameterized,
    };
    return .{ .name = s.name, .uri = uri, .range = rangeOn(src.file, s.line, s.start, s.end), .tests = tests };
}

/// The range of `len` bytes at `offset` of a text
fn offsetRange(text: []const u8, offset: usize, len: usize) lsp.Range {
    const before = text[0..offset];
    const line = std.mem.count(u8, before, "\n");
    const bol = if (std.mem.findScalarLast(u8, before, '\n')) |i| i + 1 else 0;
    const eol = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
    const line_text = text[bol..eol];
    return .{
        .start = .{ .line = line, .character = str.byteToUtf16(line_text, offset - bol) },
        .end = .{ .line = line, .character = str.byteToUtf16(line_text, offset - bol + len) },
    };
}
