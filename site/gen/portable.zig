//! The links of a page as Zine wants them, the ids of headings and
//! callouts. From skein's site/gen (chasingdaylight/skein@1e2695e), itself
//! from cesiumlang.org's tools/ai/portable.zig
//! (cesiumlang/cesiumlang.org@c657aa2), the parts the site uses; a page's
//! place on the site is `Page.site`, not its path under docs/.

const std = @import("std");
const content = @import("content.zig");
const fence = @import("fence.zig");
const links = @import("links.zig");

const Page = content.Page;

/// What was found that does not resolve, and optionally where the page links.
pub const Report = struct {
    /// Links to a `.md` file that is not a page of the site.
    unresolved: usize = 0,
    /// If set, the site path of every page linked is added (once).
    targets: ?*std.ArrayList([]const u8) = null,
    /// For the lists.
    arena: ?std.mem.Allocator = null,
    /// The files that are not pages linked from pages (images), by their
    /// path in the content; needs `arena`.
    files: std.ArrayList([]const u8) = .empty,
};

/// The site paths of the pages that `page` links to, each once. Allocated
/// from `arena`.
pub fn linkTargets(arena: std.mem.Allocator, pages: []const Page, page: Page) error{OutOfMemory}![]const []const u8 {
    var targets: std.ArrayList([]const u8) = .empty;
    var report: Report = .{ .targets = &targets, .arena = arena };
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var code: fence.Fence = .{};
    var lines = std.mem.splitScalar(u8, page.body, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trimStart(u8, line[quotePrefix(line).len..], " ");
        if (code.step(text) == .outside) try writeInline(&sink.writer, pages, page, line, false, &report);
    }
    return targets.items;
}

/// The `> ` marks at the start of a line of a block quote.
pub fn quotePrefix(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == '>' or (line[n] == ' ' and n > 0 and line[n - 1] == '>'))) n += 1;
    return line[0..n];
}

fn put(w: *std.Io.Writer, text: []const u8) error{OutOfMemory}!void {
    w.writeAll(text) catch return error.OutOfMemory;
}

/// A callout opening, `> [!warning]- Draft`: its kind and title (empty if none).
pub const Callout = struct { kind: []const u8, title: []const u8 };

/// The callout a line opens, or null.
pub fn parseCallout(line: []const u8) ?Callout {
    const marker = "> [!";
    if (!std.mem.startsWith(u8, line, marker)) return null;
    const close = std.mem.findScalar(u8, line, ']') orelse return null;
    const rest = std.mem.trimStart(u8, line[close + 1 ..], "+- ");
    return .{ .kind = line[marker.len..close], .title = std.mem.trim(u8, rest, " ") };
}

/// `text` as it is, but with the links to other pages written as Zine wants
/// them (`[words]($link.page('dir/page').ref('heading'))`) when `for_zine`.
/// The links found are counted and listed in `report`; code spans are left alone.
pub fn writeInline(w: *std.Io.Writer, pages: []const Page, page: Page, text: []const u8, for_zine: bool, report: *Report) error{OutOfMemory}!void {
    var in_code = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') in_code = !in_code;
        if (!in_code and c == ']') {
            if (links.at(pages, page, text, i)) |link| {
                if (link.page) |target| {
                    try note(report, target);
                    if (for_zine) {
                        try writeZineTarget(w, target, link.anchor, page.edition() == null);
                        i = link.end;
                        continue;
                    }
                } else {
                    report.unresolved += 1;
                    std.debug.print("warning: {s}: no page for {s}\n", .{ page.slug, text[i..link.end] });
                }
            } else if (for_zine) {
                if (try fileLink(w, page, text, i, report)) |end| {
                    i = end;
                    continue;
                }
            }
        }
        w.writeByte(c) catch return error.OutOfMemory;
        i += 1;
    }
}

fn note(report: *Report, target: Page) error{OutOfMemory}!void {
    const list = report.targets orelse return;
    const slug = siteSlug(target);
    for (list.items) |known| {
        if (std.mem.eql(u8, known, slug)) return;
    }
    try list.append(report.arena.?, slug);
}

// A link to a file that is not a page, `[figure](img/stack.png)`:
// SuperMD links to it as a site asset, which the generator copies into
// assets/ (Zine writes it at the same path). Returns where the link ends.
fn fileLink(w: *std.Io.Writer, page: Page, text: []const u8, i: usize, report: *Report) error{OutOfMemory}!?usize {
    if (!std.mem.startsWith(u8, text[i..], "](")) return null;
    const arena = report.arena orelse return null;
    const close = std.mem.findScalar(u8, text[i + 2 ..], ')') orelse return null;
    const target = text[i + 2 .. i + 2 + close];
    if (!relative(target) or std.mem.findAny(u8, target, "#? ") != null) return null;
    const path = try join(arena, page.dir(), target);
    try report.files.append(arena, path);
    try put(w, "]($link.siteAsset('");
    try put(w, path);
    try put(w, "'))");
    return i + 2 + close + 1;
}

/// Whether a link or a file's address is relative to the page.
pub fn relative(value: []const u8) bool {
    if (value.len == 0 or value[0] == '/' or value[0] == '#' or value[0] == '$') return false;
    return std.mem.find(u8, value, "://") == null and !std.mem.startsWith(u8, value, "data:") and
        !std.mem.startsWith(u8, value, "mailto:");
}

/// `path` relative to the directory `dir`, with `.` and `..` resolved.
pub fn join(arena: std.mem.Allocator, dir: []const u8, path: []const u8) error{OutOfMemory}![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var base = std.mem.tokenizeScalar(u8, dir, '/');
    while (base.next()) |segment| try parts.append(arena, segment);
    var rest = std.mem.tokenizeScalar(u8, path, '/');
    while (rest.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, segment);
    }
    return std.mem.join(arena, "/", parts.items);
}

fn writeZineTarget(w: *std.Io.Writer, target: Page, anchor: ?[]const u8, checked: bool) error{OutOfMemory}!void {
    const slug = siteSlug(target);
    // the home page: SuperMD takes no empty path, but `/` is the site's root
    if (slug.len == 0) {
        try put(w, "](/");
        if (anchor) |id| {
            try put(w, "#");
            try put(w, id);
        }
        try put(w, ")");
        return;
    }
    try put(w, "]($link.page('");
    try put(w, slug);
    try put(w, "')");
    // `.ref` deep-links to the anchor, which Zine checks; `.id` would name
    // the link itself. An earlier release's pages are as they were, broken
    // anchors and all: `.unsafeRef` does not check.
    if (anchor) |id| {
        try put(w, if (checked) ".ref('" else ".unsafeRef('");
        try put(w, id);
        try put(w, "')");
    }
    try put(w, ")");
}

/// The path of the page on the site: an index page is its directory.
pub fn siteSlug(page: Page) []const u8 {
    const site = page.site;
    if (std.mem.eql(u8, site, "index")) return "";
    if (std.mem.endsWith(u8, site, "/index")) return site[0 .. site.len - "/index".len];
    return site;
}

/// The id a heading gets on GitHub: lower case, spaces to hyphens, punctuation dropped.
pub fn writeAnchor(w: *std.Io.Writer, heading: []const u8) error{OutOfMemory}!void {
    for (heading) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            w.writeByte(std.ascii.toLower(c)) catch return error.OutOfMemory;
        } else if (c == ' ') {
            w.writeByte('-') catch return error.OutOfMemory;
        }
    }
}
