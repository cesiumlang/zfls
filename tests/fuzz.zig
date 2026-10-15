//! Robustness tests: whatever text a file holds, the server must neither
//! crash nor leak. Each input is loaded into a workspace and every kind of
//! request is sent at a few positions; the Zig test allocator reports leaks
//! and a Debug build traps overflows and out-of-bounds accesses.
//!
//! `zig build test` runs a fixed number of mutations of the seed programs
//! below. `zig build test --fuzz` lets the compiler's fuzzer drive the same
//! checks with arbitrary text.

const std = @import("std");
const h = @import("issues/harness.zig");

const seeds = [_][]const u8{
    \\module m
    \\  implicit none
    \\  integer, parameter :: sp = selected_real_kind(6)
    \\  type :: t
    \\    real(sp) :: x
    \\  contains
    \\    procedure :: show
    \\  end type t
    \\contains
    \\  subroutine show(self, n)
    \\    class(t), intent(in) :: self
    \\    integer, intent(in) :: n
    \\    print *, self%x, n
    \\  end subroutine show
    \\  function f(a) result(r)
    \\    real, intent(in) :: a(:)
    \\    real :: r
    \\    r = sum(a)
    \\  end function f
    \\end module m
    \\program p
    \\  use m, only: t, f
    \\  type(t) :: v
    \\  call v%show(1)
    \\  associate (y => v%x)
    \\    print *, y, f([1.0, 2.0])
    \\  end associate
    \\end program p
    \\
    ,
    \\#define N 4
    \\#ifdef N
    \\subroutine a(x)
    \\  integer :: x(N)
    \\#else
    \\subroutine a(x, y)
    \\#endif
    \\  include 'missing.inc'
    \\  block
    \\    x = 1
    \\  end block
    \\end subroutine a
    \\
    ,
    \\      subroutine old(a, b)
    \\      real a(10), b
    \\      do 10 i = 1, 10
    \\         a(i) = b &
    \\            + 1
    \\   10 continue
    \\      end
    \\      function g(x)
    \\      g = x
    \\      end
    \\
    ,
    \\module n
    \\  interface op
    \\    module procedure p1, p2
    \\  end interface
    \\  interface
    \\    subroutine ext(a)
    \\      integer :: a
    \\    end subroutine
    \\  end interface
    \\  abstract interface
    \\    subroutine cb(i)
    \\      integer :: i
    \\    end subroutine cb
    \\  end interface
    \\  enum, bind(c)
    \\    enumerator :: one = 1, two
    \\  end enum
    \\end module n
    \\submodule (n) s
    \\contains
    \\  module procedure p1
    \\  end procedure
    \\end submodule s
    \\
    ,
};

/// Fragments that make the mutated text look like Fortran
const vocabulary = [_][]const u8{
    "module ",         "end module ",       "program ",       "end program ",    "subroutine ",   "end subroutine ",
    "function ",       "end function ",     "type ",          "end type ",       "contains\n",    "interface\n",
    "end interface\n", "use ",              "only: ",         "implicit none\n", "integer ",      "real(8) ",
    "character(len=*) ", "class(",          "procedure ",     "::",              "=>",            "(",
    ")",               ",",                 "\n",             "&\n",             "!> doc\n",      "! comment\n",
    "#if ",            "#endif\n",          "#define X 1\n", "#include \"a\"\n", "associate (a => b)\n", "end associate\n",
    "block\n",         "end block\n",       "select type (",  "end select\n",    "do 10 i=1,2\n", "10 continue\n",
    "x",               "foo",               "%",              "'",               "\"",            "[1, 2]",
    "result(r)",       "intent(in) ",       "dimension(:) ",  "pointer ",        "abstract ",     "enum\n",
    "end enum\n",      "where (x > 0)\n",   "end where\n",    "\t",              "\r\n",          "\xc3\xa9",
};

