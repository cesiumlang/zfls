//! `zig build release-notes -- OUT`: the notes of the release of this
//! version (#979), written to OUT. The pull requests merged since the last
//! release's tag, and the issues of the version's milestone closed as done
//! that none of those pull requests closes (`Closes #N`, `Fixes #N`,
//! `Resolves #N`): a pull request stands for the issues it closes, and an
//! issue only mentioned by one, or closed without one, is listed itself.
//! Each in the first section of .github/release.yml its labels pick, the
//! labels it excludes left out, as is the `dev` to `main` pull request.
//! It asks GitHub through `gh` (`GH_TOKEN`), for `GITHUB_REPOSITORY` (by
//! default cesiumlang/zfls), and git for the tags.
//!
//! Usage: release_notes VERSION OUT

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const default_repo = "cesiumlang/zfls";

/// A pull request or an issue of the notes
const Entry = struct {
    number: u64,
    title: []const u8,
    labels: []const []const u8,
    /// a pull request's author, but a bot
    author: ?[]const u8 = null,
};

/// A section of .github/release.yml: its title and labels (`*`: any)
const Section = struct { title: []const u8, labels: []const []const u8 };

const Config = struct { exclude: []const []const u8, sections: []const Section };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 3) {
        std.log.err("usage: zig build release-notes -- OUT", .{});
        std.process.exit(2);
    }
    const version = argv[1];
    const repo = init.environ_map.get("GITHUB_REPOSITORY") orelse default_repo;
    const cwd = Io.Dir.cwd();
    const config = try parseConfig(a, try cwd.readFileAlloc(io, ".github/release.yml", a, .limited(1 << 20)));
    const tag = try a.print("v{s}", .{version});
    const previous = try previousTag(a, io, tag);

    // the pull requests merged since the last release
    var q: std.ArrayList(u8) = .empty;
    try q.print(a, "q=repo:{s} is:pr is:merged", .{repo});
    if (previous) |p| try q.print(a, " merged:>{s}", .{try tagDate(a, io, p)});
    const prs_out = try run(a, io, &.{ "gh", "api", "-X", "GET", "search/issues", "-f", q.items, "-f", "per_page=100", "--paginate", "--jq", ".items[] | [.number, .title, .user.login, .user.type, [.labels[].name], (.body // \"\")] | @json" });
    var entries: std.ArrayList(Entry) = .empty;
    var closed: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var lines = std.mem.tokenizeScalar(u8, prs_out, '\n');
    while (lines.next()) |line| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        const row = v.array.items;
        const number: u64 = @intCast(row[0].integer);
        const labels = try strings(a, row[4]);
        if (excluded(config, labels)) continue;
        // the release's own pull request
        const refs = try run(a, io, &.{ "gh", "api", try a.print("repos/{s}/pulls/{d}", .{ repo, number }), "--jq", ".head.ref + \" \" + .base.ref" });
        if (std.mem.eql(u8, std.mem.trim(u8, refs, " \r\n"), "dev main")) continue;
        for (try closedIssues(a, row[5].string, repo)) |n| try closed.put(a, n, {});
        const bot = std.mem.eql(u8, row[3].string, "Bot");
        try entries.append(a, .{ .number = number, .title = row[1].string, .labels = labels, .author = if (bot) null else row[2].string });
    }

    // the milestone's issues done that no pull request closes
    const milestones = try run(a, io, &.{ "gh", "api", try a.print("repos/{s}/milestones?state=all&per_page=100", .{repo}), "--paginate", "--jq", try a.print(".[] | select(.title == \"{s}\") | .number", .{tag}) });
    const milestone = std.mem.trim(u8, milestones, " \r\n");
    if (milestone.len > 0) {
        const issues_out = try run(a, io, &.{ "gh", "api", try a.print("repos/{s}/issues?milestone={s}&state=closed&per_page=100", .{ repo, milestone }), "--paginate", "--jq", ".[] | select(.pull_request == null and .state_reason == \"completed\") | [.number, .title, [.labels[].name]] | @json" });
        var it = std.mem.tokenizeScalar(u8, issues_out, '\n');
        while (it.next()) |line| {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
            const row = v.array.items;
            const number: u64 = @intCast(row[0].integer);
            const labels = try strings(a, row[2]);
            if (closed.contains(number) or excluded(config, labels)) continue;
            try entries.append(a, .{ .number = number, .title = row[1].string, .labels = labels });
        }
    } else std.log.warn("no milestone {s}: the pull requests alone", .{tag});

    const notes = try render(a, config, entries.items, repo, previous, tag);
    try cwd.writeFile(io, .{ .sub_path = argv[2], .data = notes });
}

