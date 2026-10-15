const std = @import("std");

pub const zon = @import("../build.zig.zon");
pub const rstd = @import("rstd");

const rstdbuild = rstd.buildutils;
const Build = rstdbuild.Build;

pub fn build(b: *std.Build) !void {
    const target = rstdbuild.getTarget(b);
    const optimize = rstdbuild.getOptimize(b);
    const docs = rstdbuild.addDocs(b);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/__root__.zig"),
        .target = target,
        .optimize = optimize,
        // .link_libc = true,
    });

    addIntrinsicDocs(b, mod);

    const rstd_mod = try rstdbuild.addRstd(b, target, docs, false, .{});
    rstd_mod.addImportToModule(mod);

    // Shared with rstd, so rstd.Logger etc. follow zfls's settings
    // (e.g. -Dlog-scope-level=...).
    const build_options = try rstdbuild.addBuildOptionsModule(b, @tagName(zon.name), zon.version, &rstd_mod);
    try rstdbuild.addLogScopeOptions(b, build_options, &.{});
    try rstdbuild.addBuildOptsModToModule(build_options, mod);
    // zigwin32 comes from rstd's build.zig.zon; nothing to declare here.
    rstdbuild.addWin32ToModIfWinTgt(b, target, mod);

    const exe = b.addExecutable(.{
        .name = "zfls",
        .root_module = mod,
    });
    docs.addCompileStepDocs(b, exe, "zfls");
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // While zfls.prerelease sits next to a release build, it reports a
    // release candidate version (src/version.zig). Only release packaging
    // leaves the file out; the binary is the same either way.
    const sentinel = b.addWriteFiles().add("zfls.prerelease",
        \\The presence of this file makes zfls report a release candidate
        \\version. Release archives do not include it.
        \\
    );
    const install_sentinel = b.addInstallBinFile(sentinel, "zfls.prerelease");
    b.getInstallStep().dependOn(&install_sentinel.step);

    // The default install also generates the API documentation (rstd's
    // docs step), which packages do not ship
    const bin_step = b.step("bin", "Install zfls without the API documentation");
    bin_step.dependOn(&install_exe.step);
    bin_step.dependOn(&install_sentinel.step);

    const run_cmd = b.addRunArtifact(exe);
    const run_cmd_step = &run_cmd.step;
    run_cmd_step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(run_cmd_step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zfls's unit tests");
    test_step.dependOn(&run_tests.step);

    // Tests of the open issues of upstream fortls, run in-process (see
    // tests/issues/harness.zig)
    const issue_mod = b.createModule(.{
        .root_source_file = b.path("tests/issues/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfls", .module = mod }},
    });
    const run_issue_tests = b.addRunArtifact(b.addTest(.{ .root_module = issue_mod }));
    const issues_step = b.step("test-issues", "Run the tests of open upstream fortls issues");
    issues_step.dependOn(&run_issue_tests.step);
    test_step.dependOn(&run_issue_tests.step);

    addScriptTests(b, exe);
}

/// Steps running the Python test drivers in tests/ against the built server
fn addScriptTests(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const python = b.option([]const u8, "python", "Python interpreter for script tests (default: python)") orelse "python";
    const fortls = b.option([]const u8, "fortls", "Path to a fortls checkout (default: ../fortls)");

    const Script = struct { step: []const u8, desc: []const u8, script: []const u8, needs_fortls: bool };
    const scripts = [_]Script{
        .{
            .step = "test-parity",
            .desc = "Run the fortls language server test suite against zfls",
            .script = "tests/fortls_parity.py",
            .needs_fortls = true,
        },
        .{
            .step = "test-oracle",
            .desc = "Compare zfls symbols with gfortran parse trees of tests/fortran",
            .script = "tests/gfortran_oracle.py",
            .needs_fortls = false,
        },
        .{
            .step = "test-stress",
            .desc = "Run randomized long editing sessions against zfls (use a Debug build)",
            .script = "tests/stress_edit.py",
            .needs_fortls = true,
        },
        .{
            .step = "test-differential",
            .desc = "Compare zfls responses with Python fortls over its corpus (slow)",
            .script = "tests/differential.py",
            .needs_fortls = true,
        },
    };
    const all = b.step("test-all", "Run unit tests, fortls parity, the gfortran oracle and the stress test");
    all.dependOn(b.getInstallStep());
    if (b.top_level_steps.get("test")) |t| all.dependOn(&t.step);
    for (scripts) |s| {
        const run = b.addSystemCommand(&.{python});
        run.addFileArg(b.path(s.script));
        run.addArg("--zfls");
        run.addArtifactArg(exe);
        if (s.needs_fortls) if (fortls) |f| {
            run.addArg("--fortls");
            run.addArg(f);
        };
        // The scripts report their own results; always rerun them
        run.has_side_effects = true;
        const step = b.step(s.step, s.desc);
        step.dependOn(&run.step);
        if (!std.mem.eql(u8, s.step, "test-differential")) all.dependOn(&run.step);
    }
}

/// Directory of Markdown documentation for intrinsic procedures, one
/// `NAME.md` file per procedure (from the M_intrinsics project).
const intrinsic_docs_dir = "src/data/intrinsics";

/// Embed every `NAME.md` file of `intrinsic_docs_dir` into a generated
/// module `intrinsic_docs` exposing `docs: []const struct { name, markdown }`.
fn addIntrinsicDocs(b: *std.Build, mod: *std.Build.Module) void {
    const io = b.graph.io;
    // Re-run configuration when files are added, removed or renamed
    b.dependOnDirectoryContents(b.path(intrinsic_docs_dir));

    const dir_path = b.pathJoin(&.{ b.root.sub_path, intrinsic_docs_dir });
    var dir = b.root.root_dir.handle.openDir(io, if (dir_path.len == 0) "." else dir_path, .{ .iterate = true }) catch |e|
        std.debug.panic("cannot open {s}: {s}", .{ intrinsic_docs_dir, @errorName(e) });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |e| std.debug.panic("cannot list {s}: {s}", .{ intrinsic_docs_dir, @errorName(e) })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        names.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - 3])) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator,
        \\//! Generated by build.zig from src/data/intrinsics/*.md
        \\pub const Doc = struct { name: []const u8, markdown: []const u8 };
        \\pub const docs = [_]Doc{
        \\
    ) catch @panic("OOM");
    for (names.items) |name| {
        const file = b.fmt("{s}.md", .{name});
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ intrinsic_docs_dir, file })), file);
        src.print(b.allocator, "    .{{ .name = \"{s}\", .markdown = @embedFile(\"{s}\") }},\n", .{ name, file }) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const index = wf.add("intrinsic_docs.zig", src.items);
    mod.addImport("intrinsic_docs", b.createModule(.{ .root_source_file = index }));
}
