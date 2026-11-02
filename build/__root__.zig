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

    const intrinsic_docs_tests = addIntrinsicDocs(b, mod);

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

    // What ifx needs to link without Visual Studio (Windows x64 packages)
    _ = @import("ifxkit.zig").add(b);

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
    test_step.dependOn(&b.addRunArtifact(intrinsic_docs_tests).step);
    test_step.dependOn(&b.addRunArtifact(addCondaRecipe(b)).step);
    test_step.dependOn(&b.addRunArtifact(addGenerated(b)).step);

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

    // Mutated and arbitrary programs thrown at an in-process server
    // (tests/fuzz.zig); `zig build test --fuzz` runs the fuzzer on it
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfls", .module = mod }},
    });
    const run_fuzz_tests = b.addRunArtifact(b.addTest(.{ .root_module = fuzz_mod }));
    const fuzz_step = b.step("test-fuzz", "Run the robustness tests (mutated programs, fuzzing with --fuzz)");
    fuzz_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);

    addScriptTests(b, exe);
    test_step.dependOn(&b.addRunArtifact(addBench(b, mod, exe)).step);
}

/// `zig build bench -- WORKSPACE [--fortls CMD] ...`: zfls, and fortls when
/// CMD starts it, timed on a large workspace (tools/bench_workspace.zig;
/// build with -Doptimize=ReleaseSafe). Returns the benchmark's unit tests.
fn addBench(b: *std.Build, mod: *std.Build.Module, exe: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_workspace.zig"),
        .target = mod.resolved_target,
        .optimize = mod.optimize,
        .imports = &.{.{ .name = "zfls", .module = mod }},
    });
    const run = b.addRunArtifact(b.addExecutable(.{ .name = "bench_workspace", .root_module = bench_mod }));
    run.addArg("--zfls");
    run.addArtifactArg(exe);
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("bench", "Time zfls (and fortls, with -- --fortls CMD) on a workspace (-- WORKSPACE)").dependOn(&run.step);
    return b.addTest(.{ .root_module = bench_mod });
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

/// `zig build conda-recipe -- (--release | --local) ARCHIVE OUT_DIR`: the
/// conda-forge recipe of packaging/conda-forge, for the zfls source archive
/// ARCHIVE, with the Zig packages it provides pinned as the build.zig.zon
/// files pin them (build/conda_recipe.zig). Paths are relative to the
/// repository. Returns the generator's unit tests.
fn addCondaRecipe(b: *std.Build) *std.Build.Step.Compile {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("build/conda_recipe.zig"),
        .target = b.graph.host,
    });
    const gen = b.addRunArtifact(b.addExecutable(.{ .name = "conda_recipe", .root_module = gen_mod }));
    gen.setCwd(b.path(""));
    gen.addDirectoryArg(b.path("packaging/conda-forge"));
    const pins = .{
        // Windows builds only: rstd's Win32 bindings
        .{ "zigwin32", rstd.buildroot.zon.dependencies.win32 },
        .{ "m_intrinsics", zon.dependencies.m_intrinsics },
    };
    inline for (pins) |p| gen.addArgs(&.{ "--pin", p[0], p[1].url, p[1].hash });
    gen.addPassthruArgs();
    // downloads, and writes outside the cache
    gen.has_side_effects = true;
    b.step("conda-recipe", "Write the conda-forge recipe for a zfls source archive (-- --release|--local ARCHIVE OUT_DIR)").dependOn(&gen.step);
    return b.addTest(.{ .root_module = gen_mod });
}

/// `zig build generated` writes the files of the repository generated from
/// others (the configuration file schema, the extension's package.nls.json
/// and l10n bundle: build/generated.zig), and `zig build check-generated`
/// fails when one is out of date. Returns the generator's unit tests.
fn addGenerated(b: *std.Build) *std.Build.Step.Compile {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("build/generated.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "settings", .module = b.createModule(.{ .root_source_file = b.path("src/settings.zig") }) },
            .{ .name = "constants", .module = b.createModule(.{ .root_source_file = b.path("src/constants.zig") }) },
        },
    });
    const exe = b.addExecutable(.{ .name = "generated", .root_module = gen_mod });
    const steps = .{
        .{ "generated", "Write the files generated from others (configuration schema, extension strings)", false },
        .{ "check-generated", "Fail when a file generated from others is out of date", true },
    };
    inline for (steps) |s| {
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path(""));
        run.addArg(".");
        if (s[2]) run.addArg("--check");
        // reads and writes the repository
        run.has_side_effects = true;
        b.step(s[0], s[1]).dependOn(&run.step);
    }
    return b.addTest(.{ .root_module = gen_mod });
}

/// Generate the module `intrinsic_docs` (`docs: []const struct { name,
/// markdown }`) from the Markdown pages of the M_intrinsics package, one
/// `md3/NAME.md` per intrinsic procedure (build/intrinsic_docs.zig). Returns
/// the generator's unit tests.
fn addIntrinsicDocs(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("build/intrinsic_docs.zig"),
        .target = b.graph.host,
    });
    const gen = b.addRunArtifact(b.addExecutable(.{ .name = "intrinsic_docs", .root_module = gen_mod }));
    const upstream = b.dependency("m_intrinsics", .{});
    gen.addDirectoryArg(upstream.path("md3"));
    gen.addDirectoryArg(upstream.path("docs"));
    const out = gen.addOutputDirectoryArg("intrinsic_docs");
    mod.addImport("intrinsic_docs", b.createModule(.{ .root_source_file = out.path(b, "intrinsic_docs.zig") }));
    return b.addTest(.{ .root_module = gen_mod });
}
