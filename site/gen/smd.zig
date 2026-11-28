//! A page as Zine reads it (SuperMD): Ziggy front matter, headings with
//! explicit ids, callouts as blocks, links as `$link.page`, and every code
//! block and HTML block (the screenshots' `<picture>`) as finished HTML.
//! From skein's site/gen/smd.zig (chasingdaylight/skein@1e2695e), itself
//! from cesiumlang.org's tools/zine/smd.zig (cesiumlang/cesiumlang.org@c657aa2),
//! without skein's item anchors.

const std = @import("std");
const content = @import("content.zig");
const fence = @import("fence.zig");
const plain = @import("plain.zig");
const portable = @import("portable.zig");

const Page = content.Page;

pub const Heading = struct {
    depth: u8,
    text: []const u8,
    id: []const u8,
};

pub const Rendered = struct {
    text: []const u8,
    headings: []const Heading,
};

pub const Error = error{OutOfMemory};

/// `date` is `YYYY-MM-DDTHH:MM:SS`; `version` names the release the page is
/// of, for the footer. Allocated from `arena`.
pub fn render(
    arena: std.mem.Allocator,
    pages: []const Page,
    page: Page,
    date: []const u8,
    version: ?[]const u8,
    report: *portable.Report,
) Error!Rendered {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try frontMatter(w, page, date, version);

    var headings: std.ArrayList(Heading) = .empty;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var code: std.ArrayList(u8) = .empty;
    var html: std.ArrayList(u8) = .empty;
    var lang: []const u8 = "";
    var state: fence.Fence = .{};
    // what stands before a fence or an HTML block: `> ` or a list's indent
    var lead: []const u8 = "";

    var lines = std.mem.splitScalar(u8, page.body, '\n');
    while (lines.next()) |line| {
        const quote = portable.quotePrefix(line);
        const after = line[quote.len..];
        const indent = after.len - std.mem.trimStart(u8, after, " ").len;
        const text = after[indent..];
        if (html.items.len > 0) {
            if (std.mem.trim(u8, line, " ").len > 0) {
                try html.appendSlice(arena, line[@min(lead.len, line.len)..]);
                try html.append(arena, '\n');
                continue;
            }
            try htmlBlock(arena, w, page, lead, html.items);
            html.clearRetainingCapacity();
        }
        switch (state.step(text)) {
            .open => {
                lead = line[0 .. quote.len + indent];
                var info = std.mem.trim(u8, text, "`~ ");
                if (std.mem.findScalar(u8, info, ' ')) |space| info = info[0..space];
                lang = info;
                code.clearRetainingCapacity();
                continue;
            },
            .inside => {
                try code.appendSlice(arena, line[@min(lead.len, leadOf(line, lead.len))..]);
                try code.append(arena, '\n');
                continue;
            },
            .close => {
                var block: std.Io.Writer.Allocating = .init(arena);
                try codeBlock(&block.writer, lang, std.mem.trimEnd(u8, code.items, "\n"));
                try rawHtml(arena, w, lead, block.written());
                continue;
            },
            .outside => {},
        }
        if (startsHtml(text) and indent < 4) {
            lead = line[0 .. quote.len + indent];
            try html.appendSlice(arena, line[lead.len..]);
            try html.append(arena, '\n');
            continue;
        }
        if (quote.len == 0 and headingLevel(line) != null) {
            const level = headingLevel(line).?;
            const words_md = std.mem.trim(u8, line[level..], " ");
            const words = try plain.text(arena, words_md);
            const id = try uniqueId(arena, &ids, words);
            try headings.append(arena, .{ .depth = @intCast(level), .text = words, .id = id });
            try put(w, line[0..level]);
            try put(w, " [");
            try portable.writeInline(w, pages, page, words_md, true, report);
            try put(w, "]($section.id('");
            try put(w, id);
            try put(w, "'))\n");
            continue;
        }
        if (portable.parseCallout(line)) |callout| {
            // a block's class is one word; the label is the kind, capitalized
            const kind = try std.ascii.allocLowerString(arena, callout.kind);
            try put(w, "># [");
            if (kind.len > 0) {
                w.writeByte(std.ascii.toUpper(kind[0])) catch return error.OutOfMemory;
                try put(w, kind[1..]);
            }
            if (callout.title.len > 0) {
                try put(w, ": ");
                try put(w, callout.title);
            }
            try put(w, "]($block.attrs('callout-");
            try put(w, kind);
            try put(w, "'))\n");
            continue;
        }
        try portable.writeInline(w, pages, page, line, true, report);
        try put(w, "\n");
    }
    if (html.items.len > 0) try htmlBlock(arena, w, page, lead, html.items);
    return .{ .text = out.written(), .headings = headings.items };
}

