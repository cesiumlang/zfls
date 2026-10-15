//! Types of the intrinsic tables in this directory. The tables are plain
//! constants maintained here (the `NAME.md` documentation in `intrinsics/`
//! is embedded separately, see `build/__root__.zig`).

/// A statement or attribute keyword, as offered by completion.
pub const Keyword = struct {
    name: []const u8,
    /// Argument list added to the completion snippet, e.g. `KIND=kind`
    args: []const u8 = "",
    /// Hover documentation
    doc: ?[]const u8 = null,
};

/// An intrinsic procedure.
pub const Procedure = struct {
    name: []const u8,
    kind: enum { subroutine, function },
    /// Comma separated, e.g. `NAME,MODE`
    args: []const u8 = "",
    /// One line summary, used when there is no `intrinsics/NAME.md`
    doc: []const u8,
};

/// A member of an intrinsic module, or a component or argument of such a
/// member.
pub const Member = struct {
    name: []const u8,
    kind: enum { subroutine, function, variable, type },
    args: []const u8 = "",
    /// The declared type of a variable, e.g. `INTEGER(KIND=omp_sched_kind)`
    desc: []const u8 = "",
    /// The result type of a function
    return_type: ?[]const u8 = null,
    /// Attributes of a variable, e.g. `INTENT(in)` or `DIMENSION(*)`
    mods: []const []const u8 = &.{},
    /// The components of a type, or the arguments of a procedure
    children: []const Member = &.{},
};

pub const Module = struct {
    name: []const u8,
    /// A module whose members this one re-exports
    use: ?[]const u8 = null,
    members: []const Member,
};
