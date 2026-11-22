//! Settings from the editor over LSP (#196): `initializationOptions` and
//! `workspace/didChangeConfiguration`, under the config file's names; and
//! `comment_markers` set through them (#741).

const std = @import("std");
const h = @import("harness.zig");

const long_line = [_]h.File{.{ .name = "t.f90", .text =
    \\program p
    \\  integer :: a_very_long_declaration_name
    \\  a_very_long_declaration_name = 1
    \\end program p
    \\
}};

/// The lines (0-based) said to be longer than max_line_length
fn longLines(w: *h.Workspace) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (try w.diagnostics("t.f90")) |d| if (std.mem.startsWith(u8, d.message, "Line length")) try out.append(std.testing.allocator, d.line);
    return out.toOwnedSlice(std.testing.allocator);
}

fn expectLongLines(w: *h.Workspace, want: usize) !void {
    const got = try longLines(w);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(want, got.len);
}

test "initializationOptions set options, as one object or in its zfls member (#196)" {
    inline for (.{ "{\"max_line_length\": 30}", "{\"zfls\": {\"max_line_length\": 30}}" }) |opts| {
        const w = try h.Workspace.init(&long_line, .{ .init_options = opts });
        defer w.deinit();
        try expectLongLines(w, 2);
    }
}

test "the config file takes over from the editor's settings, and they from the command line (#196)" {
    {
        const w = try h.Workspace.init(&long_line, .{ .settings = .{ .max_line_length = 100 }, .init_options = "{\"max_line_length\": 30}" });
        defer w.deinit();
        try expectLongLines(w, 2);
    }
    {
        const files = long_line ++ [_]h.File{.{ .name = ".fortlsrc", .text = "{\"max_line_length\": 100}\n" }};
        const w = try h.Workspace.init(&files, .{ .init_options = "{\"max_line_length\": 30}" });
        defer w.deinit();
        try expectLongLines(w, 0);
        // nor does a change from the editor take over from the file
        try w.changeConfiguration("{\"max_line_length\": 30}");
        try expectLongLines(w, 0);
    }
}

test "didChangeConfiguration applies at once and publishes the diagnostics again (#196)" {
    const w = try h.Workspace.init(&long_line, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    try expectLongLines(w, 0);
    const before = (try w.sentWith("textDocument/publishDiagnostics")).len;
    try w.changeConfiguration("{\"zfls\": {\"max_line_length\": 30}}");
    const sent = try w.sentWith("textDocument/publishDiagnostics");
    try std.testing.expect(sent.len > before);
    try std.testing.expect(std.mem.find(u8, sent[sent.len - 1], "Line length") != null);
    try expectLongLines(w, 2);
    // and back: the command line's value
    try w.changeConfiguration("{}");
    try expectLongLines(w, 0);
}

test "turning diagnostics off publishes none for the open documents (#196)" {
    const w = try h.Workspace.init(&long_line, .{ .settings = .{ .max_line_length = 30 } });
    defer w.deinit();
    try w.open("t.f90", "fortran");
    try w.changeConfiguration("{\"disable_diagnostics\": true}");
    const sent = try w.sentWith("textDocument/publishDiagnostics");
    try std.testing.expect(std.mem.find(u8, sent[sent.len - 1], "\"diagnostics\":[]") != null);
}

const two_dirs = [_]h.File{
    .{ .name = "src/a.f90", .text =
    \\module a
    \\contains
    \\  subroutine alpha()
    \\  end subroutine alpha
    \\end module a
    \\
    },
    .{ .name = "lib/b.f90", .text =
    \\module b
    \\contains
    \\  subroutine beta()
    \\  end subroutine beta
    \\end module b
    \\
    },
    .{ .name = "main.f90", .text =
    \\program main
    \\end program main
    \\
    },
};

fn hasSymbol(w: *h.Workspace, name: []const u8) !bool {
    for (try w.workspaceSymbols(name)) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "a change of what is indexed indexes the workspace again, keeping the editor's text (#196)" {
    const w = try h.Workspace.init(&two_dirs, .{ .init_options = "{\"source_dirs\": [\"src\"]}" });
    defer w.deinit();
    try std.testing.expect(try hasSymbol(w, "alpha"));
    try std.testing.expect(!try hasSymbol(w, "beta"));
    // an open document outside the source directories, with unsaved text
    try w.open("main.f90", "fortran");
    _ = try w.zflsRequest("textDocument/didChange", .{
        .textDocument = .{ .uri = try w.uri("main.f90"), .version = 2 },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = "program main\ncontains\n  subroutine gamma()\n  end subroutine gamma\nend program main\n" }},
    });
    try std.testing.expect(try hasSymbol(w, "gamma"));

    try w.changeConfiguration("{\"source_dirs\": [\"src\", \"lib\"]}");
    try std.testing.expect(try hasSymbol(w, "alpha"));
    try std.testing.expect(try hasSymbol(w, "beta"));
    try std.testing.expect(try hasSymbol(w, "gamma"));

    try w.changeConfiguration("{\"source_dirs\": [\"lib\"]}");
    try std.testing.expect(!try hasSymbol(w, "alpha"));
    try std.testing.expect(try hasSymbol(w, "beta"));
    try std.testing.expect(try hasSymbol(w, "gamma"));
}

const call = [_]h.File{.{ .name = "s.f90", .text =
    \\program s
    \\  call show(1)
    \\contains
    \\  subroutine show(n)
    \\    integer, intent(in) :: n
    \\  end subroutine show
    \\end program s
    \\
}};

