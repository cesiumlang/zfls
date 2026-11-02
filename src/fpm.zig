//! fpm (Fortran Package Manager) projects, for finding their tests
//! (`zfls/fpmTests`, server/tests.zig): the targets of `fpm.toml`, the test
//! targets fpm makes of them and of the programs in `test/`, and the suites
//! and tests of test-drive in the sources.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const project = @import("project.zig");
const objects = @import("objects.zig");
const parser = @import("parser.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;

pub const TargetKind = enum { executable, @"test", example };

/// A `[[executable]]`, `[[test]]` or `[[example]]` table of fpm.toml
pub const ManifestTarget = struct {
    kind: TargetKind,
    name: []const u8,
    source_dir: []const u8,
    main: []const u8,
};

pub const Manifest = struct {
    name: ?[]const u8 = null,
    targets: []const ManifestTarget = &.{},
    /// `auto-executables`, `auto-tests` and `auto-examples` of `[build]`
    auto: std.EnumArray(TargetKind, bool) = .initFill(true),
};

/// Where fpm looks for the programs of each kind of target
pub const default_dirs: std.EnumArray(TargetKind, []const u8) = .init(.{
    .executable = "app",
    .@"test" = "test",
    .example = "example",
});

/// The targets of fpm.toml and its `[build]` switches. Enough of TOML for
/// them: `[[kind]]` tables of string keys, and booleans in `[build]`.
pub fn parseManifest(a: Allocator, text: []const u8) !Manifest {
    var m: Manifest = .{};
    var targets: std.ArrayList(ManifestTarget) = .empty;
    var table: []const u8 = "";
    // the `[[kind]]` table being read: its kind, name, source-dir and main
    var kind: ?TargetKind = null;
    var name: ?[]const u8 = null;
    var source_dir: ?[]const u8 = null;
    var main: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (true) {
        const raw = lines.next();
        const line = if (raw) |r| str.strip(project.stripTomlComment(r)) else "";
        const header = if (raw != null) tableHeader(line) else null;
        // the end of a target's table
        if (raw == null or header != null) {
            if (kind) |k| if (name) |n| try targets.append(a, .{
                .kind = k,
                .name = n,
                .source_dir = source_dir orelse default_dirs.get(k),
                .main = main orelse "main.f90",
            });
            kind = null;
            name = null;
            source_dir = null;
            main = null;
        }
        if (raw == null) break;
        if (header) |h| {
            table = h.name;
            if (h.array) kind = std.meta.stringToEnum(TargetKind, h.name);
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = str.rstrip(line[0..eq]);
        const value = str.strip(line[eq + 1 ..]);
        if (key.len == 0 or value.len == 0 or !allOf(key, "-")) continue;
        const string = tomlString(value);
        if (kind != null) {
            if (string) |s| {
                if (std.mem.eql(u8, key, "name")) {
                    name = s;
                } else if (std.mem.eql(u8, key, "source-dir")) {
                    source_dir = s;
                } else if (std.mem.eql(u8, key, "main")) {
                    main = s;
                }
            }
        } else if (table.len == 0 and std.mem.eql(u8, key, "name")) {
            if (string) |s| m.name = s;
        } else if (std.mem.eql(u8, table, "build")) {
            const switches = [_]struct { []const u8, TargetKind }{
                .{ "auto-executables", .executable },
                .{ "auto-tests", .@"test" },
                .{ "auto-examples", .example },
            };
            for (switches) |sw| if (std.mem.eql(u8, key, sw[0])) m.auto.set(sw[1], !std.mem.eql(u8, value, "false"));
        }
    }
    m.targets = targets.items;
    return m;
}

/// `[name]` or `[[name]]`
fn tableHeader(line: []const u8) ?struct { name: []const u8, array: bool } {
    if (std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]") and line.len > 4) {
        const n = str.strip(line[2 .. line.len - 2]);
        return if (n.len > 0 and allOf(n, "-")) .{ .name = n, .array = true } else null;
    }
    if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "]") and line.len > 2) {
        const n = str.strip(line[1 .. line.len - 1]);
        return if (n.len > 0 and allOf(n, "-.")) .{ .name = n, .array = false } else null;
    }
    return null;
}

/// Whether `s` has only word characters and those of `more`
fn allOf(s: []const u8, more: []const u8) bool {
    for (s) |c| if (!isWord(c) and std.mem.findScalar(u8, more, c) == null) return false;
    return true;
}

