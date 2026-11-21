//! The kinds a compiler's options give the types written without one
//! (REAL, INTEGER, LOGICAL, COMPLEX, DOUBLE PRECISION, and literals such as
//! `1.0`, `2`, `1d0`), and the explicit kinds they promote (#512):
//! gfortran's and LLVM Flang's `-fdefault-real-8` (DOUBLE PRECISION 16
//! then, unless `-fdefault-double-8`), `-fdefault-integer-8` (LOGICAL too),
//! gfortran's `-freal-4-real-8` ... `-finteger-4-integer-8`; Intel's
//! `/real-size:64`, `/integer-size:64`, `/double-size:128`, `/4R8`, `/4I8`,
//! `/autodouble` (and their `-` spellings), `-r8`, `-i8`.

const std = @import("std");

pub const Kinds = struct {
    real: u8 = 4,
    integer: u8 = 4,
    double: u8 = 8,
    /// what explicit REAL(4), REAL(8) and INTEGER(4) are (`-freal-4-real-8`)
    real4: u8 = 4,
    real8: u8 = 8,
    integer4: u8 = 4,

    /// Explicit kind `n` of a REAL or COMPLEX (`real`) or an INTEGER or
    /// LOGICAL, as the options promote it
    pub fn promoted(k: Kinds, real: bool, n: i64) i64 {
        if (real) return switch (n) {
            4 => k.real4,
            8 => k.real8,
            else => n,
        };
        return if (n == 4) k.integer4 else n;
    }

    /// The type and kind that `k` gives type `desc` written without a kind
    /// (`REAL`, `DOUBLE PRECISION`), when not its kind without options
    pub fn implied(k: Kinds, desc: []const u8) ?struct { name: []const u8, kind: u8 } {
        const Implied = struct { name: []const u8, written: []const u8, kind: u8, default: u8 };
        const all = [_]Implied{
            .{ .name = "REAL", .written = "REAL", .kind = k.real, .default = 4 },
            .{ .name = "COMPLEX", .written = "COMPLEX", .kind = k.real, .default = 4 },
            .{ .name = "INTEGER", .written = "INTEGER", .kind = k.integer, .default = 4 },
            .{ .name = "LOGICAL", .written = "LOGICAL", .kind = k.integer, .default = 4 },
            .{ .name = "REAL", .written = "DOUBLEPRECISION", .kind = k.double, .default = 8 },
            .{ .name = "COMPLEX", .written = "DOUBLECOMPLEX", .kind = k.double, .default = 8 },
        };
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        for (desc) |c| if (c != ' ') {
            if (n == buf.len) return null;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        };
        for (all) |t| if (std.mem.eql(u8, buf[0..n], t.written)) {
            return if (t.kind == t.default) null else .{ .name = t.name, .kind = t.kind };
        };
        return null;
    }
};

/// The kinds of the options `args`; the last of each kind wins
pub fn parse(args: []const []const u8) Kinds {
    var k: Kinds = .{};
    var double8 = false;
    var real8 = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        // Intel's on Linux: the size in the next argument
        const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (eql(x, "-fdefault-real-8") or eql(x, "-r8") or eql(x, "/4R8") or eql(x, "-4R8") or eql(x, "/autodouble") or eql(x, "-autodouble")) {
            k.real = 8;
            real8 = eql(x, "-fdefault-real-8");
        } else if (eql(x, "-fdefault-real-10")) {
            k.real = 10;
        } else if (eql(x, "-fdefault-real-16") or eql(x, "/4R16") or eql(x, "-4R16")) {
            k.real = 16;
        } else if (eql(x, "-fdefault-double-8")) {
            double8 = true;
        } else if (eql(x, "-fdefault-integer-8") or eql(x, "-i8") or eql(x, "/4I8") or eql(x, "-4I8")) {
            k.integer = 8;
        } else if (eql(x, "/4I2") or eql(x, "-4I2")) {
            k.integer = 2;
        } else if (sizeOf(x, "real-size", next)) |s| {
            if (s.bits == 32 or s.bits == 64 or s.bits == 128) k.real = @intCast(s.bits / 8);
            i += s.skip;
        } else if (sizeOf(x, "integer-size", next)) |s| {
            if (s.bits == 16 or s.bits == 32 or s.bits == 64) k.integer = @intCast(s.bits / 8);
            i += s.skip;
        } else if (sizeOf(x, "double-size", next)) |s| {
            if (s.bits == 64 or s.bits == 128) k.double = @intCast(s.bits / 8);
            i += s.skip;
        } else if (promotion(x, "-freal-4-real-")) |n| {
            k.real4 = n;
        } else if (promotion(x, "-freal-8-real-")) |n| {
            k.real8 = n;
        } else if (eql(x, "-finteger-4-integer-8")) {
            k.integer4 = 8;
        }
    }
    // gfortran's -fdefault-real-8 makes DOUBLE PRECISION 16
    if (real8 and !double8 and k.double == 8) k.double = 16;
    return k;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// Intel's `/NAME:N`, `-NAME:N` or `-NAME N` (`N` in `next`)
