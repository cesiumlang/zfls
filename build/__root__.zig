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
    const kit = @import("ifxkit.zig").add(b);

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
    test_step.dependOn(&b.addRunArtifact(addReleaseTool(b, "source_archive", "source-archive", "Write the source archive zfls-v<version>-src.tar.gz, submodules included (-- [OUT_DIR], default dist)")).step);
    test_step.dependOn(&b.addRunArtifact(addReleaseTool(b, "package_vscode", "package-vscode", "Package the VS Code extension per platform from the release archives (-- DIST)")).step);

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

    // The corpus damaged as half-typed code is (tests/damaged_source.zig):
    // a sample in `zig build test`, all of it in `zig build test-damaged`
    const damaged_mod = b.createModule(.{
        .root_source_file = b.path("tests/damaged_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfls", .module = mod }},
    });
    const damaged_tests = b.addTest(.{ .root_module = damaged_mod });
    test_step.dependOn(&b.addRunArtifact(damaged_tests).step);
    const run_damaged_long = b.addRunArtifact(damaged_tests);
    run_damaged_long.setEnvironmentVariable("ZFLS_DAMAGE", "long");
    const damaged_step = b.step("test-damaged", "Damage every line of the test corpus and check the server's answers (minutes)");
    damaged_step.dependOn(&run_damaged_long.step);

    addScriptTests(b, mod, exe, test_step, damaged_step, kit.dir);
}

