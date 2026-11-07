//! pFUnit projects, for finding their tests (`zfls/pfunitTests`,
//! server/tests.zig): the suite and tests of a `.pf` file, and the test
//! programs that CMake's `add_pfunit_ctest` makes of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const objects = @import("objects.zig");
const parser = @import("parser.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const fpm = @import("fpm.zig");
const isWord = fpm.isWord;
const findWord = fpm.findWord;

/// A test: the first subroutine after an `@test` (0-based line and byte
/// columns of the `@test`)
pub const Test = struct {
    name: []const u8,
    line: usize,
    start: usize,
    end: usize,
    /// Run once per parameter (`testParameters`, `cases`, `npes`, or of a
    /// `@testCase` with parameters), so reported under names of its own
    parameterized: bool,
};

pub const Suite = struct {
    /// As pFUnit names it: `@suite(name=...)`, else the module's name, else
    /// the file's, with `_suite`
    name: []const u8,
    /// The module (0-based line and byte columns of its name), or line 0
    line: usize = 0,
    start: usize = 0,
    end: usize = 0,
    tests: []const Test,
};

/// The suite and tests of a `.pf` file, read as pFUnit's preprocessor
/// (funitproc) reads them: the first subroutine after each `@test` is a
/// test. The module and the subroutines are those of `ast`, the file's.
pub fn parsePf(a: Allocator, file: *const FortranFile, ast: *Ast, base_name: []const u8) !Suite {
    var named: ?[]const u8 = null;
    // the subroutines by their first line
    var subroutines: std.AutoHashMapUnmanaged(usize, *Obj) = .empty;
    var module: ?*Obj = null;
    for (ast.scope_list.items) |s| switch (s.kind) {
        .subroutine => try subroutines.put(a, s.sline, s),
        .module => if (module == null) {
            module = s;
        },
        else => {},
    };
    var tests: std.ArrayList(Test) = .empty;
    // the last `@test` not followed by its subroutine yet
    var pending: ?Test = null;
    var case_parameterized = false;
    for (0..file.nLines()) |i| {
        const line = file.getLine(i, false) orelse continue;
        if (subroutines.get(i + 1)) |sub| if (pending) |p| {
            var t = p;
            t.name = sub.name;
            t.parameterized = t.parameterized or case_parameterized;
            try tests.append(a, t);
            pending = null;
        };
        const at = str.lstrip(line);
        if (at.len < 2 or at[0] != '@') continue;
        var n: usize = 1;
        while (n < at.len and isWord(at[n])) n += 1;
        const word = at[1..n];
        const rest = str.strip(at[n..]);
        if (std.ascii.eqlIgnoreCase(word, "suite")) {
            if (suiteName(rest)) |s| named = s;
        } else if (std.ascii.eqlIgnoreCase(word, "testcase")) {
            case_parameterized = hasKey(rest, &.{ "testParameters", "cases" });
        } else if (std.ascii.eqlIgnoreCase(word, "testparameter")) {
            case_parameterized = true;
        } else if (std.ascii.eqlIgnoreCase(word, "test") or std.ascii.eqlIgnoreCase(word, "mpitest")) {
            if (rest.len > 0 and (rest[0] != '(' or rest[rest.len - 1] != ')')) continue;
            const start = line.len - at.len;
            pending = .{
                .name = "",
                .line = i,
                .start = start,
                .end = start + n,
                .parameterized = hasKey(rest, &.{ "testParameters", "cases", "npes" }),
            };
        }
    }
    var suite: Suite = .{
        .name = named orelse try std.mem.concat(a, u8, &.{ if (module) |m| m.name else base_name, "_suite" }),
        .tests = tests.items,
    };
    if (module) |m| {
        suite.line = m.sline - 1;
        if (file.getLine(suite.line, false)) |text| if (findWord(text, m.name)) |col| {
            suite.start = col;
            suite.end = col + m.name.len;
        };
    }
    return suite;
}

/// The name of `(name="...")`, the rest of `@suite`
fn suiteName(rest: []const u8) ?[]const u8 {
    if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return null;
    const inner = str.strip(rest[1 .. rest.len - 1]);
    if (inner.len < 4 or !std.ascii.startsWithIgnoreCase(inner, "name")) return null;
    const after = str.lstrip(inner[4..]);
    if (after.len < 3 or after[0] != '=') return null;
    const value = str.lstrip(after[1..]);
    if (value.len < 3 or (value[0] != '"' and value[0] != '\'') or value[value.len - 1] != value[0]) return null;
    const name = value[1 .. value.len - 1];
    for (name) |c| if (!isWord(c)) return null;
    return name;
}

/// Whether an annotation's arguments set one of `keys` (`key=`)
fn hasKey(args: []const u8, keys: []const []const u8) bool {
    for (keys) |k| {
        var from: usize = 0;
        while (std.ascii.findIgnoreCasePos(args, from, k)) |at| : (from = at + 1) {
            if (at > 0 and isWord(args[at - 1])) continue;
            const after = str.lstrip(args[at + k.len ..]);
            if (after.len > 0 and after[0] == '=') return true;
        }
    }
    return false;
}

/// A test program of `add_pfunit_ctest`: its name (CMake's target and
/// CTest's test), at a byte offset of the CMakeLists.txt, and its `.pf`
/// files as written (relative to the CMakeLists.txt's directory, or
/// absolute)
pub const Program = struct { name: []const u8, offset: usize, sources: []const []const u8 };

/// The keywords of `add_pfunit_ctest`, which end its TEST_SOURCES
const keywords = [_][]const u8{
    "TEST_SOURCES",      "OTHER_SOURCES",    "LINK_LIBRARIES", "REGISTRY",
    "EXTRA_USE",         "EXTRA_INITIALIZE", "EXTRA_FINALIZE", "MAX_PES",
    "WORKING_DIRECTORY", "LABELS",           "TIMEOUT",        "ENV",
    "PROPERTIES",
};

/// A word of CMake arguments, without quotes, at its offset
const Word = struct { text: []const u8, offset: usize };

/// The `add_pfunit_ctest` calls of a CMakeLists.txt, with their
/// TEST_SOURCES; `${var}` of a plain `set(var ...)` in the same file is
/// expanded, and `${CMAKE_CURRENT_SOURCE_DIR}/` dropped
pub fn parseAddPfunitCtest(a: Allocator, cmake: []const u8) ![]Program {
    // the comments blanked out, so that offsets stay
    const text = try a.dupe(u8, cmake);
    var in_comment = false;
    for (text) |*c| {
        if (c.* == '\n') {
            in_comment = false;
        } else if (c.* == '#') in_comment = true;
        if (in_comment) c.* = ' ';
    }
    var vars: std.StringHashMapUnmanaged([]const Word) = .empty;
    var sets: Commands = .{ .text = text, .name = "set" };
    while (sets.next()) |args| {
        // `name values...`
        var j: usize = 0;
        while (j < args.text.len and isWord(args.text[j])) j += 1;
        if (j == 0 or j == args.text.len or !std.ascii.isWhitespace(args.text[j])) continue;
        try vars.put(a, args.text[0..j], try words(a, args.text[j..], 0));
    }
    var out: std.ArrayList(Program) = .empty;
    var calls: Commands = .{ .text = text, .name = "add_pfunit_ctest" };
    while (calls.next()) |args| {
        const all = try words(a, args.text, args.offset);
        if (all.len == 0) continue;
        var sources: std.ArrayList([]const u8) = .empty;
        var in_sources = false;
        for (all[1..]) |w| {
            const keyword = for (keywords) |k| {
                if (std.ascii.eqlIgnoreCase(k, w.text)) break true;
            } else false;
            if (keyword) {
                in_sources = std.ascii.eqlIgnoreCase(w.text, "TEST_SOURCES");
            } else if (in_sources) {
                try expand(a, &vars, w.text, 0, &sources);
            }
        }
        try out.append(a, .{ .name = all[0].text, .offset = all[0].offset, .sources = sources.items });
    }
    return out.items;
}

/// The `.pf` files of a word: a `${var}`'s values, or the word without
/// `${CMAKE_CURRENT_SOURCE_DIR}/`
fn expand(a: Allocator, vars: *const std.StringHashMapUnmanaged([]const Word), w: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.startsWith(u8, w, "${") and std.mem.endsWith(u8, w, "}") and depth < 5) {
        if (vars.get(w[2 .. w.len - 1])) |values| {
            for (values) |v| try expand(a, vars, v.text, depth + 1, out);
            return;
        }
    }
    var file = w;
    for ([_][]const u8{ "${CMAKE_CURRENT_SOURCE_DIR}/", "${CMAKE_CURRENT_LIST_DIR}/" }) |prefix| {
        if (std.mem.startsWith(u8, file, prefix)) file = file[prefix.len..];
    }
    if (std.ascii.endsWithIgnoreCase(file, ".pf")) try out.append(a, file);
}