/// The notes: a section per title with entries, by number, then the link
/// to the changes since the last release
fn render(a: Allocator, config: Config, entries: []Entry, repo: []const u8, previous: ?[]const u8, tag: []const u8) ![]const u8 {
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return x.number < y.number;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "## What's Changed\n");
    var placed = try a.alloc(bool, entries.len);
    @memset(placed, false);
    for (config.sections) |section| {
        var any = false;
        for (entries, 0..) |e, i| {
            if (placed[i] or !picks(section, e.labels)) continue;
            placed[i] = true;
            if (!any) try out.print(a, "\n### {s}\n\n", .{section.title});
            any = true;
            if (e.author) |who| try out.print(a, "* {s} by @{s} in #{d}\n", .{ e.title, who, e.number }) else try out.print(a, "* {s} (#{d})\n", .{ e.title, e.number });
        }
    }
    if (previous) |p| try out.print(a, "\n**Full Changelog**: https://github.com/{s}/compare/{s}...{s}\n", .{ repo, p, tag });
    return out.items;
}

fn picks(section: Section, labels: []const []const u8) bool {
    for (section.labels) |l| {
        if (std.mem.eql(u8, l, "*")) return true;
        for (labels) |have| if (std.mem.eql(u8, l, have)) return true;
    }
    return false;
}

fn excluded(config: Config, labels: []const []const u8) bool {
    for (config.exclude) |l| for (labels) |have| if (std.mem.eql(u8, l, have)) return true;
    return false;
}

/// The issues of this repository that a pull request's description closes:
/// `Closes #N`, `fixes owner/name#N`, `Resolves https://github.com/owner/name/issues/N`
fn closedIssues(a: Allocator, body: []const u8, repo: []const u8) ![]const u64 {
    var out: std.ArrayList(u64) = .empty;
    const lower = try std.ascii.allocLowerString(a, body);
    const keywords = [_][]const u8{ "closes", "closed", "close", "fixes", "fixed", "fix", "resolves", "resolved", "resolve" };
    var i: usize = 0;
    while (i < lower.len) : (i += 1) {
        if (i > 0 and (std.ascii.isAlphanumeric(lower[i - 1]) or lower[i - 1] == '_')) continue;
        const word = for (keywords) |k| {
            if (std.mem.startsWith(u8, lower[i..], k)) break k;
        } else continue;
        var j = i + word.len;
        if (j < lower.len and lower[j] == ':') j += 1;
        const blanks = j;
        while (j < lower.len and (lower[j] == ' ' or lower[j] == '\t')) j += 1;
        if (j == blanks and !(j < lower.len and lower[j] == '#')) continue;
        if (issueRef(lower[j..], repo)) |n| try out.append(a, n);
    }
    return out.items;
}

/// The issue number a reference starts `text` with, for `repo`
fn issueRef(text: []const u8, repo: []const u8) ?u64 {
    var lower_buf: [128]u8 = undefined;
    const r = std.ascii.lowerString(lower_buf[0..@min(repo.len, lower_buf.len)], repo[0..@min(repo.len, lower_buf.len)]);
    var t = text;
    const url = "https://github.com/";
    if (std.mem.startsWith(u8, t, url)) {
        t = t[url.len..];
        if (!std.mem.startsWith(u8, t, r)) return null;
        t = t[r.len..];
        if (!std.mem.startsWith(u8, t, "/issues/") and !std.mem.startsWith(u8, t, "/pull/")) return null;
        t = t[std.mem.findScalarPos(u8, t, 1, '/').? + 1 ..];
    } else if (std.mem.startsWith(u8, t, r) and r.len < t.len and t[r.len] == '#') {
        t = t[r.len + 1 ..];
    } else if (t.len > 0 and t[0] == '#') {
        t = t[1..];
    } else return null;
    const end = std.mem.findNone(u8, t, "0123456789") orelse t.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, t[0..end], 10) catch null;
}