/// Steps running the test drivers in tests/ against the built server: the
/// Zig ones, which `zig build test-tools` installs (for a server built
/// elsewhere: `zig-out/bin/stress_edit --zfls EXE`), and the Python ones,
/// which run fortls; and `zig build bench -- WORKSPACE [--fortls CMD] ...`,
/// zfls (and fortls when CMD starts it) timed on a large workspace
/// (tools/bench_workspace.zig; build with -Doptimize=safe). Their
/// unit tests are part of `test_step`.
fn addScriptTests(b: *std.Build, mod: *std.Build.Module, exe: *std.Build.Step.Compile, test_step: *std.Build.Step, damaged_step: *std.Build.Step, kit: std.Build.LazyPath) void {
    const python = b.option([]const u8, "python", "Python interpreter for script tests (default: python)") orelse "python";
    const fortls = b.option([]const u8, "fortls", "Path to a fortls checkout (default: ../fortls)");
    const all = b.step("test-all", "Run unit tests, fortls parity, the gfortran, Flang and ifx oracles and the stress test");
    all.dependOn(b.getInstallStep());
    all.dependOn(test_step);
    all.dependOn(damaged_step);

    const client = b.createModule(.{
        .root_source_file = b.path("tests/lsp_client.zig"),
        .imports = &.{.{ .name = "zfls", .module = mod }},
    });
    const tools_step = b.step("test-tools", "Install the Zig test drivers (gfortran, Flang and ifx oracles, stress test, zfls dap with the engine, gdb and lldb-dap, the compiler check)");
    const Tool = struct { name: []const u8, root: []const u8, step: ?[]const u8, desc: []const u8, needs_fortls: bool, needs_zig: bool = false, in_test: bool = false, windows_only: bool = false, needs_kit: bool = false };
    const tools = [_]Tool{
        .{
            .name = "gfortran_oracle",
            .root = "tests/gfortran_oracle.zig",
            .step = "test-oracle",
            .desc = "Compare zfls symbols with gfortran parse trees of tests/fortran",
            .needs_fortls = false,
        },
        .{
            .name = "flang_oracle",
            .root = "tests/flang_oracle.zig",
            .step = "test-flang-oracle",
            .desc = "Compare zfls symbols with LLVM Flang's of tests/fortran, tests/flang, their module files and Flang's intrinsic modules (skipped without Flang; FLANG names it)",
            .needs_fortls = false,
        },
        .{
            .name = "ifx_oracle",
            .root = "tests/ifx_oracle.zig",
            .step = "test-ifx-oracle",
            .desc = "Compare zfls symbols, types and kinds with ifx's listings (/list /show:map) of tests/fortran and tests/ifx (skipped without ifx; IFX names it)",
            .needs_fortls = false,
        },
        .{
            .name = "stress_edit",
            .root = "tests/stress_edit.zig",
            .step = "test-stress",
            .desc = "Run randomized long editing sessions against zfls (use a Debug build)",
            .needs_fortls = true,
        },
        .{
            .name = "dap_windows",
            .root = "tests/dap_windows.zig",
            .step = "test-dap",
            .desc = "Debug a C program with zfls dap (Windows only; zig cc builds it, linked with the ifx kit), LLVM Flang's with -- --flang FLANG and ifx's with -- --ifx IFX",
            .needs_fortls = false,
            .needs_zig = true,
            .needs_kit = true,
        },
        .{
            .name = "dap_gdb",
            .root = "tests/dap_gdb.zig",
            .step = "test-dap-gdb",
            .desc = "Debug a gfortran program (or LLVM Flang's, with -- --compiler flang, linked with the ifx kit on Windows x64; LFortran's with -- --compiler lfortran, not on Windows) with zfls dap and gdb (skipped without the compiler or gdb 14+)",
            .needs_fortls = false,
            .needs_kit = true,
        },
        .{
            .name = "dap_lldb",
            .root = "tests/dap_lldb.zig",
            .step = "test-dap-lldb",
            .desc = "Debug a gfortran program (or LFortran's, with -- --compiler lfortran) with zfls dap and lldb-dap (skipped without the compiler or lldb-dap)",
            .needs_fortls = false,
        },
        .{
            .name = "build_command",
            .root = "tests/build_command.zig",
            .step = "test-build-command",
            .desc = "Build a Fortran file with the command zfls build-command answers and run its program: gfortran, or another with -- --compiler C (LLVM Flang and ifx linked with the ifx kit on Windows x64) (skipped without the compiler)",
            .needs_fortls = false,
            .needs_kit = true,
        },
        .{
            .name = "compiler_check",
            .root = "tests/compiler_check.zig",
            .step = "test-compiler",
            .desc = "Check tests/compiler with compiler_diagnostics and a real LFortran, or LLVM Flang with -- --compiler flang (skipped without it)",
            .needs_fortls = false,
        },
        .{
            .name = "async_stdio",
            .root = "tests/async_stdio.zig",
            .step = "test-stdio",
            .desc = "Run zfls on standard streams opened for overlapped I/O (Windows only)",
            .needs_fortls = false,
            .in_test = true,
            .windows_only = true,
        },
        .{
            .name = "cancel_request",
            .root = "tests/cancel_request.zig",
            .step = "test-cancel",
            .desc = "Cancel a running request and one waiting behind it ($/cancelRequest)",
            .needs_fortls = false,
            .in_test = true,
        },
        .{
            .name = "bench_workspace",
            .root = "tools/bench_workspace.zig",
            .step = null,
            .desc = "Time zfls (and fortls, with -- --fortls CMD) on a workspace (-- WORKSPACE)",
            .needs_fortls = false,
        },
    };
    for (tools) |t| {
        const tool_mod = b.createModule(.{
            .root_source_file = b.path(t.root),
            .target = mod.resolved_target,
            .optimize = mod.optimize,
            .imports = &.{
                .{ .name = "zfls", .module = mod },
                .{ .name = "lsp_client", .module = client },
            },
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tool_mod })).step);
        const tool = b.addExecutable(.{ .name = t.name, .root_module = tool_mod });
        if (t.step != null) tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
        const run = b.addRunArtifact(tool);
        run.setCwd(b.path(""));
        run.addArg("--zfls");
        run.addArtifactArg2(exe, .{});
        if (t.needs_fortls) if (fortls) |f| run.addArgs(&.{ "--fortls", f });
        if (t.needs_zig) run.addArgs(&.{ "--zig", b.graph.zig_exe });
        // LLVM Flang's programs link with the ifx kit, built for the test,
        // not with whatever the machine has (Visual Studio): the zfls of
        // the cache has no kit next to it (#442)
        const target = mod.resolved_target.?.result;
        if (t.needs_kit and target.os.tag == .windows and target.cpu.arch == .x86_64) {
            run.addArg("--kit");
            run.addDirectoryArg2(kit, .{});
        }
        run.addPassthruArgs();
        // They report their own results; always rerun them
        run.has_side_effects = true;
        b.step(t.step orelse "bench", t.desc).dependOn(&run.step);
        if (t.step != null) all.dependOn(&run.step);
        // quick, and needs nothing installed: also part of `zig build test`
        const native = b.graph.host.result.os.tag == target.os.tag and b.graph.host.result.cpu.arch == target.cpu.arch;
        if (t.in_test and native and (!t.windows_only or target.os.tag == .windows)) test_step.dependOn(&run.step);
    }

    const Script = struct { step: []const u8, desc: []const u8, script: []const u8, needs_fortls: bool };
    const scripts = [_]Script{
        .{
            .step = "test-parity",
            .desc = "Run the fortls language server test suite against zfls",
            .script = "tests/fortls_parity.py",
            .needs_fortls = true,
        },
        .{
            .step = "test-differential",
            .desc = "Compare zfls responses with Python fortls over its corpus (slow)",
            .script = "tests/differential.py",
            .needs_fortls = true,
        },
    };
    for (scripts) |s| {
        const run = b.addSystemCommand(&.{python});
        run.addFileArg(b.path(s.script));
        run.addArg("--zfls");
        run.addArtifactArg2(exe, .{});
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
/// ARCHIVE (build/conda_recipe.zig). Paths are relative to the repository.
/// Returns the generator's unit tests.
fn addCondaRecipe(b: *std.Build) *std.Build.Step.Compile {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("build/conda_recipe.zig"),
        .target = b.graph.host,
    });
    const gen = b.addRunArtifact(b.addExecutable(.{ .name = "conda_recipe", .root_module = gen_mod }));
    gen.setCwd(b.path(""));
    gen.addDirectoryArg2(b.path("packaging/conda-forge"), .{});
    gen.addPassthruArgs();
    // writes outside the cache
    gen.has_side_effects = true;
    b.step("conda-recipe", "Write the conda-forge recipe for a zfls source archive (-- --release|--local ARCHIVE OUT_DIR)").dependOn(&gen.step);
    return b.addTest(.{ .root_module = gen_mod });
}

