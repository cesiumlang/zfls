//! The links of a page to other pages of the site: Markdown links to
//! relative `.md` files, as `[words](../reference/types.md#pointers)`.

const std = @import("std");
const content = @import("content.zig");

const Page = content.Page;

pub const Link = struct {
    /// The page it points at; null when the file is not a page of the site.
    page: ?Page,
    /// What follows the `#`, if anything.
    anchor: ?[]const u8,
    /// The index in the text just after the closing parenthesis.
    end: usize,
};

/// The link that stands at `text[i..]`, which begins with `](`; null when
/// it is not a link to a `.md` file (a web address, an anchor, another kind
/// of file).
pub fn at(pages: []const Page, from: Page, text: []const u8, i: usize) ?Link {
    if (!std.mem.startsWith(u8, text[i..], "](")) return null;
    const close = std.mem.findScalar(u8, text[i + 2 ..], ')') orelse return null;
    const target = text[i + 2 .. i + 2 + close];
    const hash = std.mem.findScalar(u8, target, '#');
    const path = if (hash) |h| target[0..h] else target;
    if (!std.mem.endsWith(u8, path, ".md") or path[0] == '/' or std.mem.find(u8, path, "://") != null) return null;
    return .{
        .page = resolve(pages, from, path[0 .. path.len - 3]),
        .anchor = if (hash) |h| target[h + 1 ..] else null,
        .end = i + 2 + close + 1,
    };
}

/// The page that `path`, without its extension and relative to the
/// directory of `from`, names.
pub fn resolve(pages: []const Page, from: Page, path: []const u8) ?Page {
    var parts: [32][]const u8 = undefined;
    var n: usize = 0;
    var base = std.mem.tokenizeScalar(u8, from.dir(), '/');
    while (base.next()) |segment| {
        if (n == parts.len) return null;
        parts[n] = segment;
        n += 1;
    }
    var rest = std.mem.tokenizeScalar(u8, path, '/');
    while (rest.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (n == 0) return null;
            n -= 1;
            continue;
        }
        if (n == parts.len) return null;
        parts[n] = segment;
        n += 1;
    }
    for (pages) |page| {
        if (matches(page.slug, parts[0..n])) return page;
    }
    return null;
}

// whether `slug` is the segments joined by slashes
fn matches(slug: []const u8, segments: []const []const u8) bool {
    var rest = slug;
    for (segments, 0..) |segment, i| {
        if (!std.mem.startsWith(u8, rest, segment)) return false;
        rest = rest[segment.len..];
        if (i + 1 < segments.len) {
            if (rest.len == 0 or rest[0] != '/') return false;
            rest = rest[1..];
        }
    }
    return rest.len == 0;
}
