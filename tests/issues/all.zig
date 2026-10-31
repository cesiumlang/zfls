//! Tests of the open issues of upstream fortls (fortran-lang/fortls), as of
//! its commit 0392beb. See harness.zig for how they are written and
//! README.md for the status of each.

test {
    _ = @import("diagnostics.zig");
    _ = @import("highlighting.zig");
    _ = @import("hover.zig");
    _ = @import("outline.zig");
    _ = @import("rename.zig");
    _ = @import("parsing.zig");
    _ = @import("workspace.zig");
}
