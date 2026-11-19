//! Tests of the open issues of upstream fortls (fortran-lang/fortls), as of
//! its commit 0392beb. See harness.zig for how they are written and
//! README.md for the status of each.

test {
    _ = @import("argchecks.zig");
    _ = @import("associate.zig");
    _ = @import("completion.zig");
    _ = @import("compiler_locale.zig");
    _ = @import("constructs.zig");
    _ = @import("corpus.zig");
    _ = @import("debug_options.zig");
    _ = @import("debugging.zig");
    _ = @import("dlines.zig");
    _ = @import("diagnostics.zig");
    _ = @import("compiler_work_dir.zig");
    _ = @import("documents.zig");
    _ = @import("extensions.zig");
    _ = @import("external.zig");
    _ = @import("genmod.zig");
    _ = @import("highlighting.zig");
    _ = @import("hover_arguments.zig");
    _ = @import("hover.zig");
    _ = @import("language.zig");
    _ = @import("lenses.zig");
    _ = @import("navigation.zig");
    _ = @import("outline.zig");
    _ = @import("refactor.zig");
    _ = @import("rename.zig");
    _ = @import("settings.zig");
    _ = @import("signature.zig");
    _ = @import("parsing.zig");
    _ = @import("project.zig");
    _ = @import("use.zig");
    _ = @import("workspace.zig");
    _ = @import("compiler_line_length.zig");
}