/// `zig build STEP -- ARGS...`: the release packaging program
/// build/NAME.zig, run at the root of the repository with build.zig.zon's
/// version as its first argument: `source-archive` (build/source_archive.zig)
/// and `package-vscode` (build/package_vscode.zig). Paths are relative to
/// the repository. Returns its unit tests.
fn addReleaseTool(b: *std.Build, name: []const u8, step: []const u8, desc: []const u8) *std.Build.Step.Compile {
    const tool_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("build/{s}.zig", .{name})),
        .target = b.graph.host,
        // compressing the source archive takes minutes in Debug
        .optimize = .safe,
    });
    const run = b.addRunArtifact(b.addExecutable(.{ .name = name, .root_module = tool_mod }));
    run.setCwd(b.path(""));
    run.addArg(zon.version);
    run.addPassthruArgs();
    // writes outside the cache
    run.has_side_effects = true;
    b.step(step, desc).dependOn(&run.step);
    return b.addTest(.{ .root_module = tool_mod });
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
/// markdown }`) from the Markdown pages of M_intrinsics (the vendor/
/// submodule), one `md3/NAME.md` per intrinsic procedure
/// (build/intrinsic_docs.zig). Returns
/// the generator's unit tests.
fn addIntrinsicDocs(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("build/intrinsic_docs.zig"),
        .target = b.graph.host,
    });
    const gen = b.addRunArtifact(b.addExecutable(.{ .name = "intrinsic_docs", .root_module = gen_mod }));
    gen.addDirectoryArg2(b.path("vendor/M_intrinsics/md3"), .{});
    gen.addDirectoryArg2(b.path("vendor/M_intrinsics/docs"), .{});
    const out = gen.addOutputDirectoryArg2("intrinsic_docs", .{});
    mod.addImport("intrinsic_docs", b.createModule(.{ .root_source_file = out.path(b, "intrinsic_docs.zig") }));
    return b.addTest(.{ .root_module = gen_mod });
}
