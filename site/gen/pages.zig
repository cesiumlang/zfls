//! The tree of pages (pages.txt): each page's place on the site, its order
//! and its title in the tree, and a front page for each group. From skein's
//! site/gen/pages.zig (chasingdaylight/skein@1e2695e).

const std = @import("std");
const content = @import("content.zig");
const plain = @import("plain.zig");

const Page = content.Page;

pub const Group = struct {
    /// Its directory on the site: `guides`.
    dir: []const u8,
    title: []const u8,
    /// The pages, by their path under docs/: `quickstart`, `requirements/items`.
    pages: []const Entry,
};

pub const Entry = struct { path: []const u8, title: []const u8 };

pub const ParseError = error{ OutOfMemory, PageOutsideGroup, EntryWithoutTitle };

/// pages.txt: `DIR TITLE` at the left starts a group, `  PATH TITLE`
/// indented is a page of it; `#` starts a comment line. Allocated from `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError![]const Group {
    var groups: std.ArrayList(Group) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const space = std.mem.findScalar(u8, trimmed, ' ') orelse return error.EntryWithoutTitle;
        const name = trimmed[0..space];
        const title = std.mem.trim(u8, trimmed[space..], " ");
        if (line.len == trimmed.len) {
            if (groups.items.len > 0) groups.items[groups.items.len - 1].pages = try entries.toOwnedSlice(arena);
            try groups.append(arena, .{ .dir = name, .title = title, .pages = &.{} });
        } else {
            if (groups.items.len == 0) return error.PageOutsideGroup;
            try entries.append(arena, .{ .path = name, .title = title });
        }
    }
    if (groups.items.len > 0) groups.items[groups.items.len - 1].pages = try entries.toOwnedSlice(arena);
    return groups.items;
}

/// Places each page on the site by `groups` and orders them; adds a front
/// page for each group, in each edition that has a page of it. A page not
/// listed stays where it is under docs/, at the end, with a warning.
/// Returns the pages with the groups' front pages. Allocated from `arena`.
pub fn place(arena: std.mem.Allocator, groups: []const Group, pages: []Page) error{OutOfMemory}![]Page {
    var all: std.ArrayList(Page) = .empty;
    var order: i64 = 0;
    // the order of the groups and pages, the same in every edition
    var orders: std.StringHashMapUnmanaged(i64) = .empty;
    for (groups) |group| {
        order += 1;
        for (group.pages) |entry| {
            order += 1;
            try orders.put(arena, entry.path, order);
        }
    }
    for (pages) |*page| {
        const within = page.withinEdition();
        const prefix = editionPrefix(page.*);
        const source = try indexed(arena, within);
        page.site = try arena.print("{s}{s}", .{ prefix, source });
        if (find(groups, within)) |found| {
            page.site = try arena.print("{s}{s}/{s}", .{ prefix, found.group.dir, source });
            page.nav_title = found.entry.title;
            page.sortorder = orders.get(within).?;
        } else if (!std.mem.eql(u8, within, "index")) {
            std.debug.print("warning: {s}: not in pages.txt\n", .{page.slug});
        }
        try all.append(arena, page.*);
    }
    try addFronts(arena, groups, &all);
    content.sort(all.items);
    return all.items;
}

const Found = struct { group: Group, entry: Entry };

fn find(groups: []const Group, path: []const u8) ?Found {
    for (groups) |group| {
        for (group.pages) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return .{ .group = group, .entry = entry };
        }
    }
    return null;
}

// `requirements/readme` as `requirements/index`: a directory's front page
fn indexed(arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const slash = std.mem.findScalarLast(u8, path, '/');
    const name = if (slash) |s| path[s + 1 ..] else path;
    if (!content.isIndexName(name) or std.mem.eql(u8, name, "index")) return path;
    if (slash) |s| return arena.print("{s}/index", .{path[0..s]});
    return "index";
}

fn editionPrefix(page: Page) []const u8 {
    const release = page.edition() orelse return "";
    return page.slug[0 .. release.len + 2];
}

// a front page per group and edition: the group's title and its pages,
// those at the top of docs/ and the front pages of directories
fn addFronts(arena: std.mem.Allocator, groups: []const Group, all: *std.ArrayList(Page)) error{OutOfMemory}!void {
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (all.items) |page| {
        const prefix = editionPrefix(page);
        for (prefixes.items) |known| {
            if (std.mem.eql(u8, known, prefix)) break;
        } else try prefixes.append(arena, prefix);
    }
    const listed = all.items.len;
    for (prefixes.items) |prefix| {
        var order: i64 = 0;
        for (groups) |group| {
            order += 1;
            var body: std.ArrayList(u8) = .empty;
            for (group.pages) |entry| {
                order += 1;
                const slash = std.mem.findScalar(u8, entry.path, '/');
                if (slash != null and !content.isIndexName(entry.path[slash.? + 1 ..])) continue;
                const page = pageAt(all.items[0..listed], prefix, entry.path) orelse continue;
                try body.print(arena, "- [{s}](../{s}.md)", .{ entry.title, entry.path });
                const words = try describe(arena, page);
                if (words.len > 0) try body.print(arena, ": {s}", .{words});
                try body.append(arena, '\n');
            }
            if (body.items.len == 0) continue;
            const slug = try arena.print("{s}{s}/index", .{ prefix, group.dir });
            try all.append(arena, .{
                .slug = slug,
                .title = group.title,
                .nav_title = group.title,
                .sortorder = order - @as(i64, @intCast(group.pages.len)),
                .site = slug,
                .body = body.items,
            });
        }
    }
}

fn pageAt(pages: []const Page, prefix: []const u8, path: []const u8) ?Page {
    for (pages) |page| {
        if (std.mem.startsWith(u8, page.slug, prefix) and std.mem.eql(u8, page.slug[prefix.len..], path)) return page;
    }
    return null;
}

/// The first sentence of the page's first paragraph, as plain text. Allocated from `arena`.
pub fn describe(arena: std.mem.Allocator, page: Page) error{OutOfMemory}![]const u8 {
    if (page.description) |d| return d;
    var paragraph: std.ArrayList(u8) = .empty;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, page.body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "```")) in_fence = !in_fence;
        const prose = !in_fence and trimmed.len > 0 and std.mem.findScalar(u8, "#>|-*`<%", trimmed[0]) == null and
            !std.ascii.isDigit(trimmed[0]);
        if (!prose) {
            if (paragraph.items.len > 0) break;
            continue;
        }
        if (paragraph.items.len > 0) try paragraph.append(arena, ' ');
        try paragraph.appendSlice(arena, trimmed);
    }
    const words = try plain.text(arena, paragraph.items);
    const end = if (std.mem.find(u8, words, ". ")) |dot| dot + 1 else words.len;
    return if (end > 240) words[0..240] else words[0..end];
}