/// The text of a TOML string, `"..."` or `'...'`
fn tomlString(value: []const u8) ?[]const u8 {
    if (value.len < 2) return null;
    const q = value[0];
    if ((q != '"' and q != '\'') or value[value.len - 1] != q) return null;
    const inner = value[1 .. value.len - 1];
    return if (std.mem.findScalar(u8, inner, q) == null) inner else null;
}

pub fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// A test target and the file of its main program
pub const TestTarget = struct { name: []const u8, main: []const u8 };

/// The test targets of the project in `root`, by name: the `[[test]]`
/// tables of fpm.toml, and with `auto-tests` (the default) a target for
/// each of `programs` (the files of `test/` and below that hold a main
/// program) that is no table's `main`, named after its file, as fpm makes
/// them
pub fn testTargets(a: Allocator, m: Manifest, root: []const u8, programs: []const []const u8) ![]TestTarget {
    var out: std.ArrayList(TestTarget) = .empty;
    for (m.targets) |t| {
        if (t.kind != .@"test" or hasTarget(out.items, t.name)) continue;
        try out.append(a, .{ .name = t.name, .main = try std.Io.Dir.path.resolveAlloc(a, &.{ root, t.source_dir, t.main }) });
    }
    const explicit = out.items.len;
    if (m.auto.get(.@"test")) for (programs) |p| {
        const file = try std.Io.Dir.path.resolveAlloc(a, &.{p});
        const main = for (out.items[0..explicit]) |t| {
            if (samePath(t.main, file)) break true;
        } else false;
        if (main) continue;
        const base = std.Io.Dir.path.basename(file);
        const name = base[0 .. base.len - std.Io.Dir.path.extension(base).len];
        if (!hasTarget(out.items, name)) try out.append(a, .{ .name = name, .main = file });
    };
    std.mem.sort(TestTarget, out.items, {}, struct {
        fn lt(_: void, x: TestTarget, y: TestTarget) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out.items;
}

fn hasTarget(targets: []const TestTarget, name: []const u8) bool {
    for (targets) |t| if (std.mem.eql(u8, t.name, name)) return true;
    return false;
}

/// Whether two normalized paths name the same file (ignoring case on
/// Windows)
pub fn samePath(x: []const u8, y: []const u8) bool {
    return if (builtin.target.os.tag == .windows) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
}

/// The main program of a file, when it has one
pub fn mainProgram(ast: *Ast) ?*Obj {
    for (ast.scope_list.items) |s| if (s.kind == .program and s != ast.none_scope) return s;
    return null;
}

/// A test suite of test-drive: `new_testsuite("name", collect)`, with the
/// 0-based line and the byte columns of its name
pub const Suite = struct { name: []const u8, collect: []const u8, line: usize, start: usize, end: usize };

/// A test of test-drive: `new_unittest("name", ...)`, with the collect
/// procedure that returns it (in lowercase): the subroutine it is in
pub const UnitTest = struct { name: []const u8, collect: ?[]const u8, line: usize, start: usize, end: usize };

/// The suites that `file` makes (`new_testsuite` calls)
pub fn testDriveSuites(a: Allocator, file: *const FortranFile) ![]Suite {
    var out: std.ArrayList(Suite) = .empty;
    for (0..file.nLines()) |i| {
        const code = file.stripComment(file.getLine(i, false) orelse continue);
        var calls: Calls = .{ .code = code, .name = "new_testsuite" };
        while (calls.next()) |c| {
            // `, collect`
            var j = skipSpaces(code, c.after);
            if (j >= code.len or code[j] != ',') continue;
            j = skipSpaces(code, j + 1);
            const from = j;
            while (j < code.len and isWord(code[j])) j += 1;
            if (j == from) continue;
            try out.append(a, .{
                .name = code[c.start..c.end],
                .collect = try std.ascii.allocLowerString(a, code[from..j]),
                .line = i,
                .start = c.start,
                .end = c.end,
            });
        }
    }
    return out.items;
}

/// The tests in `file` (`new_unittest` calls), each with the subroutine
/// around it in `ast`
pub fn testDriveTests(a: Allocator, file: *const FortranFile, ast: *Ast) ![]UnitTest {
    var out: std.ArrayList(UnitTest) = .empty;
    for (0..file.nLines()) |i| {
        const code = file.stripComment(file.getLine(i, false) orelse continue);
        var calls: Calls = .{ .code = code, .name = "new_unittest" };
        while (calls.next()) |c| {
            var scope = ast.getInnerScope(i + 1);
            const collect: ?*Obj = while (scope) |s| : (scope = s.parent) {
                if (s.kind == .subroutine) break s;
            } else null;
            try out.append(a, .{
                .name = code[c.start..c.end],
                .collect = if (collect) |s| try std.ascii.allocLowerString(a, s.name) else null,
                .line = i,
                .start = c.start,
                .end = c.end,
            });
        }
    }
    return out.items;
}

/// The calls of a procedure whose first argument is a string literal:
/// `name("text"`, the text's columns and the column after its quote
const Calls = struct {
    code: []const u8,
    name: []const u8,
    pos: usize = 0,

    fn next(self: *Calls) ?struct { start: usize, end: usize, after: usize } {
        const code = self.code;
        while (std.ascii.findIgnoreCasePos(code, self.pos, self.name)) |at| {
            self.pos = at + self.name.len;
            if (at > 0 and isWord(code[at - 1])) continue;
            var j = skipSpaces(code, self.pos);
            if (j >= code.len or code[j] != '(') continue;
            j = skipSpaces(code, j + 1);
            if (j >= code.len or (code[j] != '"' and code[j] != '\'')) continue;
            const close = std.mem.findScalarPos(u8, code, j + 1, code[j]) orelse continue;
            if (close == j + 1) continue;
            self.pos = close + 1;
            return .{ .start = j + 1, .end = close, .after = close + 1 };
        }
        return null;
    }
};

fn skipSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// Whether a test program takes a suite and a test on its command line, as
/// test-drive's template does (`select_suite`, `run_selected`)
pub fn selectsTests(file: *const FortranFile) bool {
    var suite = false;
    var selected = false;
    for (0..file.nLines()) |i| {
        const code = file.stripComment(file.getLine(i, false) orelse continue);
        suite = suite or findWord(code, "select_suite") != null;
        selected = selected or findWord(code, "run_selected") != null;
    }
    return suite and selected;
}

/// The column of `word` in `text` (in any case), as a word
pub fn findWord(text: []const u8, word: []const u8) ?usize {
    if (word.len == 0) return null;
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, from, word)) |at| : (from = at + 1) {
        const end = at + word.len;
        if ((at == 0 or !isWord(text[at - 1])) and (end == text.len or !isWord(text[end]))) return at;
    }
    return null;
}