/// The words of CMake arguments, without quotes; `base` is the offset of
/// `args`
fn words(a: Allocator, args: []const u8, base: usize) ![]const Word {
    var out: std.ArrayList(Word) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < args.len and std.ascii.isWhitespace(args[i])) i += 1;
        if (i >= args.len) break;
        if (args[i] == '"') if (std.mem.findScalarPos(u8, args, i + 1, '"')) |close| {
            try out.append(a, .{ .text = args[i + 1 .. close], .offset = base + i + 1 });
            i = close + 1;
            continue;
        };
        const from = i;
        while (i < args.len and !std.ascii.isWhitespace(args[i])) i += 1;
        try out.append(a, .{ .text = args[from..i], .offset = base + from });
    }
    return out.items;
}

/// The calls of a CMake command: the text between its parentheses, at its
/// offset
const Commands = struct {
    text: []const u8,
    name: []const u8,
    pos: usize = 0,

    fn next(self: *Commands) ?Word {
        const t = self.text;
        while (std.ascii.findIgnoreCasePos(t, self.pos, self.name)) |at| {
            self.pos = at + self.name.len;
            if (at > 0 and isWord(t[at - 1])) continue;
            var j = self.pos;
            while (j < t.len and std.ascii.isWhitespace(t[j])) j += 1;
            if (j >= t.len or t[j] != '(') continue;
            j += 1;
            while (j < t.len and std.ascii.isWhitespace(t[j])) j += 1;
            const close = std.mem.findScalarPos(u8, t, j, ')') orelse return null;
            self.pos = close + 1;
            return .{ .text = t[j..close], .offset = j };
        }
        return null;
    }
};

