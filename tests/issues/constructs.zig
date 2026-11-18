//! Upstream issues about construct names and statement labels.

const std = @import("std");
const h = @import("harness.zig");

const loops =
    \\subroutine s(a, n)
    \\  integer :: n, i, j
    \\  real :: a(n, n)
    \\  outer: do i = 1, n
    \\    inner: do j = 1, n
    \\      if (a(i, j) < 0) cycle outer
    \\      if (a(i, j) > 9) exit inner
    \\      check: if (a(i, j) == 0) then
    \\        exit outer
    \\      end if check
    \\    end do inner
    \\  end do outer
    \\end subroutine s
    \\
;

fn expectConstructNames(w: *h.Workspace) !void {
    const use = w.pos("s.f90", "cycle outer", 0, 6);
    const def = (try w.definition("s.f90", use)) orelse return h.unmet("no definition of outer", .{});
    try h.expect(def.line == 3 and def.col == 2, "definition of outer at {d}:{d}", .{ def.line, def.col });
    const refs = try w.references("s.f90", use);
    try h.expect(refs.len == 4, "{d} references to outer, not 4", .{refs.len});
    const edits = try w.rename("s.f90", w.pos("s.f90", "end do inner", 0, 8), "rows");
    try h.expect(edits.len == 3, "{d} edits renaming inner, not 3", .{edits.len});
    for (edits) |e| try h.expect(std.mem.eql(u8, e.new_text, "rows"), "edit to {s}", .{e.new_text});
}

test "#424 go to definition, references and rename of construct names" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = loops }}, .{});
    defer w.deinit();
    try h.check(424, .fixed, expectConstructNames(w));
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn expectCompletion(w: *h.Workspace) !void {
    // EXIT: any construct open there; CYCLE: only DO constructs
    const exits = try w.completion("s.f90", w.pos("s.f90", "exit outer", 0, 5));
    for ([_][]const u8{ "check", "inner", "outer" }) |n| try h.expect(contains(exits, n), "exit does not offer {s}", .{n});
    const cycles = try w.completion("s.f90", w.pos("s.f90", "cycle outer", 0, 6));
    try h.expect(contains(cycles, "outer") and contains(cycles, "inner"), "cycle does not offer the loops", .{});
    try h.expect(!contains(cycles, "check"), "cycle offers an IF construct", .{});
}

test "hansec #157 construct names are completed after EXIT and CYCLE" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = loops }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 157, .fixed, expectCompletion(w));
}

