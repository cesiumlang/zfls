//! Intrinsic modules and their members, in the order completion lists them.

const schema = @import("schema.zig");
const Module = schema.Module;

pub const all = [_]Module{
    .{ .name = "omp_lib", .members = &.{
        .{ .name = "openmp_version", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_alloctrait", .kind = .type },
        .{ .name = "omp_sched_static", .kind = .variable, .desc = "INTEGER(KIND=omp_sched_kind)" },
        .{ .name = "omp_sched_dynamic", .kind = .variable, .desc = "INTEGER(KIND=omp_sched_kind)" },
        .{ .name = "omp_sched_guided", .kind = .variable, .desc = "INTEGER(KIND=omp_sched_kind)" },
        .{ .name = "omp_sched_auto", .kind = .variable, .desc = "INTEGER(KIND=omp_sched_kind)" },
        .{ .name = "omp_proc_bind_false", .kind = .variable, .desc = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_proc_bind_true", .kind = .variable, .desc = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_proc_bind_master", .kind = .variable, .desc = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_proc_bind_close", .kind = .variable, .desc = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_proc_bind_spread", .kind = .variable, .desc = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_lock_hint_none", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_lock_hint_uncontended", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_lock_hint_contended", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_lock_hint_nonspeculative", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_lock_hint_speculative", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_sync_hint_none", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_sync_hint_uncontended", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_sync_hint_contended", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_sync_hint_nonspeculative", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_sync_hint_speculative", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_hint_kind)" },
        .{ .name = "omp_pause_soft", .kind = .variable, .desc = "INTEGER(KIND=omp_pause_resource_kind)" },
        .{ .name = "omp_pause_hard", .kind = .variable, .desc = "INTEGER(KIND=omp_pause_resource_kind)" },
        .{ .name = "omp_atk_sync_hint", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_alignment", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_access", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_pool_size", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_fallback", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_fb_data", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_pinned", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atk_partition", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_key_kind)" },
        .{ .name = "omp_atv_default", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_false", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_true", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_contended", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_uncontended", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_serialized", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_sequential", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_private", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_all", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_thread", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_pteam", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_cgroup", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_default_mem_fb", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_null_fb", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_abort_fb", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_allocator_fb", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_environment", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_nearest", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_atv_blocked", .kind = .variable, .desc = "INTEGER(KIND=omp_alloctrait_val_kind)" },
        .{ .name = "omp_null_allocator", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_default_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_large_cap_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_const_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_high_bw_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_low_lat_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_cgroup_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_pteam_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_thread_mem_alloc", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_default_mem_space", .kind = .variable, .desc = "INTEGER(KIND=omp_memspace_handle_kind)" },
        .{ .name = "omp_large_cap_mem_space", .kind = .variable, .desc = "INTEGER(KIND=omp_memspace_handle_kind)" },
        .{ .name = "omp_const_mem_space", .kind = .variable, .desc = "INTEGER(KIND=omp_memspace_handle_kind)" },
        .{ .name = "omp_high_bw_mem_space", .kind = .variable, .desc = "INTEGER(KIND=omp_memspace_handle_kind)" },
        .{ .name = "omp_low_lat_mem_space", .kind = .variable, .desc = "INTEGER(KIND=omp_memspace_handle_kind)" },
        .{ .name = "omp_get_supported_active_levels", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_num_threads", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_max_threads", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_thread_num", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_num_procs", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_thread_limit", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_max_active_levels", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_level", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_ancestor_thread_num", .kind = .function, .args = "level", .return_type = "INTEGER", .children = &.{
            .{ .name = "level", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_get_team_size", .kind = .function, .args = "level", .return_type = "INTEGER", .children = &.{
            .{ .name = "level", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_get_active_level", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_proc_bind", .kind = .function, .return_type = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_get_num_places", .kind = .function, .return_type = "INTEGER(KIND=omp_proc_bind_kind)" },
        .{ .name = "omp_get_place_num_procs", .kind = .function, .args = "place_num", .return_type = "INTEGER", .children = &.{
            .{ .name = "place_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_get_place_proc_ids", .kind = .subroutine, .args = "place_num,ids", .children = &.{
            .{ .name = "place_num", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "ids", .kind = .variable, .desc = "INTEGER", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "omp_get_partition_place_nums", .kind = .subroutine, .args = "place_nums", .children = &.{
            .{ .name = "place_nums", .kind = .variable, .desc = "INTEGER", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "omp_set_affinity_format", .kind = .subroutine, .args = "format", .children = &.{
            .{ .name = "format", .kind = .variable, .desc = "CHARACTER(LEN=*)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "omp_get_affinity_format", .kind = .function, .args = "buffer", .return_type = "INTEGER", .children = &.{
            .{ .name = "buffer", .kind = .variable, .desc = "CHARACTER(LEN=*)", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "omp_display_affinity", .kind = .subroutine, .args = "format", .children = &.{
            .{ .name = "format", .kind = .variable, .desc = "CHARACTER(LEN=*)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "omp_capture_affinity", .kind = .subroutine, .args = "buffer,format", .children = &.{
            .{ .name = "buffer", .kind = .variable, .desc = "CHARACTER(LEN=*)", .mods = &.{"INTENT(out)"} },
            .{ .name = "format", .kind = .variable, .desc = "CHARACTER(LEN=*)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "omp_get_default_device", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_num_devices", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_device_num", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_num_teams", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_team_num", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_in_parallel", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "omp_get_dynamic", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "omp_get_cancellation", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "omp_get_nested", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "omp_in_final", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "omp_is_initial_device", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "omp_get_initial_device", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_get_max_task_priority", .kind = .function, .return_type = "INTEGER" },
        .{ .name = "omp_pause_resource", .kind = .function, .args = "kind,device_num", .return_type = "INTEGER", .children = &.{
            .{ .name = "kind", .kind = .variable, .desc = "INTEGER(KIND=omp_pause_resource_kind)" },
            .{ .name = "device_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_pause_resource_all", .kind = .function, .args = "kind", .return_type = "INTEGER", .children = &.{
            .{ .name = "kind", .kind = .variable, .desc = "INTEGER(KIND=omp_pause_resource_kind)" },
        } },
        .{ .name = "omp_get_wtime", .kind = .function, .return_type = "DOUBLE PRECISION" },
        .{ .name = "omp_get_wtick", .kind = .function, .return_type = "DOUBLE PRECISION" },
        .{ .name = "omp_fulfill_event", .kind = .subroutine, .args = "event", .children = &.{
            .{ .name = "event", .kind = .variable, .desc = "INTEGER(KIND=omp_event_handle_kind)" },
        } },
        .{ .name = "omp_init_allocator", .kind = .function, .args = "memspace,ntraits,traits", .return_type = "INTEGER(KIND=omp_allocator_handle_kind)", .children = &.{
            .{ .name = "memspace", .kind = .variable, .desc = "INTEGER(KIND=omp_memspace_handle_kind)", .mods = &.{"INTENT(in)"} },
            .{ .name = "ntraits", .kind = .variable, .desc = "INTEGER", .mods = &.{"INTENT(in)"} },
            .{ .name = "traits", .kind = .variable, .desc = "TYPE(omp_alloctrait)", .mods = &.{ "DIMENSION(*)", "INTENT(in)" } },
        } },
        .{ .name = "omp_destroy_allocator", .kind = .subroutine, .args = "allocator", .children = &.{
            .{ .name = "allocator", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "omp_set_default_allocator", .kind = .subroutine, .args = "allocator", .children = &.{
            .{ .name = "allocator", .kind = .variable, .desc = "INTEGER(KIND=omp_allocator_handle_kind)", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "omp_get_default_allocator", .kind = .function, .return_type = "INTEGER(KIND=omp_allocator_handle_kind)" },
        .{ .name = "omp_control_tool", .kind = .function, .args = "command,modifier", .return_type = "INTEGER", .children = &.{
            .{ .name = "command", .kind = .variable, .desc = "INTEGER(KIND=omp_control_tool_kind)" },
            .{ .name = "modifier", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_test_lock", .kind = .function, .args = "svar", .return_type = "LOGICAL", .children = &.{
            .{ .name = "svar", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_kind)" },
        } },
        .{ .name = "omp_test_nest_lock", .kind = .function, .args = "nvar", .return_type = "LOGICAL", .children = &.{
            .{ .name = "nvar", .kind = .variable, .desc = "INTEGER(KIND=omp_nest_lock_kind)" },
        } },
        .{ .name = "omp_set_num_threads", .kind = .subroutine, .args = "num_threads", .children = &.{
            .{ .name = "num_threads", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_set_dynamic", .kind = .subroutine, .args = "dynamic_threads", .children = &.{
            .{ .name = "dynamic_threads", .kind = .variable, .desc = "LOGICAL" },
        } },
        .{ .name = "omp_set_nested", .kind = .subroutine, .args = "nested", .children = &.{
            .{ .name = "nested", .kind = .variable, .desc = "LOGICAL" },
        } },
        .{ .name = "omp_set_schedule", .kind = .subroutine, .args = "kind,chunk_size", .children = &.{
            .{ .name = "kind", .kind = .variable, .desc = "INTEGER(KIND=omp_sched_kind)" },
            .{ .name = "chunk_size", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_get_schedule", .kind = .subroutine, .args = "kind,chunk_size", .children = &.{
            .{ .name = "kind", .kind = .variable, .desc = "INTEGER(KIND=omp_sched_kind)" },
            .{ .name = "chunk_size", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_set_max_active_levels", .kind = .subroutine, .args = "max_levels", .children = &.{
            .{ .name = "max_levels", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_set_default_device", .kind = .subroutine, .args = "device_num", .children = &.{
            .{ .name = "device_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "omp_init_lock", .kind = .subroutine, .args = "svar", .children = &.{
            .{ .name = "svar", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_kind)" },
        } },
        .{ .name = "omp_init_nest_lock", .kind = .subroutine, .args = "nvar", .children = &.{
            .{ .name = "nvar", .kind = .variable, .desc = "INTEGER(KIND=omp_nest_lock_kind)" },
        } },
        .{ .name = "omp_init_lock_with_hint", .kind = .subroutine, .args = "svar,hint", .children = &.{
            .{ .name = "svar", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_kind)" },
            .{ .name = "hint", .kind = .variable, .desc = "INTEGER(KIND=omp_sync_hint_kind)" },
        } },
        .{ .name = "omp_init_nest_lock_with_hint", .kind = .subroutine, .args = "nvar,hint", .children = &.{
            .{ .name = "nvar", .kind = .variable, .desc = "INTEGER(KIND=omp_nest_lock_kind)" },
            .{ .name = "hint", .kind = .variable, .desc = "INTEGER(KIND=omp_sync_hint_kind)" },
        } },
        .{ .name = "omp_destroy_lock", .kind = .subroutine, .args = "svar", .children = &.{
            .{ .name = "svar", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_kind)" },
        } },
        .{ .name = "omp_destroy_nest_lock", .kind = .subroutine, .args = "nvar", .children = &.{
            .{ .name = "nvar", .kind = .variable, .desc = "INTEGER(KIND=omp_nest_lock_kind)" },
        } },
        .{ .name = "omp_set_lock", .kind = .subroutine, .args = "svar", .children = &.{
            .{ .name = "svar", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_kind)" },
        } },
        .{ .name = "omp_set_nest_lock", .kind = .subroutine, .args = "nvar", .children = &.{
            .{ .name = "nvar", .kind = .variable, .desc = "INTEGER(KIND=omp_nest_lock_kind)" },
        } },
        .{ .name = "omp_unset_lock", .kind = .subroutine, .args = "svar", .children = &.{
            .{ .name = "svar", .kind = .variable, .desc = "INTEGER(KIND=omp_lock_kind)" },
        } },
        .{ .name = "omp_unset_nest_lock", .kind = .subroutine, .args = "nvar", .children = &.{
            .{ .name = "nvar", .kind = .variable, .desc = "INTEGER(KIND=omp_nest_lock_kind)" },
        } },
    } },
    .{ .name = "omp_lib_kinds", .members = &.{
        .{ .name = "omp_allocator_handle_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_alloctrait_key_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_alloctrait_val_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_depend_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_lock_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_lock_hint_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_nest_lock_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_pause_resource_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_memspace_handle_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_proc_bind_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_sched_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "omp_sync_hint_kind", .kind = .variable, .desc = "INTEGER" },
    } },
    .{ .name = "openacc", .members = &.{
        .{ .name = "openacc_version", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "acc_device_property_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "acc_get_num_devices", .kind = .function, .args = "dev_type", .return_type = "INTEGER", .children = &.{
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_set_device_type", .kind = .subroutine, .args = "dev_type", .children = &.{
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_get_device_type", .kind = .function, .return_type = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_set_device_num", .kind = .subroutine, .args = "dev_num,dev_type", .children = &.{
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_get_device_num", .kind = .function, .args = "dev_type", .return_type = "INTEGER", .children = &.{
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_get_property", .kind = .function, .args = "dev_num,dev_type,property", .return_type = "INTEGER(KIND=c_size_t)", .children = &.{
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER", .mods = &.{"VALUE"} },
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)", .mods = &.{"VALUE"} },
            .{ .name = "property", .kind = .variable, .desc = "INTEGER(KIND=acc_device_property_kind)", .mods = &.{"VALUE"} },
        } },
        .{ .name = "acc_get_property_string", .kind = .subroutine, .args = "dev_num,dev_type,property,string", .children = &.{
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER", .mods = &.{"VALUE"} },
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)", .mods = &.{"VALUE"} },
            .{ .name = "property", .kind = .variable, .desc = "INTEGER(KIND=acc_device_property_kind)", .mods = &.{"VALUE"} },
            .{ .name = "string", .kind = .variable, .desc = "CHARACTER(LEN=*)" },
        } },
        .{ .name = "acc_init", .kind = .subroutine, .args = "dev_type", .children = &.{
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)", .mods = &.{"VALUE"} },
        } },
        .{ .name = "acc_shutdown", .kind = .subroutine, .args = "dev_type", .children = &.{
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_async_test", .kind = .function, .args = "wait_arg", .return_type = "LOGICAL", .children = &.{
            .{ .name = "wait_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_async_test_device", .kind = .function, .args = "wait_arg,dev_num", .return_type = "LOGICAL", .children = &.{
            .{ .name = "wait_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_async_test_all", .kind = .function, .return_type = "LOGICAL" },
        .{ .name = "acc_async_test_all_device", .kind = .function, .args = "dev_num", .return_type = "LOGICAL", .children = &.{
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_wait", .kind = .subroutine, .args = "wait_arg", .children = &.{
            .{ .name = "wait_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_wait", .kind = .subroutine, .args = "wait_arg,dev_num", .children = &.{
            .{ .name = "wait_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_wait_async", .kind = .subroutine, .args = "wait_arg,async_arg", .children = &.{
            .{ .name = "wait_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_wait_device_async", .kind = .subroutine, .args = "wait_arg,async_arg,dev_num", .children = &.{
            .{ .name = "wait_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_wait_all", .kind = .subroutine },
        .{ .name = "acc_wait_all_device", .kind = .subroutine, .args = "dev_num", .children = &.{
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_wait_all_async", .kind = .subroutine, .args = "async_arg", .children = &.{
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_wait_all_device_async", .kind = .subroutine, .args = "async_arg,dev_num", .children = &.{
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
            .{ .name = "dev_num", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_get_default_async", .kind = .function, .return_type = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_set_default_async", .kind = .subroutine, .args = "async_arg", .children = &.{
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_on_device", .kind = .function, .args = "dev_type", .return_type = "LOGICAL", .children = &.{
            .{ .name = "dev_type", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        } },
        .{ .name = "acc_copyin", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_copyin", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_copyin_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_copyin_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_create", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_create", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_create_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_create_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_copyout", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_copyout", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_copyout_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_copyout_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_copyout_finalize", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_copyout_finalize", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_copyout_finalize_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_copyout_finalize_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_delete", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_delete", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_delete_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_delete_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_delete_finalize", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_delete_finalize", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_delete_finalize_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_delete_finalize_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_update_device", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_update_device", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_update_device_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_update_device_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_update_self", .kind = .subroutine, .args = "data_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_update_self", .kind = .subroutine, .args = "data_arg,bytes", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_update_self_async", .kind = .subroutine, .args = "data_arg,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_update_self_async", .kind = .subroutine, .args = "data_arg,bytes,async_arg", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "async_arg", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        } },
        .{ .name = "acc_is_present", .kind = .function, .args = "data_arg", .return_type = "LOGICAL", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
        } },
        .{ .name = "acc_is_present", .kind = .function, .args = "data_arg,bytes", .return_type = "LOGICAL", .children = &.{
            .{ .name = "data_arg", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
        } },
        .{ .name = "acc_memcpy_d2d", .kind = .subroutine, .args = "data_arg_dest,data_arg_src,bytes,dev_num_dest,dev_num_src", .children = &.{
            .{ .name = "data_arg_dest", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "data_arg_src", .kind = .variable, .desc = "TYPE(*)", .mods = &.{"DIMENSION(*)"} },
            .{ .name = "bytes", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "dev_num_dest", .kind = .variable, .desc = "INTEGER" },
            .{ .name = "dev_num_src", .kind = .variable, .desc = "INTEGER" },
        } },
    } },
    .{ .name = "openacc_kinds", .members = &.{
        .{ .name = "acc_device_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "acc_device_none", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_device_default", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_device_host", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_device_not_host", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_device_nvidia", .kind = .variable, .desc = "INTEGER(KIND=acc_device_kind)" },
        .{ .name = "acc_handle_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "acc_async_noval", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
        .{ .name = "acc_async_sync", .kind = .variable, .desc = "INTEGER(KIND=acc_handle_kind)" },
    } },
    .{ .name = "iso_fortran_env", .members = &.{
        .{ .name = "atomic_int_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "atomic_logical_kind", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "character_kinds", .kind = .variable, .desc = "INTEGER", .mods = &.{"DIMENSION(:)"} },
        .{ .name = "character_storage_size", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "error_unit", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "file_storage_size", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "input_unit", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "int8", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "int16", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "int32", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "int64", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "integer_kinds", .kind = .variable, .desc = "INTEGER", .mods = &.{"DIMENSION(:)"} },
        .{ .name = "iostat_end", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "iostat_eor", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "iostat_inquire_internal_unit", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "numeric_storage_size", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "logical_kinds", .kind = .variable, .desc = "INTEGER", .mods = &.{"DIMENSION(:)"} },
        .{ .name = "output_unit", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "real32", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "real64", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "real128", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "real_kinds", .kind = .variable, .desc = "INTEGER", .mods = &.{"DIMENSION(:)"} },
        .{ .name = "stat_locked", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "stat_locked_other_image", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "stat_stopped_image", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "stat_failed_image", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "stat_unlocked", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "lock_type", .kind = .type },
        .{ .name = "compiler_options", .kind = .function, .return_type = "CHARACTER(LEN=*)" },
        .{ .name = "compiler_version", .kind = .function, .return_type = "CHARACTER(LEN=*)" },
    } },
    .{ .name = "iso_c_binding", .members = &.{
        .{ .name = "c_int", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_short", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_long", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_long_long", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_signed_char", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_size_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int8_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int16_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int32_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int64_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int128_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_least8_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_least16_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_least32_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_least64_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_least128_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_fast8_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_fast16_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_fast32_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_fast64_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_int_fast128_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_intmax_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_intptr_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_ptrdiff_t", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_float", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_double", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_long_double", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_float128", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_float_complex", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_double_complex", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_long_double_complex", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_float128_complex", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_bool", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_char", .kind = .variable, .desc = "INTEGER" },
        .{ .name = "c_null_char", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_alert", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_backspace", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_form_feed", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_new_line", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_carriage_return", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_horizontal_tab", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_vertical_tab", .kind = .variable, .desc = "CHARACTER(KIND=c_char)" },
        .{ .name = "c_null_ptr", .kind = .variable, .desc = "TYPE(c_ptr)" },
        .{ .name = "c_null_funptr", .kind = .variable, .desc = "TYPE(c_funptr)" },
        .{ .name = "c_ptr", .kind = .type },
        .{ .name = "c_funptr", .kind = .type },
        .{ .name = "c_associated", .kind = .function, .args = "c_ptr_1,c_ptr_2", .return_type = "LOGICAL", .children = &.{
            .{ .name = "c_ptr_1", .kind = .variable, .desc = "TYPE(c_ptr)", .mods = &.{"INTENT(in)"} },
            .{ .name = "c_ptr_2", .kind = .variable, .desc = "TYPE(c_ptr)", .mods = &.{ "OPTIONAL", "INTENT(in)" } },
        } },
        .{ .name = "c_f_pointer", .kind = .subroutine, .args = "cptr,fptr,shape", .children = &.{
            .{ .name = "cptr", .kind = .variable, .desc = "INTENT(in)", .mods = &.{"INTENT(in)"} },
            .{ .name = "fptr", .kind = .variable, .desc = "ANY", .mods = &.{ "POINTER", "INTENT(out)" } },
            .{ .name = "shape", .kind = .variable, .desc = "INTEGER", .mods = &.{ "DIMENSION(:)", "INTENT(in)" } },
        } },
        .{ .name = "c_f_procpointer", .kind = .subroutine, .args = "cptr,fptr", .children = &.{
            .{ .name = "cptr", .kind = .variable, .desc = "TYPE(c_funptr)", .mods = &.{"INTENT(in)"} },
            .{ .name = "fptr", .kind = .variable, .desc = "PROCEDURE", .mods = &.{ "POINTER", "INTENT(out)" } },
        } },
        .{ .name = "c_funloc", .kind = .function, .args = "x", .return_type = "TYPE(c_funptr)", .children = &.{
            .{ .name = "x", .kind = .variable, .desc = "PROCEDURE", .mods = &.{"INTENT(in)"} },
        } },
        .{ .name = "c_loc", .kind = .function, .args = "x", .return_type = "TYPE(c_ptr)", .children = &.{
            .{ .name = "x", .kind = .variable, .desc = "ANY", .mods = &.{ "POINTER", "INTENT(in)" } },
        } },
        .{ .name = "c_sizeof", .kind = .function, .args = "x", .return_type = "INTEGER(KIND=c_size_t)", .children = &.{
            .{ .name = "x", .kind = .variable, .desc = "ANY", .mods = &.{"INTENT(in)"} },
        } },
    } },
    .{ .name = "ieee_exceptions", .members = &.{
        .{ .name = "ieee_flag_type", .kind = .type },
        .{ .name = "ieee_overflow", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_divide_by_zero", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_invalid", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_underflow", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_inexact", .kind = .variable, .desc = "TYPE(ieee_flag_type)" },
        .{ .name = "ieee_usual", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"DIMENSION(3)"} },
        .{ .name = "ieee_all", .kind = .variable, .desc = "TYPE(ieee_flag_type)", .mods = &.{"DIMENSION(5)"} },
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
        .{ .name = "ieee_nearest", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
        .{ .name = "ieee_to_zero", .kind = .variable, .desc = "TYPE(ieee_round_type)" },
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
        .{ .name = "ieee_get_rounding_mode", .kind = .subroutine, .args = "ROUND_VALUE", .children = &.{
            .{ .name = "ROUND_VALUE", .kind = .variable, .desc = "TYPE(ieee_round_type)", .mods = &.{"INTENT(out)"} },
        } },
        .{ .name = "ieee_set_rounding_mode", .kind = .subroutine, .args = "ROUND_VALUE", .children = &.{
            .{ .name = "ROUND_VALUE", .kind = .variable, .desc = "TYPE(ieee_round_type)", .mods = &.{"INTENT(in)"} },
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