// --------------------------------------------------------------------------
// Tests

const testing = std.testing;
const parseForTest = fpm.parseForTest;

const pf_text =
    \\module test_vectors
    \\   use funit
    \\   use vectors
    \\   implicit none
    \\contains
    \\
    \\   @test
    \\   subroutine test_norm()
    \\      @assertEqual(5.0, norm([3.0, 4.0]))
    \\   end subroutine test_norm
    \\
    \\   ! @test in a comment does not count
    \\   @test(testParameters={[1, 2]})
    \\   subroutine test_cases(this)
    \\      class (MyCase), intent(inout) :: this
    \\   end subroutine test_cases
    \\
    \\   @Test
    \\   subroutine Test_Dot
    \\   end subroutine Test_Dot
    \\
    \\   subroutine helper()
    \\   end subroutine helper
    \\end module test_vectors
    \\
;

fn pfSuite(a: Allocator, text: []const u8, base: []const u8) !Suite {
    const src = try parseForTest(a, "/w/t.pf", text);
    return parsePf(a, src.file, src.ast, base);
}

test "a .pf file: its suite (the module's name) and @test procedures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try pfSuite(arena.allocator(), pf_text, "test_vectors");
    try testing.expectEqualStrings("test_vectors_suite", s.name);
    try testing.expectEqual(@as(usize, 0), s.line);
    try testing.expectEqual(@as(usize, 7), s.start);
    try testing.expectEqual(@as(usize, 3), s.tests.len);
    const want = [_]struct { []const u8, usize, bool }{
        .{ "test_norm", 6, false },
        .{ "test_cases", 12, true },
        .{ "Test_Dot", 17, false },
    };
    for (want, s.tests) |w, t| {
        try testing.expectEqualStrings(w[0], t.name);
        try testing.expectEqual(w[1], t.line);
        try testing.expectEqual(w[2], t.parameterized);
    }
    try testing.expectEqual(@as(usize, 3), s.tests[0].start);
    try testing.expectEqual(@as(usize, 8), s.tests[0].end);
}

test "a .pf file: @suite names the suite; without a module, the file does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("vec_tests", (try pfSuite(a, "@suite(name='vec_tests')\nmodule m\nend module m\n", "x")).name);
    try testing.expectEqualStrings("loose_suite", (try pfSuite(a, "@test\nsubroutine t()\nend subroutine t\n", "loose")).name);
}

test "a .pf file: the tests of a @testCase with parameters are parameterized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try pfSuite(arena.allocator(), "module m\n@testParameter\ntype, extends(AbstractTestParameter) :: P\nend type\n@testCase(testParameters={getParameters()})\n" ++
        "type, extends(ParameterizedTestCase) :: C\nend type\ncontains\n@test\nsubroutine t(this)\nend subroutine t\nend module m\n", "m");
    try testing.expectEqual(@as(usize, 1), s.tests.len);
    try testing.expectEqualStrings("t", s.tests[0].name);
    try testing.expect(s.tests[0].parameterized);
}

test "add_pfunit_ctest: the test's name and its .pf files, with set() variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cmake =
        \\
        \\set(pf_files test_a.pf ${CMAKE_CURRENT_SOURCE_DIR}/sub/test_b.pf)
        \\add_pfunit_ctest (vector_tests
        \\  TEST_SOURCES ${pf_files} "test c.pf"
        \\  LINK_LIBRARIES vectors  # not a test
        \\  OTHER_SOURCES helper.F90
        \\  )
        \\# add_pfunit_ctest(commented TEST_SOURCES x.pf)
        \\add_pfunit_ctest(other TEST_SOURCES other.pf MAX_PES 4)
        \\
    ;
    const programs = try parseAddPfunitCtest(arena.allocator(), cmake);
    try testing.expectEqual(@as(usize, 2), programs.len);
    try testing.expectEqualStrings("vector_tests", programs[0].name);
    try testing.expectEqual(std.mem.find(u8, cmake, "vector_tests").?, programs[0].offset);
    try testing.expectEqual(@as(usize, 3), programs[0].sources.len);
    try testing.expectEqualStrings("test_a.pf", programs[0].sources[0]);
    try testing.expectEqualStrings("sub/test_b.pf", programs[0].sources[1]);
    try testing.expectEqualStrings("test c.pf", programs[0].sources[2]);
    try testing.expectEqualStrings("other", programs[1].name);
    try testing.expectEqual(@as(usize, 1), programs[1].sources.len);
    try testing.expectEqualStrings("other.pf", programs[1].sources[0]);
}
