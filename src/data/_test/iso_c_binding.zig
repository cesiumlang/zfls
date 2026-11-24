//! The names of iso_c_binding that the three compilers export, and the table of
//! `data/modules.zig` (#881): each name of a compiler is in the table, and
//! the table has no name that none of them has. Recorded 2026-11-24 from
//! gfortran 16.1 and ifx 2026.2.0 (a `use iso_c_binding, only: NAME` of each
//! candidate name; ifx's own `iso_c_binding.f90` agrees) and from Flang
//! 23.1.5's `iso_c_binding.mod`. Not regenerated: re-record to follow a
//! compiler's new release.

const std = @import("std");
const modules = @import("../modules.zig");

/// gfortran 16.1
const gfortran = [_][]const u8{
    "c_alert",
    "c_associated",
    "c_backspace",
    "c_bool",
    "c_carriage_return",
    "c_char",
    "c_double",
    "c_double_complex",
    "c_f_pointer",
    "c_f_procpointer",
    "c_float",
    "c_float128",
    "c_float128_complex",
    "c_float_complex",
    "c_form_feed",
    "c_funloc",
    "c_funptr",
    "c_horizontal_tab",
    "c_int",
    "c_int128_t",
    "c_int16_t",
    "c_int32_t",
    "c_int64_t",
    "c_int8_t",
    "c_int_fast128_t",
    "c_int_fast16_t",
    "c_int_fast32_t",
    "c_int_fast64_t",
    "c_int_fast8_t",
    "c_int_least128_t",
    "c_int_least16_t",
    "c_int_least32_t",
    "c_int_least64_t",
    "c_int_least8_t",
    "c_intmax_t",
    "c_intptr_t",
    "c_loc",
    "c_long",
    "c_long_double",
    "c_long_double_complex",
    "c_long_long",
    "c_new_line",
    "c_null_char",
    "c_null_funptr",
    "c_null_ptr",
    "c_ptr",
    "c_ptrdiff_t",
    "c_short",
    "c_signed_char",
    "c_size_t",
    "c_sizeof",
    "c_vertical_tab",
    "f_c_string",
};

/// ifx 2026.2.0
const ifx = [_][]const u8{
    "c_alert",
    "c_associated",
    "c_backspace",
    "c_bool",
    "c_carriage_return",
    "c_char",
    "c_double",
    "c_double_complex",
    "c_f_pointer",
    "c_f_procpointer",
    "c_f_strpointer",
    "c_float",
    "c_float_complex",
    "c_form_feed",
    "c_funloc",
    "c_funptr",
    "c_horizontal_tab",
    "c_int",
    "c_int16_t",
    "c_int32_t",
    "c_int64_t",
    "c_int8_t",
    "c_int_fast16_t",
    "c_int_fast32_t",
    "c_int_fast64_t",
    "c_int_fast8_t",
    "c_int_least16_t",
    "c_int_least32_t",
    "c_int_least64_t",
    "c_int_least8_t",
    "c_intmax_t",
    "c_intptr_t",
    "c_loc",
    "c_long",
    "c_long_double",
    "c_long_double_complex",
    "c_long_long",
    "c_new_line",
    "c_null_char",
    "c_null_funptr",
    "c_null_ptr",
    "c_ptr",
    "c_ptrdiff_t",
    "c_short",
    "c_signed_char",
    "c_size_t",
    "c_sizeof",
    "c_vertical_tab",
    "f_c_string",
};

/// LLVM Flang 23.1.5
const flang = [_][]const u8{
    "c_alert",
    "c_associated",
    "c_backspace",
    "c_bool",
    "c_carriage_return",
    "c_char",
    "c_double",
    "c_double_complex",
    "c_f_pointer",
    "c_f_procpointer",
    "c_f_strpointer",
    "c_float",
    "c_float128",
    "c_float128_complex",
    "c_float16",
    "c_float16_complex",
    "c_float_complex",
    "c_form_feed",
    "c_funloc",
    "c_funptr",
    "c_horizontal_tab",
    "c_int",
    "c_int128_t",
    "c_int16_t",
    "c_int32_t",
    "c_int64_t",
    "c_int8_t",
    "c_int_fast128_t",
    "c_int_fast16_t",
    "c_int_fast32_t",
    "c_int_fast64_t",
    "c_int_fast8_t",
    "c_int_least128_t",
    "c_int_least16_t",
    "c_int_least32_t",
    "c_int_least64_t",
    "c_int_least8_t",
    "c_intmax_t",
    "c_intptr_t",
    "c_loc",
    "c_long",
    "c_long_double",
    "c_long_double_complex",
    "c_long_long",
    "c_new_line",
    "c_null_char",
    "c_null_funptr",
    "c_null_ptr",
    "c_ptr",
    "c_ptrdiff_t",
    "c_short",
    "c_signed_char",
    "c_size_t",
    "c_sizeof",
    "c_uint128_t",
    "c_uint16_t",
    "c_uint32_t",
    "c_uint64_t",
    "c_uint8_t",
    "c_uint_fast128_t",
    "c_uint_fast16_t",
    "c_uint_fast32_t",
    "c_uint_fast64_t",
    "c_uint_fast8_t",
    "c_uint_least128_t",
    "c_uint_least16_t",
    "c_uint_least32_t",
    "c_uint_least64_t",
    "c_uint_least8_t",
    "c_uintmax_t",
    "c_unsigned",
    "c_unsigned_char",
    "c_unsigned_long",
    "c_unsigned_long_long",
    "c_unsigned_short",
    "c_vertical_tab",
    "f_c_string",
};

fn tableHas(name: []const u8) bool {
    for (modules.all) |m| if (std.mem.eql(u8, m.name, "iso_c_binding")) {
        for (m.members) |member| if (std.mem.eql(u8, member.name, name)) return true;
    };
    return false;
}

test "the iso_c_binding table has every name of gfortran, ifx and Flang" {
    for ([_][]const []const u8{ &gfortran, &ifx, &flang }) |list| {
        for (list) |name| if (!tableHas(name)) {
            std.debug.print("missing from the table: {s}\n", .{name});
            return error.MissingName;
        };
    }
}

test "the iso_c_binding table has no name that no compiler has" {
    for (modules.all) |m| if (std.mem.eql(u8, m.name, "iso_c_binding")) {
        for (m.members) |member| {
            var found = false;
            for ([_][]const []const u8{ &gfortran, &ifx, &flang }) |list| {
                for (list) |name| found = found or std.mem.eql(u8, name, member.name);
            }
            if (!found) {
                std.debug.print("in no compiler: {s}\n", .{member.name});
                return error.ExtraName;
            }
        }
    };
}