fn sizeOf(x: []const u8, comptime name: []const u8, next: ?[]const u8) ?struct { bits: u16, skip: usize } {
    if (x.len < name.len + 1 or (x[0] != '/' and x[0] != '-') or !std.mem.startsWith(u8, x[1..], name)) return null;
    const rest = x[1 + name.len ..];
    if (rest.len == 0) {
        const n = next orelse return null;
        return .{ .bits = std.fmt.parseInt(u16, n, 10) catch return null, .skip = 1 };
    }
    if (rest[0] != ':' and rest[0] != '=') return null;
    return .{ .bits = std.fmt.parseInt(u16, rest[1..], 10) catch return null, .skip = 0 };
}

/// `N` of `-freal-K-real-N`
fn promotion(x: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, x, prefix)) return null;
    const n = std.fmt.parseInt(u8, x[prefix.len..], 10) catch return null;
    return switch (n) {
        4, 8, 10, 16 => n,
        else => null,
    };
}

const testing = std.testing;

test "gfortran's default kinds" {
    const k = parse(&.{ "-c", "-fdefault-real-8", "-fdefault-integer-8", "x.f90" });
    try testing.expectEqual(@as(u8, 8), k.real);
    try testing.expectEqual(@as(u8, 8), k.integer);
    try testing.expectEqual(@as(u8, 16), k.double);
    try testing.expectEqual(@as(u8, 8), parse(&.{ "-fdefault-real-8", "-fdefault-double-8" }).double);
    const p = parse(&.{ "-freal-4-real-8", "-freal-8-real-16", "-finteger-4-integer-8" });
    try testing.expectEqual(@as(i64, 8), p.promoted(true, 4));
    try testing.expectEqual(@as(i64, 16), p.promoted(true, 8));
    try testing.expectEqual(@as(i64, 8), p.promoted(false, 4));
    try testing.expectEqual(@as(i64, 2), p.promoted(false, 2));
    try testing.expectEqual(Kinds{}, parse(&.{ "-Wall", "-O2" }));
}

test "the kinds the options give a type written without one" {
    // gfortran 16.1 -fdefault-real-8 -fdefault-integer-8 (its parse tree)
    const g = parse(&.{ "-fdefault-real-8", "-fdefault-integer-8" });
    try testing.expectEqual(@as(u8, 8), g.implied("REAL").?.kind);
    try testing.expectEqual(@as(u8, 8), g.implied("LOGICAL").?.kind);
    const d = g.implied("DOUBLE PRECISION").?;
    try testing.expectEqualStrings("REAL", d.name);
    try testing.expectEqual(@as(u8, 16), d.kind);
    try testing.expectEqualStrings("COMPLEX", g.implied("DOUBLE COMPLEX").?.name);
    try testing.expect(g.implied("CHARACTER") == null);
    // ifx 2026.2.0 /real-size:64 (its listing): DOUBLE PRECISION stays R(8)
    const i = parse(&.{"/real-size:64"});
    try testing.expectEqual(@as(u8, 8), i.implied("COMPLEX").?.kind);
    try testing.expect(i.implied("DOUBLE PRECISION") == null);
    try testing.expect(i.implied("INTEGER") == null);
    try testing.expect((Kinds{}).implied("REAL") == null);
}

test "Intel's default kinds" {
    const w = parse(&.{ "/real-size:64", "/integer-size:64", "/double-size:128" });
    try testing.expectEqual(@as(u8, 8), w.real);
    try testing.expectEqual(@as(u8, 8), w.integer);
    try testing.expectEqual(@as(u8, 16), w.double);
    const l = parse(&.{ "-real-size", "64", "-integer-size", "64", "x.f90" });
    try testing.expectEqual(@as(u8, 8), l.real);
    try testing.expectEqual(@as(u8, 8), l.integer);
    // Intel's DOUBLE PRECISION stays 8 with REAL 8
    try testing.expectEqual(@as(u8, 8), parse(&.{"/4R8"}).double);
    try testing.expectEqual(@as(u8, 8), parse(&.{"/autodouble"}).real);
    try testing.expectEqual(@as(u8, 8), parse(&.{"/4I8"}).integer);
    try testing.expectEqual(@as(u8, 8), parse(&.{"-r8"}).real);
}
