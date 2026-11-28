//! The tree of pages: groups, places on the site, front pages, editions.

const std = @import("std");
const testing = std.testing;

const content = @import("../content.zig");
const pages = @import("../pages.zig");
const portable = @import("../portable.zig");

const tree =
    \\# a comment
    \\guides Guides
    \\  quickstart Quickstart
    \\project zfls itself
    \\  requirements/readme Requirements
    \\  requirements/items Items
    \\
;

test "pages.txt gives groups and their pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try pages.parse(arena.allocator(), tree);
    try testing.expectEqual(2, groups.len);
    try testing.expectEqualStrings("project", groups[1].dir);
    try testing.expectEqualStrings("zfls itself", groups[1].title);
    try testing.expectEqualStrings("requirements/items", groups[1].pages[1].path);
    try testing.expectEqualStrings("Items", groups[1].pages[1].title);
    try testing.expectError(error.PageOutsideGroup, pages.parse(arena.allocator(), "  quickstart Quickstart\n"));
}

test "a page goes to its group, a readme is its directory's front page, each edition has its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const groups = try pages.parse(a, tree);
    var found = [_]content.Page{
        content.parse("index", "# zfls\n\nHome.\n"),
        content.parse("quickstart", "# Quickstart\n\nFrom nothing to a project. Then more.\n"),
        content.parse("requirements/readme", "# The requirements of zfls\n\nWhat zfls does.\n"),
        content.parse("requirements/items", "# Items\n\nText.\n"),
        content.parse("v0.2.0/quickstart", "# Quickstart\n\nOlder.\n"),
        content.parse("stray", "# Stray\n\nNot listed.\n"),
    };
    const placed = try pages.place(a, groups, &found);
    const at = struct {
        fn site(list: []const content.Page, slug: []const u8) ?content.Page {
            for (list) |p| if (std.mem.eql(u8, p.slug, slug)) return p;
            return null;
        }
    };
    try testing.expectEqualStrings("index", at.site(placed, "index").?.site);
    try testing.expectEqualStrings("guides/quickstart", at.site(placed, "quickstart").?.site);
    try testing.expectEqualStrings("Quickstart", at.site(placed, "quickstart").?.title);
    try testing.expectEqualStrings("project/requirements/index", at.site(placed, "requirements/readme").?.site);
    try testing.expectEqualStrings("project/requirements", portable.siteSlug(at.site(placed, "requirements/readme").?));
    try testing.expectEqualStrings("Requirements", at.site(placed, "requirements/readme").?.nav_title);
    try testing.expectEqualStrings("v0.2.0/guides/quickstart", at.site(placed, "v0.2.0/quickstart").?.site);
    try testing.expectEqualStrings("stray", at.site(placed, "stray").?.site);

    // the front pages: the group's pages at the top of docs/ and the front pages of directories
    const guides = at.site(placed, "guides/index").?;
    try testing.expectEqualStrings("Guides", guides.title);
    try testing.expectEqualStrings("- [Quickstart](../quickstart.md): From nothing to a project.\n", guides.body);
    const project = at.site(placed, "project/index").?;
    try testing.expectEqualStrings("- [Requirements](../requirements/readme.md): What zfls does.\n", project.body);
    try testing.expect(at.site(placed, "v0.2.0/guides/index") != null);
    try testing.expect(at.site(placed, "v0.2.0/project/index") == null);
    // in the order of pages.txt: a group before its pages
    try testing.expect(guides.sortorder < at.site(placed, "quickstart").?.sortorder);
    try testing.expect(at.site(placed, "quickstart").?.sortorder < project.sortorder);
}

test "an edition is a release's directory" {
    try testing.expectEqualStrings("0.2.0", content.editionOf("v0.2.0/quickstart").?);
    try testing.expect(content.editionOf("vscode") == null);
    try testing.expectEqualStrings("requirements/items", content.withoutEdition("v1.10.3/requirements/items"));
}
