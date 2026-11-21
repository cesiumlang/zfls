//! How a file's compiler options say it is read (#542): its source form,
//! fixed-form line length, debug lines and `-fimplicit-none`, from the
//! options of gfortran, LLVM Flang, Intel's compilers, nvfortran and nagfor.

const std = @import("std");

/// The fixed-form line length an option sets
pub const Columns = union(enum) { limit: usize, none };

pub const ReadOptions = struct {
    /// `-ffixed-form` (true) or `-ffree-form` (false)
    fixed: ?bool = null,
    columns: ?Columns = null,
    /// Debug lines as code (true) or comments (false)
    d_lines_code: ?bool = null,
    implicit_none: bool = false,
};

/// The read options of `args`; the last of each kind wins
pub fn parse(args: []const []const u8) ReadOptions {
    var o: ReadOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (oneOf(x, &.{ "-ffixed-form", "-fixed", "/fixed", "-Mfixed", "--fixed-form" })) {
            o.fixed = true;
        } else if (oneOf(x, &.{ "-ffree-form", "-free", "/free", "-Mfree" })) {
            o.fixed = false;
        } else if (oneOf(x, &.{ "-fd-lines-as-code", "-d-lines", "/d-lines", "-Mdlines", "-d_lines" })) {
            o.d_lines_code = true;
        } else if (oneOf(x, &.{ "-fd-lines-as-comments", "-nod-lines", "/nod-lines", "-Mnodlines" })) {
            o.d_lines_code = false;
        } else if (std.mem.eql(u8, x, "-fimplicit-none")) {
            o.implicit_none = true;
        } else if (std.mem.eql(u8, x, "-fno-implicit-none")) {
            o.implicit_none = false;
        } else if (columnsOf(x)) |c| {
            o.columns = c;
        } else if (std.mem.eql(u8, x, "-extend-source")) {
            // Intel on Linux: the length in the next argument, else 132
            const n = if (i + 1 < args.len) std.fmt.parseInt(usize, args[i + 1], 10) catch null else null;
            if (n != null) i += 1;
            o.columns = .{ .limit = n orelse 132 };
        }
    }
    return o;
}

fn oneOf(x: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

/// The line length of one argument: gfortran's `-ffixed-line-length-N`
/// (`none`, `0`: no limit), Flang's `-ffixed-line-length=N`, Intel's
/// `/extend-source[:N]` and `/4LN`, nvfortran's `-Mextend`, nagfor's `-132`
fn columnsOf(x: []const u8) ?Columns {
    for ([_][]const u8{ "-ffixed-line-length-", "-ffixed-line-length=" }) |p| if (std.mem.startsWith(u8, x, p)) {
        const v = x[p.len..];
        if (std.mem.eql(u8, v, "none")) return .none;
        const n = std.fmt.parseInt(usize, v, 10) catch return null;
        return if (n == 0) .none else .{ .limit = n };
    };
    if (std.mem.eql(u8, x, "/extend-source") or std.mem.eql(u8, x, "-Mextend") or std.mem.eql(u8, x, "-132")) return .{ .limit = 132 };
    for ([_][]const u8{ "/extend-source:", "/4L" }) |p| if (std.mem.startsWith(u8, x, p)) {
        return .{ .limit = std.fmt.parseInt(usize, x[p.len..], 10) catch return null };
    };
    return null;
}

test "read options: gfortran's" {
    const o = parse(&.{ "-c", "-ffixed-form", "-ffixed-line-length-72", "-fd-lines-as-code", "-fimplicit-none", "x.f90" });
    try std.testing.expectEqual(@as(?bool, true), o.fixed);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 72 }), o.columns);
    try std.testing.expectEqual(@as(?bool, true), o.d_lines_code);
    try std.testing.expect(o.implicit_none);
    try std.testing.expectEqual(@as(?Columns, .none), parse(&.{"-ffixed-line-length-none"}).columns);
    try std.testing.expectEqual(@as(?Columns, .none), parse(&.{"-ffixed-line-length-0"}).columns);
    // the last wins
    const last = parse(&.{ "-ffree-form", "-fd-lines-as-code", "-fd-lines-as-comments", "-ffixed-form" });
    try std.testing.expectEqual(@as(?bool, true), last.fixed);
    try std.testing.expectEqual(@as(?bool, false), last.d_lines_code);
    try std.testing.expectEqual(ReadOptions{}, parse(&.{ "-Wall", "-O2", "-c" }));
}

test "read options: Flang's, Intel's, nvfortran's and nagfor's" {
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 80 }), parse(&.{"-ffixed-line-length=80"}).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 132 }), parse(&.{"/extend-source"}).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 80 }), parse(&.{"/extend-source:80"}).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 132 }), parse(&.{"/4L132"}).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 72 }), parse(&.{ "-extend-source", "72", "x.f" }).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 132 }), parse(&.{ "-extend-source", "x.f" }).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 132 }), parse(&.{"-Mextend"}).columns);
    try std.testing.expectEqual(@as(?Columns, .{ .limit = 132 }), parse(&.{"-132"}).columns);
    const intel = parse(&.{ "/fixed", "/d-lines" });
    try std.testing.expectEqual(@as(?bool, true), intel.fixed);
    try std.testing.expectEqual(@as(?bool, true), intel.d_lines_code);
    try std.testing.expectEqual(@as(?bool, false), parse(&.{"-free"}).fixed);
}