// --------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A file of `text`, parsed (`arena` owns both)
pub fn parseForTest(arena: Allocator, name: []const u8, text: []const u8) !struct { file: *FortranFile, ast: *Ast } {
    @import("patterns.zig").init();
    const f = try FortranFile.create(arena, name, null);
    _ = try f.setText(text);
    return .{ .file = f, .ast = try f.parse(testing.io, null, &.{}, .{}) };
}

const manifest_text =
    \\
    \\name = "demo"   # the package
    \\version = "0.1.0"
    \\
    \\[build]
    \\auto-examples = false
    \\
    \\[[executable]]
    \\name = "second"
    \\source-dir = "app2"
    \\main = "main.f90"
    \\
    \\[[test]]
    \\name = 'unit'
    \\source-dir = "tests/unit"
    \\
    \\[dev-dependencies]
    \\test-drive.git = "https://github.com/fortran-lang/test-drive"
    \\
;

test "fpm.toml: the name, the targets and the auto-discovery switches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseManifest(arena.allocator(), manifest_text);
    try testing.expectEqualStrings("demo", m.name.?);
    try testing.expectEqual(@as(usize, 2), m.targets.len);
    try testing.expectEqual(TargetKind.executable, m.targets[0].kind);
    try testing.expectEqualStrings("second", m.targets[0].name);
    try testing.expectEqualStrings("app2", m.targets[0].source_dir);
    try testing.expectEqualStrings("main.f90", m.targets[0].main);
    try testing.expectEqual(TargetKind.@"test", m.targets[1].kind);
    try testing.expectEqualStrings("unit", m.targets[1].name);
    try testing.expectEqualStrings("tests/unit", m.targets[1].source_dir);
    try testing.expectEqualStrings("main.f90", m.targets[1].main);
    try testing.expect(m.auto.get(.executable) and m.auto.get(.@"test") and !m.auto.get(.example));
}

