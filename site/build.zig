//! The documentation site: `gen` turns the pages of docs/ into what Zine
//! builds, and Zine writes the site. A package of its own, so that zfls
//! itself does not fetch Zine. From skein's site/build.zig
//! (chasingdaylight/skein@1e2695e).
//!
//!   zig build -p OUT    the site in OUT/public
//!   zig build serve     Zine's live server
//!   zig build test      the generator's tests

const std = @import("std");
const zine = @import("zine");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const content = b.option([]const u8, "content", "The directory of the pages") orelse "../docs";

    // the pages to the input of Zine: content/, assets/site-index.json
    const gen_exe = b.addExecutable(.{
        .name = "zfls-site-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gen/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const gen = b.addRunArtifact(gen_exe);
    gen.setCwd(b.path("."));
    gen.has_side_effects = true;
    gen.addArgs(&.{ "--content", content, "--pages", "pages.txt", "--site", "." });
    // the logo is the repository's: assets/ holds a copy (.gitignore)
    const logo = b.addUpdateSourceFiles();
    logo.addCopyFileToSource(b.path("../logo.svg"), "assets/logo.svg");
    gen.step.dependOn(&logo.step);
    b.step("gen", "Write the input of Zine from the pages").dependOn(&gen.step);

    const site = zine.website(b, .{
        .website_root = b.path("."),
        .output_path = "public",
        .force = true,
    });
    site.step.dependOn(&gen.step);
    b.getInstallStep().dependOn(&site.step);

    // beside the pages, where Zine writes nothing: their Markdown (llms.txt
    // and each page's alternate link point at it), and at the root what
    // browsers and agents ask for there
    const markdown = b.addInstallDirectory(.{
        .source_dir = b.path(content),
        .install_dir = .prefix,
        .install_subdir = "public",
        .include_extensions = &.{".md"},
    });
    markdown.step.dependOn(&site.step);
    b.getInstallStep().dependOn(&markdown.step);
    for ([_][]const u8{ "llms.txt", "assets/favicon.ico" }) |file| {
        const name = b.fmt("public/{s}", .{std.Io.Dir.path.basename(file)});
        const install = b.addInstallFile(b.path(file), name);
        install.step.dependOn(&site.step);
        b.getInstallStep().dependOn(&install.step);
    }

    const serve = zine.serve(b, .{ .website_root = b.path(".") });
    serve.step.dependOn(&gen.step);
    b.step("serve", "Start the Zine dev server").dependOn(&serve.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("gen/__root__.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run the tests of the generator").dependOn(&b.addRunArtifact(tests).step);
}
