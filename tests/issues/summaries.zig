//! The files that are not open are kept as summaries (#219): every request
//! answers as it does when they are kept in full.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");
const json = zfls.json;

const files = [_]h.File{
    .{ .name = "lib.f90", .text =
    \\module lib
    \\  implicit none
    \\  integer :: counter = 0
    \\  type :: point
    \\    real :: x, y
    \\  contains
    \\    procedure :: norm => point_norm
    \\  end type
    \\contains
    \\  !> Adds n to the counter
    \\  subroutine bump(n)
    \\    integer, intent(in) :: n
    \\    integer :: i, before
    \\    before = counter
    \\    do i = 1, n
    \\      counter = counter + 1
    \\    end do
    \\    block
    \\      integer :: counter
    \\      counter = before
    \\    end block
    \\  end subroutine bump
    \\  real function point_norm(self)
    \\    class(point), intent(in) :: self
    \\    real :: s
    \\    s = self%x**2 + self%y**2
    \\    point_norm = sqrt(s)
    \\    call bump(1)
    \\  end function
    \\end module lib
    \\
    },
    .{ .name = "app.f90", .text =
    \\program app
    \\  use lib, only: bump, counter, point
    \\  type(point) :: p
    \\  call bump(3)
    \\  print *, counter, p%norm()
    \\end program app
    \\
    },
    .{ .name = "report.f90", .text =
    \\subroutine report()
    \\  use lib, only: total => counter, bump
    \\  integer :: k
    \\  do k = 1, 2
    \\    call bump(k)
    \\  end do
    \\  print *, total
    \\end subroutine report
    \\
    },
};

/// Whether the AST zfls has of `name` is a summary
fn isSummary(w: *h.Workspace, name: []const u8) !bool {
    const f = w.server.workspace.get(try w.path(name)) orelse return error.FileNotInWorkspace;
    return f.ast.?.summary != null;
}

/// The answers to a session of requests, with the workspace's URI left out
fn session(w: *h.Workspace) ![]const u8 {
    const a = w.arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    const Req = struct { method: []const u8, file: []const u8, at: ?[]const u8 = null, plus: usize = 0, extra: ?[]const u8 = null };
    const reqs = [_]Req{
        .{ .method = "textDocument/hover", .file = "app.f90", .at = "bump(3)" },
        .{ .method = "textDocument/signatureHelp", .file = "app.f90", .at = "bump(3)", .plus = 5 },
        .{ .method = "textDocument/definition", .file = "app.f90", .at = "norm()" },
        .{ .method = "textDocument/completion", .file = "app.f90", .at = "norm()", .plus = 2 },
        .{ .method = "textDocument/references", .file = "app.f90", .at = "counter, p" },
        .{ .method = "textDocument/documentHighlight", .file = "app.f90", .at = "counter, p" },
        .{ .method = "textDocument/references", .file = "app.f90", .at = "bump(3)" },
        .{ .method = "textDocument/rename", .file = "app.f90", .at = "counter, p", .extra = "renamed" },
        .{ .method = "textDocument/hover", .file = "report.f90", .at = "total" },
        .{ .method = "textDocument/documentSymbol", .file = "lib.f90" },
        .{ .method = "textDocument/foldingRange", .file = "lib.f90" },
        .{ .method = "textDocument/semanticTokens/full", .file = "lib.f90" },
        .{ .method = "textDocument/codeLens", .file = "lib.f90" },
        .{ .method = "workspace/symbol", .file = "" },
        .{ .method = "textDocument/prepareCallHierarchy", .file = "lib.f90", .at = "bump(n)" },
    };
    for (reqs) |r| {
        // the files rest again, as after a save
        try w.save("app.f90");
        var params: json.Value = undefined;
        if (r.file.len == 0) {
            params = try json.from(a, .{ .query = "" });
        } else if (r.at) |needle| {
            const p = w.pos(r.file, needle, 0, r.plus);
            params = try json.from(a, .{
                .textDocument = .{ .uri = try w.uri(r.file) },
                .position = .{ .line = p.line, .character = p.col },
                .newName = r.extra orelse "",
                .context = .{ .includeDeclaration = true },
            });
        } else params = try json.from(a, .{ .textDocument = .{ .uri = try w.uri(r.file) } });
        const res = try w.server.dispatchPublic(a, r.method, params);
        try out.print(a, "{s} {s}: {s}\n", .{ r.method, r.file, try json.stringify(a, res) });
        // incoming calls of the procedure call hierarchy prepared
        if (std.mem.eql(u8, r.method, "textDocument/prepareCallHierarchy")) {
            const items = json.items(res);
            if (items.len == 0) return error.NoCallHierarchyItem;
            const item = items[0];
            const calls = try w.server.dispatchPublic(a, "callHierarchy/incomingCalls", try json.from(a, .{ .item = item }));
            try out.print(a, "incoming: {s}\n", .{try json.stringify(a, calls)});
        }
    }
    for ([_][]const u8{ "lib.f90", "report.f90" }) |name| {
        for (try w.diagnostics(name)) |d| try out.print(a, "{s}:{d}: {s}\n", .{ name, d.line, d.message });
    }
    const root = try w.uri("");
    return std.mem.replaceOwned(u8, a, out.items, root, "ROOT/");
}

test "requests answer as with every file in full while those not open are summaries (#219)" {
    const full = try h.Workspace.init(&files, .{ .summaries = false });
    defer full.deinit();
    try full.open("app.f90", "fortran");
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("app.f90", "fortran");
    try h.expect(try isSummary(w, "lib.f90") and try isSummary(w, "report.f90"), "the files not open are no summaries", .{});
    try h.expect(!try isSummary(w, "app.f90") and !try isSummary(full, "lib.f90"), "an open file, or a file without summaries, is one", .{});
    const want = try session(full);
    const got = try session(w);
    try std.testing.expectEqualStrings(want, got);
}

test "a file not open is a summary until a request reads more of it (#219)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("app.f90", "fortran");
    try h.expect(try isSummary(w, "lib.f90"), "lib.f90 is no summary", .{});
    // references of the module variable read lib.f90 and report.f90 (which
    // names it as `total`)
    const refs = try w.references("app.f90", w.pos("app.f90", "counter, p", 0, 0));
    try h.expect(refs.len >= 5, "{d} references", .{refs.len});
    try h.expect(!try isSummary(w, "lib.f90") and !try isSummary(w, "report.f90"), "references did not read the files in full", .{});
    try w.save("app.f90");
    try h.expect(try isSummary(w, "lib.f90"), "lib.f90 did not rest again after a save", .{});
    // opened, it is in full; closed, a summary again
    try w.open("lib.f90", "fortran");
    try h.expect(!try isSummary(w, "lib.f90"), "an open file is a summary", .{});
    try w.close("lib.f90");
    try h.expect(try isSummary(w, "lib.f90"), "a closed file is no summary", .{});
}

test "the files a request read last stay in full at a save, up to keep_awake (#219)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    w.server.keep_awake = 1;
    try w.open("app.f90", "fortran");
    // one, then the other, read in full
    _ = try w.hover("lib.f90", w.pos("lib.f90", "bump(n)", 0, 0));
    _ = try w.hover("report.f90", w.pos("report.f90", "total", 0, 0));
    try h.expect(!try isSummary(w, "lib.f90") and !try isSummary(w, "report.f90"), "the hovers did not read the files in full", .{});
    try w.save("app.f90");
    try h.expect(try isSummary(w, "lib.f90") and !try isSummary(w, "report.f90"), "not only the file read last stayed in full", .{});
}