fn signatureHelp(w: *h.Workspace) !h.json.Value {
    return w.zflsRequest("textDocument/signatureHelp", try w.positionOf("s.f90", w.pos("s.f90", "show(1", 0, 5)));
}

test "a provider turned on after initialization is registered with a client that allows it (#196)" {
    const w = try h.Workspace.init(&call, .{ .dynamic_registration = true });
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try w.sentWith("client/registerCapability")).len);
    try w.changeConfiguration("{\"use_signature_help\": true, \"formatter\": \"findent\"}");
    const regs = try w.sentWith("client/registerCapability");
    try std.testing.expectEqual(@as(usize, 1), regs.len);
    try std.testing.expect(std.mem.find(u8, regs[0], "\"textDocument/signatureHelp\"") != null);
    try std.testing.expect(std.mem.find(u8, regs[0], "\"textDocument/rangeFormatting\"") != null);
    try std.testing.expect(std.mem.find(u8, regs[0], "codeAction") == null);
    try std.testing.expect(try signatureHelp(w) != .null);
    // once
    try w.changeConfiguration("{\"use_signature_help\": true, \"formatter\": \"findent\", \"max_line_length\": 80}");
    try std.testing.expectEqual(@as(usize, 1), (try w.sentWith("client/registerCapability")).len);
    // the client's answer is no request
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = w.sent.items.len;
    w.server.handle(arena.allocator(), try h.json.from(arena.allocator(), .{ .jsonrpc = "2.0", .id = 1, .result = null }));
    try std.testing.expectEqual(before, w.sent.items.len);
}

test "a client that registers nothing is told to restart the server (#196)" {
    const w = try h.Workspace.init(&call, .{});
    defer w.deinit();
    try w.changeConfiguration("{\"use_signature_help\": true}");
    try std.testing.expectEqual(@as(usize, 0), (try w.sentWith("client/registerCapability")).len);
    var told = false;
    for (try w.sentWith("window/showMessage")) |m| told = told or std.mem.find(u8, m, "Restart zfls to apply use_signature_help") != null;
    try std.testing.expect(told);
}

test "a provider turned off answers nothing (#196)" {
    const w = try h.Workspace.init(&call, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    try std.testing.expect(try signatureHelp(w) != .null);
    try w.changeConfiguration("{\"use_signature_help\": false}");
    try std.testing.expect(try signatureHelp(w) == .null);
}

test "a configuration file written on disk is read again, and its removal too (#196)" {
    const w = try h.Workspace.init(&long_line, .{});
    defer w.deinit();
    try expectLongLines(w, 0);
    try w.changeOnDisk(".fortlsrc", "{\"max_line_length\": 30}");
    try expectLongLines(w, 2);
    try w.changeOnDisk(".fortlsrc", null);
    try expectLongLines(w, 0);
}

test "a configuration file changed on disk keeps taking over from the editor's settings (#196)" {
    const w = try h.Workspace.init(&long_line, .{ .init_options = "{\"max_line_length\": 30}" });
    defer w.deinit();
    try expectLongLines(w, 2);
    try w.changeOnDisk(".fortls.json", "{\"max_line_length\": 100}");
    try expectLongLines(w, 0);
    try w.changeOnDisk(".fortls.json", "{}");
    try expectLongLines(w, 2);
}

const guarded = [_]h.File{.{ .name = "m.F90", .text =
    \\module m
    \\contains
    \\#ifdef FEATURE
    \\  subroutine guarded()
    \\  end subroutine guarded
    \\#endif
    \\end module m
    \\
}};

test "a compile_commands.json written on disk indexes the workspace again (#196)" {
    const w = try h.Workspace.init(&guarded, .{});
    defer w.deinit();
    try std.testing.expect(!try hasSymbol(w, "guarded"));
    try w.changeOnDisk("build/compile_commands.json",
        \\[{"directory": "..", "file": "m.F90", "arguments": ["gfortran", "-DFEATURE", "-c", "m.F90"]}]
    );
    try std.testing.expect(try hasSymbol(w, "guarded"));
}

test "the server asks a client that allows it to watch the configuration files (#196)" {
    const w = try h.Workspace.init(&long_line, .{ .watch_registration = true });
    defer w.deinit();
    _ = try w.zflsRequest("initialized", .{});
    const regs = try w.sentWith("client/registerCapability");
    try std.testing.expectEqual(@as(usize, 1), regs.len);
    try std.testing.expect(std.mem.find(u8, regs[0], "**/{.fortlsrc,.fortls.json,.fortls,fpm.toml,compile_commands.json}") != null);
}

test "a client that cannot is asked nothing (#196)" {
    const w = try h.Workspace.init(&long_line, .{});
    defer w.deinit();
    _ = try w.zflsRequest("initialized", .{});
    try std.testing.expectEqual(@as(usize, 0), (try w.sentWith("client/registerCapability")).len);
}

test "comment_markers: what follows a marker is a comment (#741)" {
    const marked = [_]h.File{.{ .name = "m.f90", .text =
        \\program p
        \\  implicit none
        \\  integer :: a
        \\  a = 1 ;* b = 2
        \\end program p
        \\
    }};
    // without the marker, `;` ends the statement and `b` is a name
    inline for (.{ "{}", "{\"comment_markers\": [\";*\"]}" }, .{ 1, 0 }) |opts, want| {
        const w = try h.Workspace.init(&marked, .{ .init_options = opts });
        defer w.deinit();
        var found: usize = 0;
        for (try w.diagnostics("m.f90")) |d| {
            if (std.mem.find(u8, d.message, "\"b\" is not declared") != null) found += 1;
        }
        try std.testing.expectEqual(@as(usize, want), found);
    }
}