fn mutate(rng: std.Random, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var cur: std.ArrayList(u8) = .empty;
    try cur.appendSlice(a, text);
    var edits = rng.intRangeAtMost(usize, 1, 8);
    while (edits > 0) : (edits -= 1) {
        const at = if (cur.items.len == 0) 0 else rng.uintLessThan(usize, cur.items.len + 1);
        switch (rng.uintLessThan(u8, 6)) {
            0 => { // insert vocabulary
                try cur.insertSlice(a, at, vocabulary[rng.uintLessThan(usize, vocabulary.len)]);
            },
            1 => { // delete a range
                const len = @min(rng.uintAtMost(usize, 40), cur.items.len - @min(at, cur.items.len));
                cur.replaceRangeAssumeCapacity(@min(at, cur.items.len), len, "");
            },
            2 => { // truncate
                cur.shrinkRetainingCapacity(at);
            },
            3 => { // random byte
                try cur.insert(a, at, rng.int(u8));
            },
            4 => { // duplicate a chunk
                const start = @min(at, cur.items.len);
                const len = @min(rng.uintAtMost(usize, 120), cur.items.len - start);
                const chunk = try a.dupe(u8, cur.items[start .. start + len]);
                try cur.insertSlice(a, at, chunk);
            },
            else => { // swap two lines
                var lines: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, cur.items, '\n');
                while (it.next()) |l| try lines.append(a, l);
                if (lines.items.len > 1) {
                    const i = rng.uintLessThan(usize, lines.items.len);
                    const j = rng.uintLessThan(usize, lines.items.len);
                    std.mem.swap([]const u8, &lines.items[i], &lines.items[j]);
                    const joined = try std.mem.join(a, "\n", lines.items);
                    cur.clearRetainingCapacity();
                    try cur.appendSlice(a, joined);
                }
            },
        }
    }
    return cur.items;
}

/// Errors the server may legitimately answer with: they are sent to the
/// client as JSON-RPC errors. Anything else (and OutOfMemory) is a bug.
fn tolerate(r: anytype) !void {
    _ = r catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {},
    };
}

fn exercise(rng: std.Random, text: []const u8, name: []const u8) !void {
    const w = try h.Workspace.init(&.{.{ .name = name, .text = "" }}, .{ .settings = .{ .incremental_sync = true } });
    defer w.deinit();
    try tolerate(w.replaceText(name, text));
    try tolerate(w.diagnostics(name));
    try tolerate(w.documentSymbols(name));
    try tolerate(w.workspaceSymbols("a"));
    var n_lines: usize = 1;
    for (text) |c| n_lines += @intFromBool(c == '\n');
    for (0..6) |_| {
        const p: h.Pos = .{
            .line = @intCast(rng.uintLessThan(usize, n_lines + 2)),
            .col = @intCast(rng.uintAtMost(usize, 30)),
        };
        try tolerate(w.hover(name, p));
        try tolerate(w.definition(name, p));
        try tolerate(w.implementation(name, p));
        try tolerate(w.references(name, p));
        try tolerate(w.completion(name, p));
        try tolerate(w.signature(name, p));
        try tolerate(w.rename(name, p, "renamed"));
    }
}

test "mutated programs do not crash or leak the server" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..200) |i| {
        _ = arena.reset(.retain_capacity);
        const seed = seeds[i % seeds.len];
        const text = try mutate(rng, arena.allocator(), seed);
        const name = if (i % 3 == 0) "f.f" else if (i % 3 == 1) "f.F90" else "f.f90";
        exercise(rng, text, name) catch |e| {
            std.debug.print("input {d} ({s}) failed with {s}:\n{s}\n", .{ i, name, @errorName(e), text });
            return e;
        };
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    var prng = std.Random.DefaultPrng.init(n);
    try exercise(prng.random(), buf[0..n], "f.f90");
}

test "fuzz: arbitrary text does not crash or leak the server" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &seeds });
}
