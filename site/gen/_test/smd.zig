//! A page as SuperMD: links, headings, fences, HTML blocks.

const std = @import("std");
const testing = std.testing;

const content = @import("../content.zig");
const fence = @import("../fence.zig");
const portable = @import("../portable.zig");
const smd = @import("../smd.zig");

fn renderOne(a: std.mem.Allocator, all: []const content.Page, index: usize) ![]const u8 {
    var report: portable.Report = .{ .arena = a };
    const rendered = try smd.render(a, all, all[index], "2026-11-27T00:00:00", "zfls 0.2.1", &report);
    const body = rendered.text[std.mem.find(u8, rendered.text[3..], "---\n").? + 7 ..];
    // the last line end of the page, and the one the split adds
    return std.mem.trimEnd(u8, body, "\n");
}

test "links to pages, to the home page and to files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all = [_]content.Page{
        content.parse("index", "# zfls\n\n## Getting it\n"),
        content.parse("quickstart", "# Quickstart\n\nSee [getting it](index.md#getting-it), [items](requirements/items.md), [a site](examples/rover/index.html) and [the web](https://example.com/).\n"),
        content.parse("requirements/items", "# Items\n"),
    };
    all[1].site = "guides/quickstart";
    all[2].site = "project/requirements/items";
    const body = try renderOne(a, &all, 1);
    try testing.expectEqualStrings(
        "See [getting it](/#getting-it), [items]($link.page('project/requirements/items')), " ++
            "[a site]($link.siteAsset('examples/rover/index.html')) and [the web](https://example.com/).",
        body,
    );
}

test "code and HTML as finished HTML, in a fence longer than any inside" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all = [_]content.Page{content.parse("quickstart", "# Q\n\n````markdown\n```text\na < b\n```\n````\n\n<picture>\n  <img src=\"img/a.png\" alt=\"A\">\n</picture>\n")};
    all[0].site = "guides/quickstart";
    const body = try renderOne(a, &all, 0);
    try testing.expectEqualStrings(
        "````=html\n<pre class=\"highlight\"><code class=\"language-markdown\">```text\na &lt; b\n```</code></pre>\n````\n\n" ++
            "```=html\n<picture>\n  <img src=\"/img/a.png\" alt=\"A\">\n</picture>\n```",
        body,
    );
}

test "a fence closes with at least as many of its marks" {
    var f: fence.Fence = .{};
    try testing.expectEqual(fence.Line.open, f.step("````md"));
    try testing.expectEqual(fence.Line.inside, f.step("```"));
    try testing.expectEqual(fence.Line.inside, f.step("~~~~"));
    try testing.expectEqual(fence.Line.close, f.step("`````"));
    try testing.expectEqual(fence.Line.outside, f.step("text"));
}

test "what opens an HTML block" {
    try testing.expect(smd.startsHtml("<picture>"));
    try testing.expect(smd.startsHtml("</div>"));
    try testing.expect(smd.startsHtml("<img src=\"a.png\">"));
    try testing.expect(!smd.startsHtml("<https://example.com>"));
    try testing.expect(!smd.startsHtml("< 3"));
}

test "a path relative to a directory" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("v0.2.0/img/a.png", try portable.join(arena.allocator(), "v0.2.0", "./img/a.png"));
    try testing.expectEqualStrings("img/a.png", try portable.join(arena.allocator(), "requirements", "../img/a.png"));
}
