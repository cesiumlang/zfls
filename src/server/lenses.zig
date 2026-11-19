//! Code lenses (`textDocument/codeLens`, `codeLens/resolve`): above each
//! module, procedure and derived type the number of its references,
//! counted when the lens is resolved (when the editor shows it), and above
//! a program Run and Debug.
//!
//! What a lens does when clicked is the client's: a client that runs
//! `zfls.showReferences` (uri, position, locations), `zfls.runFile` and
//! `zfls.debugFile` (uri) itself says so in its capabilities, under
//! `experimental.commands.commands` as rust-analyzer's clients do (the VS
//! Code extension does). Without them a reference lens only shows the count,
//! and a program has no lenses.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const objects = @import("../objects.zig");

const Obj = objects.Obj;
const Value = json.Value;

const Server = @import("../server.zig").Server;
const references = @import("references.zig");

/// The lens commands the client runs
pub const Commands = struct {
    show_references: bool = false,
    run: bool = false,
    debug: bool = false,
};

pub const show_references = "zfls.showReferences";
pub const run_file = "zfls.runFile";
pub const debug_file = "zfls.debugFile";

/// The lens commands that the client's `experimental.commands.commands`
/// lists
pub fn clientCommands(experimental: ?Value) Commands {
    var out: Commands = .{};
    for (json.items(json.path(experimental, &.{ "commands", "commands" }))) |c| {
        const name = json.str(c) orelse continue;
        if (std.mem.eql(u8, name, show_references)) out.show_references = true;
        if (std.mem.eql(u8, name, run_file)) out.run = true;
        if (std.mem.eql(u8, name, debug_file)) out.debug = true;
    }
    return out;
}

/// Whether a unit has a reference lens: modules, procedures (not the
/// declarations of an interface block) and derived types
fn counted(obj: *const Obj) bool {
    return switch (obj.kind) {
        .module, .type => true,
        .subroutine, .function => if (obj.parent) |p| p.kind != .interface else true,
        else => false,
    };
}

pub fn serveCodeLens(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
    const uri = params.textDocument.uri;
    const file = (try self.fileFromUri(a, uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const runs = !self.s.code_lens_no_run and (self.lens_commands.run or self.lens_commands.debug);
    var out: std.ArrayList(lsp.CodeLens) = .empty;
    for (ast.scope_list.items) |obj| {
        if (obj.file_ast != ast or obj.sline == 0) continue;
        const line = obj.sline - 1;
        const text = file.getLine(line, false) orelse continue;
        // where the name is not on the first line (a macro, a
        // continuation), nothing can be asked about it
        const w = helpers.findWordInLineIgnoreCase(text, obj.name);
        if (w.start < 0) continue;
        const range = Server.rangeOf(file, line, @intCast(w.start), line, @intCast(w.end));
        if (obj.kind == .program and runs) {
            const args = try a.alloc(Value, 1);
            args[0] = .{ .string = uri };
            if (self.lens_commands.run) try out.append(a, .{ .range = range, .command = .{ .title = "Run", .command = run_file, .arguments = args } });
            if (self.lens_commands.debug) try out.append(a, .{ .range = range, .command = .{ .title = "Debug", .command = debug_file, .arguments = args } });
        }
        if (!self.s.code_lens_no_references and counted(obj)) {
            try out.append(a, .{ .range = range, .data = .{ .uri = uri, .end = @max(obj.eline, obj.sline) - 1 } });
        }
    }
    return json.from(a, out.items);
}

/// `codeLens/resolve`: a reference lens with its count, and the command
/// that shows them where the client has it
pub fn serveResolve(self: *Server, a: Allocator, params: Value) !Value {
    const lens = json.decode(lsp.CodeLens, a, params) catch return params;
    const data = lens.data orelse return params;
    const locations = try referencesOf(self, a, data, lens.range.start);
    const title = if (locations.len == 1) "1 reference" else try a.print("{d} references", .{locations.len});
    var command: lsp.Command = .{ .title = title, .command = "" };
    if (self.lens_commands.show_references) {
        const args = try a.alloc(Value, 3);
        args[0] = .{ .string = data.uri };
        args[1] = try json.from(a, lens.range.start);
        args[2] = try json.from(a, locations);
        command = .{ .title = title, .command = show_references, .arguments = args };
    }
    return json.from(a, lsp.CodeLens{ .range = lens.range, .command = command, .data = data });
}

/// The references of the unit named at `at`, what `textDocument/references`
/// gives but for the unit's own statement and its end statement
pub fn referencesOf(self: *Server, a: Allocator, data: lsp.CodeLensData, at: lsp.Position) ![]const Value {
    const found = references.serveReferences(self, a, .{ .textDocument = .{ .uri = data.uri }, .position = at }, true) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return &.{},
    };
    const own = try self.pathFromUri(a, data.uri);
    var out: std.ArrayList(Value) = .empty;
    for (json.items(found)) |loc| {
        const line = json.int(json.path(loc, &.{ "range", "start", "line" })) orelse continue;
        if (line == @as(i64, @intCast(at.line)) or line == @as(i64, @intCast(data.end))) {
            const uri = json.str(json.get(loc, "uri")) orelse continue;
            if (std.mem.eql(u8, try self.pathFromUri(a, uri), own)) continue;
        }
        try out.append(a, loc);
    }
    return out.items;
}
