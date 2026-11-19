//! Preprocessor macros (#265): go to definition goes to the `#define` in
//! effect at a use, also in a header; references and highlights list a
//! macro's places, directives included; hover and definition work on the
//! names of `#ifdef`, `#ifndef`, `#if defined(...)` and `#undef` lines.

const std = @import("std");
const h = @import("harness.zig");

const files = [_]h.File{
    .{ .name = "a.F90", .text =
    \\#define LOCALM real*8
    \\subroutine s()
    \\   implicit none
    \\#include "decl.h"
    \\   HDRM :: x
    \\   LOCALM :: y
    \\#ifdef LOCALM
    \\   x = 1
    \\#endif
    \\   y = 2
    \\end subroutine
    \\
    },
    .{ .name = "decl.h", .text =
    \\#define HDRM real*8
    \\
    },
    .{ .name = "b.F90", .text =
    \\subroutine t()
    \\   implicit none
    \\#include "decl.h"
    \\   HDRM :: z
    \\   z = 3
    \\end subroutine
    \\
    },
};

fn endsWith(uri: []const u8, name: []const u8) bool {
    return std.mem.endsWith(u8, uri, name);
}

fn expectFive(w: *h.Workspace) !void {
    const use = w.pos("a.F90", "LOCALM :: y", 0, 0);
    try w.expectHoverContains("a.F90", use, "#define LOCALM real*8");
    const local = (try w.definition("a.F90", use)) orelse return h.unmet("no definition of LOCALM", .{});
    try h.expect(endsWith(local.uri, "a.F90") and local.line == 0 and local.col == 8, "LOCALM defined at {s} {d}:{d}", .{ local.uri, local.line, local.col });
    const hdr = (try w.definition("a.F90", w.pos("a.F90", "HDRM", 0, 0))) orelse return h.unmet("no definition of HDRM", .{});
    try h.expect(endsWith(hdr.uri, "decl.h") and hdr.line == 0, "HDRM defined at {s} {d}", .{ hdr.uri, hdr.line });
    var lines: [8]i64 = undefined;
    var n: usize = 0;
    for (try w.references("a.F90", use)) |r| {
        if (n < lines.len) lines[n] = r.line;
        n += 1;
    }
    try h.expect(n == 3 and lines[0] == 0 and lines[1] == 5 and lines[2] == 6, "references of LOCALM in lines {any}", .{lines[0..@min(n, lines.len)]});
    const in_ifdef = w.pos("a.F90", "LOCALM", 2, 0);
    const d = (try w.definition("a.F90", in_ifdef)) orelse return h.unmet("no definition of LOCALM in #ifdef", .{});
    try h.expect(d.line == 0, "LOCALM in #ifdef defined in line {d}", .{d.line});
    try w.expectHoverContains("a.F90", in_ifdef, "#define LOCALM real*8");
}

test "hansec #115 macros: definition, references and hover on directives (#265)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 115, .fixed, expectFive(w));
}

test "a header's macro: references in the header and in the files that include it (#265)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    var a_lines: usize = 0;
    var b_lines: usize = 0;
    var h_lines: usize = 0;
    for (try w.references("a.F90", w.pos("a.F90", "HDRM", 0, 0))) |r| {
        if (endsWith(r.uri, "a.F90")) a_lines += 1;
        if (endsWith(r.uri, "b.F90")) b_lines += 1;
        if (endsWith(r.uri, "decl.h")) h_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), a_lines);
    try std.testing.expectEqual(@as(usize, 1), b_lines);
    try std.testing.expectEqual(@as(usize, 1), h_lines);
    // highlights: only the file's
    const hl = try w.zflsRequest("textDocument/documentHighlight", .{
        .textDocument = .{ .uri = try w.uri("a.F90") },
        .position = .{ .line = 4, .character = 4 },
    });
    try std.testing.expectEqual(@as(usize, 1), h.json.items(hl).len);
}

test "a macro of pp_defs has no definition, and hover as before (#265)" {
    const src = [_]h.File{.{ .name = "p.F90", .text =
        \\subroutine s()
        \\   implicit none
        \\   real :: v
        \\   v = PI_VAL
        \\end subroutine
        \\
    }};
    const w = try h.Workspace.init(&src, .{ .pp_defs = &.{.{ .name = "PI_VAL", .value = "3.14" }} });
    defer w.deinit();
    const p = w.pos("p.F90", "PI_VAL", 0, 0);
    try std.testing.expect((try w.definition("p.F90", p)) == null);
    try w.expectHoverContains("p.F90", p, "#define PI_VAL 3.14");
}

test "after #undef and a new #define, definition goes to the #define in effect (#265)" {
    const src = [_]h.File{.{ .name = "r.F90", .text =
        \\#define KND 4
        \\subroutine s()
        \\   implicit none
        \\   real(KND) :: a
        \\#undef KND
        \\#define KND 8
        \\   real(KND) :: b
        \\#undef KND
        \\end subroutine
        \\
    }};
    const w = try h.Workspace.init(&src, .{});
    defer w.deinit();
    const first = (try w.definition("r.F90", w.pos("r.F90", "KND", 1, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 0), first.line);
    const second = (try w.definition("r.F90", w.pos("r.F90", "KND", 4, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 5), second.line);
    // on the #undef that ends it, hover tells the #define it removes
    try w.expectHoverContains("r.F90", w.pos("r.F90", "KND", 5, 0), "#define KND 8");
}

test "a function-like macro used as SQ(a) (#265)" {
    const src = [_]h.File{.{ .name = "q.F90", .text =
        \\#define SQ(x) ((x)*(x))
        \\subroutine s()
        \\   implicit none
        \\   real :: a, b
        \\   a = 2
        \\   b = SQ(a)
        \\#if defined(SQ)
        \\   b = SQ(b) + 'SQ'
        \\#endif
        \\end subroutine
        \\
    }};
    const w = try h.Workspace.init(&src, .{});
    defer w.deinit();
    const d = (try w.definition("q.F90", w.pos("q.F90", "SQ(a)", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 0), d.line);
    // the one in a string is no use
    const refs = try w.references("q.F90", w.pos("q.F90", "SQ(a)", 0, 0));
    try std.testing.expectEqual(@as(usize, 4), refs.len);
    const in_if = (try w.definition("q.F90", w.pos("q.F90", "SQ)", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 0), in_if.line);
}

test "a variable named like a macro in a file that is not preprocessed is a variable (#265)" {
    const src = [_]h.File{
        .{ .name = "v.f90", .text =
        \\subroutine s()
        \\   implicit none
        \\#include "decl.h"
        \\   integer :: HDRM
        \\   HDRM = 1
        \\end subroutine
        \\
        },
        .{ .name = "decl.h", .text =
        \\#define HDRM real*8
        \\
        },
    };
    const w = try h.Workspace.init(&src, .{});
    defer w.deinit();
    const d = (try w.definition("v.f90", w.pos("v.f90", "HDRM = 1", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expect(endsWith(d.uri, "v.f90"));
    try std.testing.expectEqual(@as(i64, 3), d.line);
}
