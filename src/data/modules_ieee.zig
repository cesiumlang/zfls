//! The IEEE intrinsic modules and their members (of modules.zig): Fortran
//! 2003's, with the names Fortran 2018 and 2023 add (#730).

const schema = @import("schema.zig");
const Module = schema.Module;

pub const modules = [_]Module{
    .{ .name = "ieee_exceptions", .members = &.{
        .{ .name = "ieee_flag_type", .kind = .type },
        .{ .name = "ieee_overflow", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_divide_by_zero", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_invalid", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_underflow", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_inexact", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_usual", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"DIMENSION(3)"} },
        .{ .name = "ieee_all", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"DIMENSION(5)"} },
        .{ .name = "ieee_modes_type", .kind = .type },
        .{ .name = "ieee_get_modes", .kind = .subroutine, .args = "MODES", .children = &.{
            .{ .name = "MODES", .kind = .variable, .desc = "TYPE(ieee_modes_type)", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "ieee_set_modes", .kind = .subroutine, .args = "MODES", .children = &.{
            .{ .name = "MODES", .kind = .variable, .desc = "TYPE(ieee_modes_type)", .mods = &.{"INTENT(in)"} },
        } },
    } },
    .{ .name = "ieee_arithmetic", .use = "ieee_exceptions", .members = &.{
        .{ .name = "ieee_status_type", .kind = .type },
        .{ .name = "ieee_class_type", .kind = .type },
        .{ .name = "ieee_round_type", .kind = .type },
        .{ .name = "ieee_signaling_nan", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_quiet_nan", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_negative_inf", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_negative_normal", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_negative_denormal", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_negative_zero", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_positive_zero", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_positive_denormal", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_positive_normal", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_positive_inf", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_negative_subnormal", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_positive_subnormal", .kind = .variable, .desc = "TYPE(ieee_class_type)" },
        .{ .name = "ieee_nearest", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_to_zero", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_away", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_up", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_down", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_other", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_class", .kind = .function, .args = "X", .return_type = "TYPE(ieee_class_type)", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_copy_sign", .kind = .subroutine, .args = "X,Y", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(inout)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_get_flag", .kind = .subroutine, .args = "FLAG,FLAG_VALUE", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "FLAG_VALUE", .kind = .variable, .desc = "LOGICAL", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "ieee_set_flag", .kind = .subroutine, .args = "FLAG,FLAG_VALUE", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "FLAG_VALUE", .kind = .variable, .desc = "LOGICAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_get_halting_mode", .kind = .subroutine, .args = "FLAG,HALTING", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "HALTING", .kind = .variable, .desc = "LOGICAL", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "ieee_set_halting_mode", .kind = .subroutine, .args = "FLAG,HALTING", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "HALTING", .kind = .variable, .desc = "LOGICAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_get_rounding_mode", .kind = .subroutine, .args = "ROUND_VALUE,RADIX", .children = &.{
            .{ .name = "ROUND_VALUE", .kind = .variable, .desc = "TYPE(ieee_round_type)", .mods = &.{"INTENT(out)"} },
            .{ .name = "RADIX", .kind = .variable, .desc = "INTEGER", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_set_rounding_mode", .kind = .subroutine, .args = "ROUND_VALUE,RADIX", .children = &.{
            .{ .name = "ROUND_VALUE", .kind = .variable, .desc = "TYPE(ieee_round_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "RADIX", .kind = .variable, .desc = "INTEGER", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_get_status", .kind = .subroutine, .args = "STATUS_VALUE", .children = &.{
            .{ .name = "STATUS_VALUE", .kind = .variable, .desc = "TYPE(ieee_status_type)", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "ieee_set_status", .kind = .subroutine, .args = "STATUS_VALUE", .children = &.{
            .{ .name = "STATUS_VALUE", .kind = .variable, .desc = "TYPE(ieee_status_type)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_is_finite", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_is_nan", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_is_negative", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_is_normal", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_logb", .kind = .function, .args = "X", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_next_after", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_rem", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_rint", .kind = .function, .args = "X", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_scalb", .kind = .function, .args = "X,I", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "I", .kind = .variable, .desc = "INTEGER", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_selected_real_kind", .kind = .function, .args = "P,R", .return_type = "INTEGER", .children = &.{
            .{ .name = "P", .kind = .variable, .desc = "INTEGER", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
            .{ .name = "R", .kind = .variable, .desc = "INTEGER", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_datatype", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_denormal", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_divide", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_flag", .kind = .function, .args = "FLAG,X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_halting", .kind = .function, .args = "FLAG", .return_type = "LOGICAL", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_support_inf", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_io", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_nan", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_rounding", .kind = .function, .args = "ROUND_VALUE,X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "FLAG", .kind = .variable, .desc = "TYPE(ieee_round_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_sqrt", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_standard", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_unordered", .kind = .function, .args = "X,Y", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_value", .kind = .function, .args = "X,CLASS", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "CLASS", .kind = .variable, .desc = "TYPE(ieee_class_type)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_fma", .kind = .function, .args = "A,B,C", .return_type = "REAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "C", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_int", .kind = .function, .args = "A,ROUND,KIND", .return_type = "INTEGER", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "ROUND", .kind = .variable, .desc = "TYPE(ieee_round_type)", .mods = &.{"INTENT(in)"} },
            .{ .name = "KIND", .kind = .variable, .desc = "INTEGER", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_real", .kind = .function, .args = "A,KIND", .return_type = "REAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "INTEGER or REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "KIND", .kind = .variable, .desc = "INTEGER", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_max", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_min", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_max_mag", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_min_mag", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_max_num", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_min_num", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_max_num_mag", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_min_num_mag", .kind = .function, .args = "X,Y", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "Y", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_next_down", .kind = .function, .args = "X", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_next_up", .kind = .function, .args = "X", .return_type = "REAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_quiet_eq", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_quiet_ge", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_quiet_gt", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_quiet_le", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_quiet_lt", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_quiet_ne", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signaling_eq", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signaling_ge", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signaling_gt", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signaling_le", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signaling_lt", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signaling_ne", .kind = .function, .args = "A,B", .return_type = "LOGICAL", .children = &.{
            .{ .name = "A", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
            .{ .name = "B", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_signbit", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "ieee_support_subnormal", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_support_underflow_control", .kind = .function, .args = "X", .return_type = "LOGICAL", .children = &.{
            .{ .name = "X", .kind = .variable, .desc = "REAL", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "ieee_get_underflow_mode", .kind = .subroutine, .args = "GRADUAL", .children = &.{
            .{ .name = "GRADUAL", .kind = .variable, .desc = "LOGICAL", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "ieee_set_underflow_mode", .kind = .subroutine, .args = "GRADUAL", .children = &.{
            .{ .name = "GRADUAL", .kind = .variable, .desc = "LOGICAL", .mods = &.{"INTENT(in)"} },
        } },
    } },
    .{ .name = "ieee_features", .members = &.{
        .{ .name = "ieee_features_type", .kind = .type },
        .{ .name = "ieee_denormal", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_divide", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_halting", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_inexact_flag", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_inf", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_invalid_flag", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_nan", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_rounding", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_sqrt", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
        .{ .name = "ieee_underflow_flag", .kind = .variable, .desc = "TYPE(ieee_features_type)" },
    } },
};