/// The sections and excluded labels of .github/release.yml (its own
/// shape: `exclude: labels:` and `categories:`, each `- title:` with its
/// `labels:` list)
fn parseConfig(a: Allocator, text: []const u8) !Config {
    var exclude: std.ArrayList([]const u8) = .empty;
    var sections: std.ArrayList(Section) = .empty;
    var labels: std.ArrayList([]const u8) = .empty;
    var title: ?[]const u8 = null;
    var in_exclude = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "exclude:")) {
            in_exclude = true;
        } else if (std.mem.eql(u8, line, "categories:")) {
            in_exclude = false;
        } else if (std.mem.startsWith(u8, line, "- title:")) {
            if (title) |t| try sections.append(a, .{ .title = t, .labels = try labels.toOwnedSlice(a) });
            title = unquote(std.mem.trim(u8, line["- title:".len..], " "));
        } else if (std.mem.startsWith(u8, line, "- ")) {
            const label = unquote(std.mem.trim(u8, line[2..], " "));
            if (in_exclude) try exclude.append(a, label) else if (title != null) try labels.append(a, label);
        }
    }
    if (title) |t| try sections.append(a, .{ .title = t, .labels = try labels.toOwnedSlice(a) });
    return .{ .exclude = exclude.items, .sections = sections.items };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

fn strings(a: Allocator, v: std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |x| try out.append(a, x.string);
    return out.items;
}

/// The last release's tag before `tag`, among those of `HEAD`'s history
fn previousTag(a: Allocator, io: Io, tag: []const u8) !?[]const u8 {
    const out = try run(a, io, &.{ "git", "tag", "--list", "v*", "--sort=-v:refname", "--merged", "HEAD" });
    var it = std.mem.tokenizeAny(u8, out, "\r\n");
    while (it.next()) |t| if (!std.mem.eql(u8, t, tag)) return t;
    return null;
}

/// When `tag`'s commit was made (ISO 8601)
fn tagDate(a: Allocator, io: Io, tag: []const u8) ![]const u8 {
    return std.mem.trim(u8, try run(a, io, &.{ "git", "log", "-1", "--format=%cI", tag }), " \r\n");
}

fn run(a: Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    const r = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 26) });
    if (r.term != .exited or r.term.exited != 0) {
        std.log.err("{s} failed: {s}", .{ argv[0], r.stderr });
        return error.CommandFailed;
    }
    return r.stdout;
}

const testing = std.testing;

test "the issues a pull request closes, not those it mentions (#979)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try closedIssues(arena.allocator(), "Closes #12, fixes: #13.\nSee #14; resolves cesiumlang/zfls#15, fixed https://github.com/cesiumlang/zfls/issues/16 and #19. Prefix#17, closes other/repo#18", "cesiumlang/zfls");
    try testing.expectEqualSlices(u64, &.{ 12, 13, 15, 16 }, got);
}

test "release.yml's sections and excluded labels (#979)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parseConfig(arena.allocator(),
        \\changelog:
        \\  exclude:
        \\    labels:
        \\      - skip-changelog
        \\  categories:
        \\    - title: Fixes
        \\      labels:
        \\        - fix
        \\        - bug
        \\    - title: Other changes
        \\      labels:
        \\        - "*"
        \\
    );
    try testing.expectEqual(@as(usize, 1), c.exclude.len);
    try testing.expectEqual(@as(usize, 2), c.sections.len);
    try testing.expectEqualStrings("bug", c.sections[0].labels[1]);
    try testing.expectEqualStrings("*", c.sections[1].labels[0]);
}

test "the notes: sections by labels, entries by number (#979)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config: Config = .{ .exclude = &.{}, .sections = &.{ .{ .title = "Fixes", .labels = &.{"fix"} }, .{ .title = "Other changes", .labels = &.{"*"} } } };
    var entries = [_]Entry{
        .{ .number = 9, .title = "A crash", .labels = &.{"fix"} },
        .{ .number = 4, .title = "Hover", .labels = &.{"fix"}, .author = "someone" },
        .{ .number = 7, .title = "Docs", .labels = &.{} },
    };
    try testing.expectEqualStrings(
        "## What's Changed\n\n### Fixes\n\n* Hover by @someone in #4\n* A crash (#9)\n\n### Other changes\n\n* Docs (#7)\n\n**Full Changelog**: https://github.com/o/r/compare/v1.0.0...v1.0.1\n",
        try render(a, config, &entries, "o/r", "v1.0.0", "v1.0.1"),
    );
}
