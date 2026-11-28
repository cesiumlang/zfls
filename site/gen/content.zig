//! The pages of the site: the Markdown files of docs/ (and an earlier
//! release's under vX.Y.Z/, where there is one). From skein's
//! site/gen/content.zig (chasingdaylight/skein@1e2695e), itself from
//! cesiumlang.org's tools/ai/content.zig (cesiumlang/cesiumlang.org@c657aa2);
//! a page here has no front matter: its title is its first heading, and its
//! place on the site comes from pages.txt (pages.zig).

const std = @import("std");

pub const Page = struct {
    /// Path without the extension, with forward slashes, as under docs/:
    /// `requirements/items`, `v0.2.0/quickstart`.
    slug: []const u8,
    /// The first heading.
    title: []const u8,
    /// The title in the tree of pages (pages.txt); the title when not listed.
    nav_title: []const u8,
    description: ?[]const u8 = null,
    sortorder: i64 = std.math.maxInt(i32),
    tags: []const []const u8 = &.{},
    /// Where the page is on the site, without the extension: `guides/quickstart`,
    /// `project/notes/index`, `index` for the home page.
    site: []const u8,
    /// The text after the title, with LF line ends.
    body: []const u8,

    /// The directory of the page under docs/: `requirements` for `requirements/items`.
    pub fn dir(self: Page) []const u8 {
        const slash = std.mem.findScalarLast(u8, self.slug, '/') orelse return "";
        return self.slug[0..slash];
    }

    pub fn basename(self: Page) []const u8 {
        const slash = std.mem.findScalarLast(u8, self.slug, '/') orelse return self.slug;
        return self.slug[slash + 1 ..];
    }

    /// Whether the page is its directory's front page (`index.md`, `readme.md`).
    pub fn isIndex(self: Page) bool {
        return isIndexName(self.basename());
    }

    /// The release whose edition the page belongs to, `0.2.0` for
    /// `v0.2.0/quickstart`; null for the latest release's pages.
    pub fn edition(self: Page) ?[]const u8 {
        return editionOf(self.slug);
    }

    /// The slug within its edition: `quickstart` for `v0.2.0/quickstart`.
    pub fn withinEdition(self: Page) []const u8 {
        return withoutEdition(self.slug);
    }

    fn lessThan(_: void, a: Page, b: Page) bool {
        if (a.sortorder != b.sortorder) return a.sortorder < b.sortorder;
        return std.mem.lessThan(u8, a.slug, b.slug);
    }
};

pub fn isIndexName(name: []const u8) bool {
    return std.mem.eql(u8, name, "index") or std.ascii.eqlIgnoreCase(name, "readme");
}

/// `0.2.0` for a path under `v0.2.0/`, else null.
pub fn editionOf(path: []const u8) ?[]const u8 {
    const top = path[0 .. std.mem.findScalar(u8, path, '/') orelse path.len];
    if (top.len < 6 or top[0] != 'v') return null;
    var parts = std.mem.splitScalar(u8, top[1..], '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return null;
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
    }
    return if (count == 3) top[1..] else null;
}

pub fn withoutEdition(path: []const u8) []const u8 {
    const release = editionOf(path) orelse return path;
    const rest = path[release.len + 1 ..];
    return if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;
}

pub fn sort(pages: []Page) void {
    std.mem.sort(Page, pages, {}, Page.lessThan);
}

pub const LoadError = error{ OutOfMemory, ContentUnreadable };

/// Reads every `.md` file under `content_dir`. Each page's `site` is its slug until
/// pages.zig places it. Everything is allocated from `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, content_dir: []const u8) LoadError![]Page {
    var dir = std.Io.Dir.cwd().openDir(io, content_dir, .{ .iterate = true }) catch return error.ContentUnreadable;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();

    var pages: std.ArrayList(Page) = .empty;
    while (walker.next(io) catch return error.ContentUnreadable) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        const path = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const raw = entry.dir.readFileAlloc(io, entry.basename, arena, .limited(1 << 24)) catch
            return error.ContentUnreadable;
        const text = try std.mem.replaceOwned(u8, arena, raw, "\r\n", "\n");
        try pages.append(arena, parse(path[0 .. path.len - 3], text));
    }
    sort(pages.items);
    return pages.items;
}

/// A page from its text: the first line `# Title` is its title, and the rest its body.
pub fn parse(slug: []const u8, text: []const u8) Page {
    var page: Page = .{ .slug = slug, .title = slug, .nav_title = slug, .site = slug, .body = text };
    var rest = text;
    // a comment above the title (a generated page's note) stays in the body
    if (std.mem.startsWith(u8, rest, "# ")) {
        const end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        page.title = std.mem.trim(u8, rest[2..end], " ");
        page.nav_title = page.title;
        page.body = std.mem.trimStart(u8, rest[@min(end + 1, rest.len)..], "\n");
    }
    return page;
}