// how much of `line` is the fence's lead: its quote marks and up to its indent
fn leadOf(line: []const u8, most: usize) usize {
    var n: usize = 0;
    while (n < most and n < line.len and (line[n] == ' ' or line[n] == '>')) n += 1;
    return n;
}

// each line of `block` after `lead`, as the fence or HTML stood
fn indented(w: *std.Io.Writer, lead: []const u8, block: []const u8) Error!void {
    var block_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block, "\n"), '\n');
    while (block_lines.next()) |block_line| {
        try put(w, lead);
        try put(w, block_line);
        try put(w, "\n");
    }
}

/// Whether a line opens an HTML block: a tag, `<picture>` or `</div>`, but
/// not an autolink (`<https://...>`).
pub fn startsHtml(text: []const u8) bool {
    if (text.len < 2 or text[0] != '<') return false;
    var n: usize = 1;
    if (text[n] == '/') n += 1;
    const name_start = n;
    while (n < text.len and std.ascii.isAlphanumeric(text[n])) n += 1;
    if (n == name_start or !std.ascii.isAlphabetic(text[name_start])) return false;
    return n == text.len or text[n] == ' ' or text[n] == '>' or std.mem.startsWith(u8, text[n..], "/>");
}

// an HTML block as it is, with its images' relative paths made absolute: the
// page is at another place on the site than in docs/
fn htmlBlock(arena: std.mem.Allocator, w: *std.Io.Writer, page: Page, lead: []const u8, block: []const u8) Error!void {
    var fixed: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < block.len) {
        const attr = nextAttr(block, i) orelse {
            try fixed.appendSlice(arena, block[i..]);
            break;
        };
        try fixed.appendSlice(arena, block[i..attr.value_start]);
        const value = block[attr.value_start..attr.value_end];
        if (portable.relative(value)) {
            try fixed.append(arena, '/');
            try fixed.appendSlice(arena, try portable.join(arena, page.dir(), value));
        } else try fixed.appendSlice(arena, value);
        i = attr.value_end;
    }
    try rawHtml(arena, w, lead, fixed.items);
}