test "statement labels: definition and references" {
    const w = try h.Workspace.init(&.{.{ .name = "old.f", .text =
        \\      SUBROUTINE OLD(N)
        \\      INTEGER N, I
        \\      DO 10 I = 1, N
        \\        IF (I .GT. 5) GO TO 20
        \\        WRITE (6, 100) I
        \\   10 CONTINUE
        \\   20 RETURN
        \\  100 FORMAT (I5)
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    const def = (try w.definition("old.f", w.pos("old.f", "GO TO 20", 0, 6))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 6), def.line);
    const fmt = (try w.definition("old.f", w.pos("old.f", "(6, 100)", 0, 4))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 7), fmt.line);
    try std.testing.expectEqual(@as(usize, 2), (try w.references("old.f", w.pos("old.f", "DO 10", 0, 3))).len);
}

// Completion of constructs and program units (#264)

const starts = [_]h.File{
    .{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\contains
    \\  subr
    \\  subroutine s(n)
    \\    integer :: n, x
    \\    sel
    \\    if (n > 0) th
    \\    x = sel
    \\    do wh
    \\  end subroutine
    \\end module
    \\
    },
    .{ .name = "e.f90", .text = "module e\n" ++
        "contains\n" ++
        "  subroutine s(n)\n" ++
        "    integer :: n, i\n" ++
        "    do i = 1, n\n" ++
        "      print *, i\n" ++
        "    end \n" ++
        "  end subroutine s\n" ++
        "  subroutine s2(n)\n" ++
        "    integer :: n, i\n" ++
        "    do i = 1, n\n" ++
        "    end do\n" ++
        "    end \n" ++
        "end module e\n" },
};

const Snip = struct { label: []const u8, text: []const u8, kind: i64 };

/// The completion items at `needle` + `plus`: their labels, the text
/// they insert and their kinds
fn snipsAt(w: *h.Workspace, name: []const u8, needle: []const u8, nth: usize, plus: usize) ![]const Snip {
    const aa = w.arena.allocator();
    const p = w.pos(name, needle, nth, plus);
    const v = try w.server.dispatchPublic(aa, "textDocument/completion", try h.json.from(aa, .{
        .textDocument = .{ .uri = try w.uri(name) },
        .position = .{ .line = p.line, .character = p.col },
    }));
    var out: std.ArrayList(Snip) = .empty;
    for (h.json.items(v)) |item| {
        const edit = h.json.str(h.json.path(item, &.{ "textEdit", "newText" }));
        try out.append(aa, .{
            .label = h.json.str(h.json.get(item, "label")) orelse "",
            .text = edit orelse h.json.str(h.json.get(item, "insertText")) orelse "",
            .kind = h.json.int(h.json.get(item, "kind")) orelse 0,
        });
    }
    return out.items;
}

fn snip(items: []const Snip, label: []const u8) ?Snip {
    for (items) |i| if (std.mem.eql(u8, i.label, label)) return i;
    return null;
}

fn expectConstructs(w: *h.Workspace) !void {
    // a procedure after CONTAINS, with its end statement
    var items = try snipsAt(w, "m.f90", "subr\n", 0, 4);
    const sub = snip(items, "SUBROUTINE") orelse return h.unmet("subr: {any}", .{items});
    try h.expect(sub.kind == 15 and std.mem.find(u8, sub.text, "END SUBROUTINE ${1:name}") != null, "subr: {s}", .{sub.text});
    // a construct of more than one word
    items = try snipsAt(w, "m.f90", "do wh", 0, 5);
    const dow = snip(items, "DO WHILE") orelse return h.unmet("do wh: {any}", .{items});
    try h.expect(std.mem.startsWith(u8, dow.text, "DO WHILE ("), "do wh: {s}", .{dow.text});
    // before the intrinsics
    items = try snipsAt(w, "m.f90", "    sel", 0, 7);
    try h.expect(items.len > 2 and std.mem.eql(u8, items[0].label, "SELECT CASE") and std.mem.eql(u8, items[1].label, "SELECT TYPE"), "sel: {any}", .{items});
    // THEN after the condition
    items = try snipsAt(w, "m.f90", "if (n > 0) th", 0, 13);
    try h.expect(snip(items, "THEN") != null, "th: {any}", .{items});
    // not where an expression goes
    items = try snipsAt(w, "m.f90", "x = sel", 0, 7);
    try h.expect(snip(items, "SELECT CASE") == null, "x = sel: {any}", .{items});
    // after END, only the end statement of the open scope
    items = try snipsAt(w, "e.f90", "    end \n", 0, 8);
    try h.expect(items.len == 1 and std.mem.eql(u8, items[0].label, "END DO"), "end in the DO: {any}", .{items});
    items = try snipsAt(w, "e.f90", "    end \n", 1, 8);
    try h.expect(items.len == 1 and std.mem.eql(u8, items[0].label, "END SUBROUTINE s2"), "end after the DO: {any}", .{items});
}

test "#264 completion of constructs and program units, with their end statements" {
    const w = try h.Workspace.init(&starts, .{ .snippet_support = true });
    defer w.deinit();
    expectConstructs(w) catch |e| {
        std.debug.print("{s}\n", .{h.lastNote()});
        return e;
    };
}

test "#264 constructs in lowercase, and without snippets" {
    {
        const w = try h.Workspace.init(&starts, .{ .snippet_support = true, .settings = .{ .lowercase_intrinsics = true } });
        defer w.deinit();
        const items = try snipsAt(w, "m.f90", "subr\n", 0, 4);
        const sub = snip(items, "subroutine") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.find(u8, sub.text, "end subroutine ${1:name}") != null);
        const end = try snipsAt(w, "e.f90", "    end \n", 1, 8);
        try std.testing.expectEqualStrings("end subroutine s2", end[0].label);
    }
    inline for (.{ h.Options{}, h.Options{ .snippet_support = true, .settings = .{ .autocomplete_no_snippets = true } } }) |opts| {
        const w = try h.Workspace.init(&starts, opts);
        defer w.deinit();
        const items = try snipsAt(w, "m.f90", "do wh", 0, 5);
        const dow = snip(items, "DO WHILE") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("DO WHILE", dow.text);
        try std.testing.expectEqual(@as(i64, 14), dow.kind);
    }
}
