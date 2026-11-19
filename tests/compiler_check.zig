//! The compiler check (`compiler_diagnostics`) against a real compiler,
//! LFortran: zfls, started as an editor starts it, checks the files of
//! tests/compiler when they are opened, and each must get the compiler's
//! errors it has and none of those it has not: a program that uses a
//! module of the workspace (compiled first, for its .mod file), implicit
//! typing and an external procedure, fixed form, the preprocessor with a
//! definition of `pp_defs`, an include directory of `include_dirs`, and
//! the unsaved text of an edit (`compiler_on_change`)
//! (`zig build test-compiler`). Skipped without LFortran.
//!
//!     compiler_check --zfls ZFLS [--lfortran LFORTRAN]
//!
//! LFORTRAN in the environment names it too.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const fixtures = "tests/compiler";
/// How long a file's compiler diagnostics may take
const timeout_ms = 120_000;

/// A message the compiler must give: on `line` (1-based), containing `text`
const Want = struct { line: i64, text: []const u8 };

/// A file of the fixtures, what the compiler must say about it, and what
/// it must not say (texts of any of its messages)
const Case = struct {
    file: []const u8,
    want: []const Want,
    absent: []const []const u8 = &.{},
};

const cases = [_]Case{
    // the module's .mod file exists, with its type-bound procedure; every
    // error, not only the first
    .{ .file = "main.f90", .want = &.{
        .{ .line = 8, .text = "Variable 'undeclared_main' is not declared" },
        .{ .line = 9, .text = "Variable 'also_undeclared' is not declared" },
    }, .absent = &.{"modfile"} },
    // implicit typing and implicit interfaces, but no implicit casting of
    // arguments
    .{ .file = "implicit.f90", .want = &.{
        .{ .line = 5, .text = "Type mismatch in argument" },
    }, .absent = &.{ "is not declared", "not found" } },
    .{ .file = "legacy.f", .want = &.{
        .{ .line = 6, .text = "Type mismatch in argument" },
    }, .absent = &.{ "is not declared", "not found" } },
    // ZFLS_DEFINED, of pp_defs, declares `from_define`
    .{ .file = "defines.F90", .want = &.{
        .{ .line = 8, .text = "Variable 'undeclared_defines' is not declared" },
    }, .absent = &.{"from_define"} },
    // consts.inc is in include_dirs
    .{ .file = "includes.f90", .want = &.{
        .{ .line = 6, .text = "Variable 'undeclared_includes' is not declared" },
    }, .absent = &.{ "Include file", "included_n" } },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var lfortran: []const u8 = init.environ_map.get("LFORTRAN") orelse "lfortran";
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--lfortran")) {
            lfortran = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: compiler_check --zfls ZFLS [--lfortran LFORTRAN]\n", .{});
        return 2;
    }
    const version = std.process.run(a, io, .{ .argv = &.{ lfortran, "--version" } }) catch {
        std.debug.print("skipped: no {s}\n", .{lfortran});
        return 0;
    };
    std.debug.print("{s}", .{firstLine(version.stdout)});

    // absolute, with its drive on Windows (Git Bash's TMPDIR is `/c/...`),
    // so that the root's URI names the same directory
    const tmp = try Io.Dir.cwd().realPathFileAlloc(io, try lsp.tempDir(io, a, init.environ_map, "zfls_compiler_"), a);
    const work = try std.Io.Dir.path.join(a, &.{ tmp, "work" });
    try lsp.copyTree(io, a, fixtures, work);
    // zfls's cache (the copies of unsaved text) in the test's directory
    var env = try init.environ_map.clone(a);
    const cache = try std.Io.Dir.path.join(a, &.{ tmp, "cache" });
    try env.put("XDG_CACHE_HOME", cache);
    try env.put("LOCALAPPDATA", cache);

    const c = try lsp.Client.startEnv(io, init.gpa, &.{ zfls_exe.?, "--disable_index_cache" }, null, &env);
    defer c.deinit();
    errdefer c.kill();
    const initialized = try c.request("initialize", .{
        .rootUri = try zfls.paths.pathToUri(a, work),
        .rootPath = work,
        // an object (`.{}` would be an empty array)
        .capabilities = struct {}{},
        .initializationOptions = .{
            .compiler_diagnostics = "lfortran",
            // a name is looked for on the PATH; zfls takes a relative
            // path as relative to the root
            .compiler_path = if (std.mem.findAny(u8, lfortran, "/\\") != null) try Io.Dir.cwd().realPathFileAlloc(io, lfortran, a) else null,
            .compiler_mod_dir = "build/mod",
            .include_dirs = &[_][]const u8{"include"},
            .pp_defs = .{ .ZFLS_DEFINED = "" },
            .compiler_on_change = true,
            .compiler_change_delay = 200,
        },
    });
    if (initialized.object.get("error")) |e| {
        std.debug.print("FAIL initialize: {s}\n", .{try std.json.Stringify.valueAlloc(a, e, .{})});
        return 1;
    }
    try c.send("initialized", struct {}{}, null);

    var failures: std.ArrayList([]const u8) = .empty;
    for (cases) |case| {
        const path = try std.Io.Dir.path.join(a, &.{ work, case.file });
        const uri = try zfls.paths.pathToUri(a, path);
        try c.send("textDocument/didOpen", .{ .textDocument = .{
            .uri = uri,
            .languageId = "fortran",
            .version = 1,
            .text = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)),
        } }, null);
        const diags = try waitFor(io, a, c, uri, null);
        try expectCase(a, &failures, case.file, diags, case.want, case.absent);
    }

    // an unsaved edit: its text is checked, from a copy
    {
        const path = try std.Io.Dir.path.join(a, &.{ work, "main.f90" });
        const uri = try zfls.paths.pathToUri(a, path);
        const text = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        const edited = try std.mem.replaceOwned(u8, a, text, "undeclared_main", "undeclared_edit");
        try c.send("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = 2 },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = edited }},
        }, null);
        const diags = try waitFor(io, a, c, uri, "undeclared_edit");
        try expectCase(a, &failures, "main.f90 (edited)", diags, &.{
            .{ .line = 8, .text = "Variable 'undeclared_edit' is not declared" },
        }, &.{"undeclared_main"});
    }

    const term = try c.close();
    if (!term.success()) try failures.append(a, try a.print("zfls ended with {s}", .{try lsp.termText(a, term)}));
    for (failures.items) |f| std.debug.print("FAIL {s}\n", .{f});
    if (failures.items.len > 0) {
        std.debug.print("zfls's stderr:\n{s}\n", .{c.stderr.items});
        return 1;
    }
    std.debug.print("ok   {d} files and an edit checked with LFortran\n", .{cases.len});
    return 0;
}

fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, s, '\n') orelse s.len;
    return s[0..@min(end + 1, s.len)];
}

/// The compiler's diagnostics of `uri`, once there are some (that contain
/// `needle`, when given); an empty list after the timeout
fn waitFor(io: Io, a: Allocator, c: *lsp.Client, uri: []const u8, needle: ?[]const u8) ![]const Value {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        const ours = try compilerDiagnostics(a, c.diagnosticsOf(uri));
        if (ours.len > 0) {
            const found = if (needle) |n| for (ours) |d| {
                if (std.mem.find(u8, message(d), n) != null) break true;
            } else false else true;
            if (found) return ours;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return &.{};
}

/// The diagnostics of `list` whose source is the compiler
fn compilerDiagnostics(a: Allocator, list: Value) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    if (list != .array) return &.{};
    for (list.array.items) |d| {
        if (d != .object) continue;
        const source = d.object.get("source") orelse continue;
        if (source == .string and std.mem.eql(u8, source.string, "lfortran")) try out.append(a, d);
    }
    return out.items;
}

fn message(d: Value) []const u8 {
    const m = d.object.get("message") orelse return "";
    return if (m == .string) m.string else "";
}

/// The 1-based line of a diagnostic
fn lineOf(d: Value) i64 {
    const range = d.object.get("range") orelse return 0;
    if (range != .object) return 0;
    const start = range.object.get("start") orelse return 0;
    if (start != .object) return 0;
    const line = start.object.get("line") orelse return 0;
    return if (line == .integer) line.integer + 1 else 0;
}

fn expectCase(a: Allocator, failures: *std.ArrayList([]const u8), name: []const u8, diags: []const Value, want: []const Want, absent: []const []const u8) !void {
    if (diags.len == 0) {
        try failures.append(a, try a.print("{s}: no diagnostics from LFortran", .{name}));
        return;
    }
    for (want) |w| {
        for (diags) |d| {
            if (lineOf(d) == w.line and std.mem.find(u8, message(d), w.text) != null) break;
        } else try failures.append(a, try a.print("{s}: no \"{s}\" on line {d}; got:{s}", .{ name, w.text, w.line, try listing(a, diags) }));
    }
    for (absent) |x| for (diags) |d| if (std.mem.find(u8, message(d), x) != null) {
        try failures.append(a, try a.print("{s}: line {d}: \"{s}\", which it should not have", .{ name, lineOf(d), message(d) }));
    };
}

fn listing(a: Allocator, diags: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (diags) |d| try out.print(a, "\n    {d}: {s}", .{ lineOf(d), message(d) });
    return out.items;
}

test "a diagnostic's line and message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"range":{"start":{"line":7,"character":10}},"message":"Variable 'x' is not declared","source":"lfortran"},
        \\ {"range":{"start":{"line":0,"character":0}},"message":"own","source":"zfls"}]
    , .{});
    const ours = try compilerDiagnostics(a, list);
    try std.testing.expectEqual(@as(usize, 1), ours.len);
    try std.testing.expectEqual(@as(i64, 8), lineOf(ours[0]));
    var failures: std.ArrayList([]const u8) = .empty;
    try expectCase(a, &failures, "f", ours, &.{.{ .line = 8, .text = "'x' is not declared" }}, &.{"modfile"});
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);
    try expectCase(a, &failures, "f", ours, &.{.{ .line = 9, .text = "'x'" }}, &.{"'x'"});
    try std.testing.expectEqual(@as(usize, 2), failures.items.len);
}