// HTML as SuperMD takes it: in a `=html` fence longer than any run of
// backquotes inside, so that code showing a fence does not close it
fn rawHtml(arena: std.mem.Allocator, w: *std.Io.Writer, lead: []const u8, html: []const u8) Error!void {
    var longest: usize = 0;
    var run: usize = 0;
    for (html) |c| {
        run = if (c == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    const marks = try arena.alloc(u8, @max(3, longest + 1));
    @memset(marks, '`');
    var block: std.Io.Writer.Allocating = .init(arena);
    try put(&block.writer, marks);
    try put(&block.writer, "=html\n");
    try put(&block.writer, std.mem.trimEnd(u8, html, "\n"));
    try put(&block.writer, "\n");
    try put(&block.writer, marks);
    try put(&block.writer, "\n");
    try indented(w, lead, block.written());
}

const Attr = struct { value_start: usize, value_end: usize };

fn nextAttr(block: []const u8, from: usize) ?Attr {
    var best: ?Attr = null;
    for ([_][]const u8{ " src=\"", " srcset=\"", " href=\"" }) |name| {
        const at = std.mem.findPos(u8, block, from, name) orelse continue;
        const start = at + name.len;
        const end = std.mem.findScalarPos(u8, block, start, '"') orelse continue;
        if (best == null or start < best.?.value_start) best = .{ .value_start = start, .value_end = end };
    }
    return best;
}

fn put(w: *std.Io.Writer, text: []const u8) Error!void {
    w.writeAll(text) catch return error.OutOfMemory;
}

/// The depth of an ATX heading line, or null.
pub fn headingLevel(line: []const u8) ?usize {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6 or n >= line.len or line[n] != ' ') return null;
    return n;
}

// the GitHub id of a heading, made unique within the page
fn uniqueId(arena: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), words: []const u8) Error![]const u8 {
    var buffer: std.Io.Writer.Allocating = .init(arena);
    try portable.writeAnchor(&buffer.writer, words);
    var id: []const u8 = buffer.written();
    if (id.len == 0) id = "section";
    var n: usize = 0;
    while (ids.contains(id)) {
        n += 1;
        id = try arena.print("{s}-{d}", .{ buffer.written(), n });
    }
    try ids.put(arena, id, {});
    return id;
}

fn frontMatter(w: *std.Io.Writer, page: Page, date: []const u8, version: ?[]const u8) Error!void {
    try put(w, "---\n.title = ");
    try ziggyString(w, page.title);
    try put(w, ",\n");
    if (page.description) |description| {
        try put(w, ".description = ");
        try ziggyString(w, description);
        try put(w, ",\n");
    }
    try put(w, ".date = .date(\"");
    try put(w, date);
    try put(w, "\"),\n.layout = \"page.shtml\",\n");
    // the page as Markdown, copied beside the site at its place in docs/
    try put(w, ".custom = { \"markdown\": \"/");
    try put(w, page.slug);
    try put(w, ".md\"");
    if (version) |v| {
        try put(w, ", \"version\": ");
        try ziggyString(w, v);
    }
    // the title of the browser's tab: the page's, then the site's; the home
    // page is the site's alone, and an edition's names its release
    try put(w, ", \"head_title\": \"");
    if (std.mem.eql(u8, page.site, "index")) {
        try ziggyText(w, "zfls");
    } else {
        try ziggyText(w, page.title);
        try ziggyText(w, " · zfls");
        if (page.edition()) |release| {
            try ziggyText(w, " ");
            try ziggyText(w, release);
        }
    }
    try put(w, "\" },\n");
    try put(w, "---\n");
}

pub fn ziggyString(w: *std.Io.Writer, text: []const u8) Error!void {
    try put(w, "\"");
    try ziggyText(w, text);
    try put(w, "\"");
}

/// The inside of a Ziggy string: `text` escaped.
pub fn ziggyText(w: *std.Io.Writer, text: []const u8) Error!void {
    for (text) |c| {
        switch (c) {
            '"' => try put(w, "\\\""),
            '\\' => try put(w, "\\\\"),
            '\n' => try put(w, "\\n"),
            else => w.writeByte(c) catch return error.OutOfMemory,
        }
    }
}

// a block of code as HTML
fn codeBlock(w: *std.Io.Writer, lang: []const u8, code: []const u8) Error!void {
    try put(w, "<pre class=\"highlight\"><code class=\"language-");
    try put(w, if (lang.len > 0) lang else "text");
    try put(w, "\">");
    try escaped(w, code);
    try put(w, "</code></pre>\n");
}

pub fn escaped(w: *std.Io.Writer, text: []const u8) Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try put(w, "&amp;"),
            '<' => try put(w, "&lt;"),
            '>' => try put(w, "&gt;"),
            else => w.writeByte(c) catch return error.OutOfMemory,
        }
    }
}