test "the test targets: fpm.toml's, then the programs of test/ named after their files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parseManifest(a, manifest_text ++ "[[test]]\nname = \"own\"\nsource-dir = \"test\"\nmain = \"own_main.f90\"\n");
    const root = if (builtin.target.os.tag == .windows) "C:\\p" else "/p";
    const p = std.Io.Dir.path.resolveAlloc;
    const programs = [_][]const u8{
        try p(a, &.{ root, "test", "check.F90" }),
        try p(a, &.{ root, "test", "sub", "more.f90" }),
        // the `main` of a table: that target's
        try p(a, &.{ root, "test", "own_main.f90" }),
    };
    const targets = try testTargets(a, m, root, &programs);
    try testing.expectEqual(@as(usize, 4), targets.len);
    const names = [_][]const u8{ "check", "more", "own", "unit" };
    for (names, targets) |n, t| try testing.expectEqualStrings(n, t.name);
    try testing.expectEqualStrings(try p(a, &.{ root, "tests", "unit", "main.f90" }), targets[3].main);
    try testing.expectEqualStrings(programs[1], targets[1].main);
    // auto-tests = false: the tables' only
    const off = try parseManifest(a, "[build]\nauto-tests = false\n[[test]]\nname = \"t\"\n");
    const only = try testTargets(a, off, root, &programs);
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings(try p(a, &.{ root, "test", "main.f90" }), only[0].main);
}

const suite_text =
    \\module suite_math
    \\  use testdrive, only : new_unittest, unittest_type, error_type, check
    \\contains
    \\  subroutine collect_math(testsuite)
    \\    type(unittest_type), allocatable, intent(out) :: testsuite(:)
    \\    testsuite = [ &
    \\      new_unittest("adds", test_adds), &
    \\      ! new_unittest("commented", test_x), &
    \\      new_unittest('fails', test_fails, should_fail=.true.) &
    \\      ]
    \\  end subroutine collect_math
    \\end module
    \\program tester
    \\  use testdrive, only : run_testsuite, new_testsuite, testsuite_type
    \\  testsuites = [new_testsuite("math", collect_math), &
    \\    new_testsuite("Strings", Collect_Strings)]
    \\end program
    \\
;

test "test-drive's suites and tests in the sources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try parseForTest(a, "/w/tester.f90", suite_text);
    const suites = try testDriveSuites(a, src.file);
    try testing.expectEqual(@as(usize, 2), suites.len);
    try testing.expectEqualStrings("math", suites[0].name);
    try testing.expectEqualStrings("collect_math", suites[0].collect);
    try testing.expectEqual(@as(usize, 14), suites[0].line);
    try testing.expectEqual(@as(usize, 31), suites[0].start);
    try testing.expectEqualStrings("Strings", suites[1].name);
    try testing.expectEqualStrings("collect_strings", suites[1].collect);
    try testing.expectEqual(@as(usize, 15), suites[1].line);
    const tests = try testDriveTests(a, src.file, src.ast);
    try testing.expectEqual(@as(usize, 2), tests.len);
    try testing.expectEqualStrings("adds", tests[0].name);
    try testing.expectEqual(@as(usize, 6), tests[0].line);
    try testing.expectEqualStrings("collect_math", tests[0].collect.?);
    try testing.expectEqualStrings("fails", tests[1].name);
    try testing.expectEqual(@as(usize, 8), tests[1].line);
    try testing.expectEqualStrings("collect_math", tests[1].collect.?);
    try testing.expectEqual(@as(usize, 12), mainProgram(src.ast).?.sline - 1);
    try testing.expect(!selectsTests(src.file));
    const sel = try parseForTest(a, "/w/main.f90", "program p\n  is = select_suite(testsuites, name)\n  call run_selected(testsuites(is)%collect, t, u, stat)\nend program p\n");
    try testing.expect(selectsTests(sel.file));
}

test "test-drive: a collect procedure that ends with a bare `end`, or is a module procedure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try parseForTest(a, "/w/s.f90",
        \\module s
        \\contains
        \\  module subroutine collect_a(testsuite)
        \\    testsuite = [new_unittest("one", t1)]
        \\  end
        \\  subroutine other()
        \\  end subroutine
        \\end module
        \\call x(new_unittest("loose", t))
        \\
    );
    const tests = try testDriveTests(a, src.file, src.ast);
    try testing.expectEqual(@as(usize, 2), tests.len);
    try testing.expectEqualStrings("collect_a", tests[0].collect.?);
    try testing.expect(tests[1].collect == null);
    try testing.expect(mainProgram(src.ast) == null);
}
