//! The counts of the intrinsic functions that zfls reads from the M_intrinsics
//! synopses (build/intrinsic_arity.zig) against what gfortran 16.1 accepts
//! (#877): each `NAME(args)` was compiled with 0 to 8 real arguments and the
//! least and most that gave no argument-count error recorded here (null: no
//! limit). LLVM Flang 23.1.5 has the same limits where its messages tell
//! them apart. A change of the pages that changes a count fails the test:
//! check the compilers again, record, or leave the name out
//! (`skip_counts`).

const std = @import("std");
const intrinsic_docs = @import("intrinsic_docs");

const Recorded = struct { []const u8, usize, ?usize };

const gfortran = [_]Recorded{
    .{ "abs", 1, 1 },
    .{ "achar", 1, 2 },
    .{ "acos", 1, 1 },
    .{ "acosd", 1, 1 },
    .{ "acosh", 1, 1 },
    .{ "acospi", 1, 1 },
    .{ "adjustl", 1, 1 },
    .{ "adjustr", 1, 1 },
    .{ "aimag", 1, 1 },
    .{ "aint", 1, 2 },
    .{ "all", 1, 2 },
    .{ "anint", 1, 2 },
    .{ "any", 1, 2 },
    .{ "asin", 1, 1 },
    .{ "asind", 1, 1 },
    .{ "asinh", 1, 1 },
    .{ "asinpi", 1, 1 },
    .{ "associated", 1, 2 },
    .{ "atan", 1, 2 },
    .{ "atan2", 2, 2 },
    .{ "atan2d", 2, 2 },
    .{ "atan2pi", 2, 2 },
    .{ "atand", 1, 2 },
    .{ "atanh", 1, 1 },
    .{ "bessel_j0", 1, 1 },
    .{ "bessel_j1", 1, 1 },
    .{ "bessel_y0", 1, 1 },
    .{ "bessel_y1", 1, 1 },
    .{ "bge", 2, 2 },
    .{ "bgt", 2, 2 },
    .{ "bit_size", 1, 1 },
    .{ "ble", 2, 2 },
    .{ "blt", 2, 2 },
    .{ "btest", 2, 2 },
    .{ "ceiling", 1, 2 },
    .{ "char", 1, 2 },
    .{ "cmplx", 1, 3 },
    .{ "command_argument_count", 0, 0 },
    .{ "conjg", 1, 1 },
    .{ "cos", 1, 1 },
    .{ "cosd", 1, 1 },
    .{ "cosh", 1, 1 },
    .{ "cospi", 1, 1 },
    .{ "count", 1, 3 },
    .{ "cshift", 2, 3 },
    .{ "dble", 1, 1 },
    .{ "digits", 1, 1 },
    .{ "dim", 2, 2 },
    .{ "dot_product", 2, 2 },
    .{ "dprod", 2, 2 },
    .{ "dshiftl", 3, 3 },
    .{ "dshiftr", 3, 3 },
    .{ "eoshift", 2, 4 },
    .{ "epsilon", 1, 1 },
    .{ "erf", 1, 1 },
    .{ "erfc", 1, 1 },
    .{ "erfc_scaled", 1, 1 },
    .{ "exp", 1, 1 },
    .{ "exponent", 1, 1 },
    .{ "extends_type_of", 2, 2 },
    .{ "findloc", 2, 6 },
    .{ "floor", 1, 2 },
    .{ "fraction", 1, 1 },
    .{ "gamma", 1, 1 },
    .{ "huge", 1, 1 },
    .{ "hypot", 2, 2 },
    .{ "iachar", 1, 2 },
    .{ "iall", 1, 3 },
    .{ "iand", 2, 2 },
    .{ "iany", 1, 3 },
    .{ "ibclr", 2, 2 },
    .{ "ibits", 3, 3 },
    .{ "ibset", 2, 2 },
    .{ "ichar", 1, 2 },
    .{ "ieor", 2, 2 },
    .{ "index", 2, 4 },
    .{ "int", 1, 2 },
    .{ "ior", 2, 2 },
    .{ "is_contiguous", 1, 1 },
    .{ "is_iostat_end", 1, 1 },
    .{ "is_iostat_eor", 1, 1 },
    .{ "ishftc", 2, 3 },
    .{ "kind", 1, 1 },
    .{ "lbound", 1, 3 },
    .{ "lcobound", 1, 3 },
    .{ "leadz", 1, 1 },
    .{ "len", 1, 2 },
    .{ "len_trim", 1, 2 },
    .{ "lge", 2, 2 },
    .{ "lgt", 2, 2 },
    .{ "lle", 2, 2 },
    .{ "llt", 2, 2 },
    .{ "log", 1, 1 },
    .{ "log10", 1, 1 },
    .{ "log_gamma", 1, 1 },
    .{ "logical", 1, 2 },
    .{ "maskl", 1, 2 },
    .{ "maskr", 1, 2 },
    .{ "matmul", 2, 2 },
    .{ "maxexponent", 1, 1 },
    .{ "maxval", 1, 3 },
    .{ "merge", 3, 3 },
    .{ "merge_bits", 3, 3 },
    .{ "minexponent", 1, 1 },
    .{ "minval", 1, 3 },
    .{ "mod", 2, 2 },
    .{ "modulo", 2, 2 },
    .{ "nearest", 2, 2 },
    .{ "new_line", 1, 1 },
    .{ "nint", 1, 2 },
    .{ "norm2", 1, 2 },
    .{ "not", 1, 1 },
    .{ "out_of_range", 2, 3 },
    .{ "pack", 2, 3 },
    .{ "parity", 1, 2 },
    .{ "popcnt", 1, 1 },
    .{ "poppar", 1, 1 },
    .{ "precision", 1, 1 },
    .{ "present", 1, 1 },
    .{ "product", 1, 3 },
    .{ "radix", 1, 1 },
    .{ "range", 1, 1 },
    .{ "rank", 1, 1 },
    .{ "real", 1, 2 },
    .{ "reduce", 2, 6 },
    .{ "repeat", 2, 2 },
    .{ "reshape", 2, 4 },
    .{ "rrspacing", 1, 1 },
    .{ "same_type_as", 2, 2 },
    .{ "scale", 2, 2 },
    .{ "scan", 2, 4 },
    .{ "selected_char_kind", 1, 1 },
    .{ "selected_int_kind", 1, 1 },
    .{ "selected_real_kind", 0, 3 },
    .{ "set_exponent", 2, 2 },
    .{ "shape", 1, 2 },
    .{ "shifta", 2, 2 },
    .{ "shiftl", 2, 2 },
    .{ "shiftr", 2, 2 },
    .{ "sign", 2, 2 },
    .{ "sin", 1, 1 },
    .{ "sind", 1, 1 },
    .{ "sinh", 1, 1 },
    .{ "sinpi", 1, 1 },
    .{ "size", 1, 3 },
    .{ "spacing", 1, 1 },
    .{ "spread", 3, 3 },
    .{ "sqrt", 1, 1 },
    .{ "storage_size", 1, 2 },
    .{ "tan", 1, 1 },
    .{ "tand", 1, 1 },
    .{ "tanh", 1, 1 },
    .{ "tanpi", 1, 1 },
    .{ "tiny", 1, 1 },
    .{ "trailz", 1, 1 },
    .{ "transfer", 2, 3 },
    .{ "transpose", 1, 1 },
    .{ "trim", 1, 1 },
    .{ "ubound", 1, 3 },
    .{ "ucobound", 1, 3 },
    .{ "unpack", 3, 3 },
    .{ "verify", 2, 4 },
};

test "the counts of the pages are those the compilers accept" {
    for (intrinsic_docs.arities) |ar| {
        const rec = for (gfortran) |r| {
            if (std.mem.eql(u8, r[0], ar.name)) break r;
        } else {
            std.debug.print("not recorded: {s}\n", .{ar.name});
            return error.NotRecorded;
        };
        if (rec[1] != ar.min or rec[2] != ar.max) {
            std.debug.print("{s}: the page says {d} to {?d}, gfortran {d} to {?d}\n", .{ ar.name, ar.min, ar.max, rec[1], rec[2] });
            return error.CountDiffers;
        }
    }
    for (gfortran) |r| {
        const found = for (intrinsic_docs.arities) |ar| {
            if (std.mem.eql(u8, r[0], ar.name)) break true;
        } else false;
        if (!found) {
            std.debug.print("recorded but not read: {s}\n", .{r[0]});
            return error.NotRead;
        }
    }
}
