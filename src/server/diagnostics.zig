//! Diagnostics (computing, filtering by settings and suppression comments,
//! publishing) and code actions.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const glob = @import("../glob.zig");
const autouse = @import("../autouse.zig");
const suppress = @import("../suppress.zig");

const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const completion = @import("completion.zig");

pub fn serveCodeActions(self: *Server, a: Allocator, params: lsp.CodeActionParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const sline = params.range.start.line;
    const eline = params.range.end.line;
    var out: std.ArrayList(lsp.CodeAction) = .empty;
    try addUseActions(self, a, file, ast, sline, eline, &out);
    const curr_scope = ast.getInnerScope(sline) orelse return if (out.items.len > 0) json.from(a, out.items) else .null;
    const actions = (try curr_scope.getActions(a, sline, eline)) orelse return if (out.items.len > 0) json.from(a, out.items) else .null;
    for (actions) |act| {
        const edit_file = self.fileForPath(act.uri_path);
        const edits = try a.alloc(lsp.TextEdit, act.edits.len);
        for (act.edits, edits) |e, *ev| {
            ev.* = .{ .range = Server.rangeOf(edit_file, e.sline, e.schar, e.eline, e.echar), .newText = e.new_text };
        }
        const files = try a.alloc(lsp.Changes.File, 1);
        files[0] = .{ .uri = try paths.pathToUri(a, act.uri_path), .edits = edits };
        const diags = try a.alloc(lsp.Diagnostic, act.diagnostics.len);
        for (act.diagnostics, diags) |dg, *dv| dv.* = try self.diagnosticOf(a, file, try dg.build(a, file));
        try out.append(a, .{ .title = act.title, .kind = act.kind, .edit = .{ .changes = .{ .files = files } }, .diagnostics = diags });
    }
    return json.from(a, out.items);
}

/// For each name on 0-based lines `sline`..`eline` that is not found in
/// scope but is public in a module: a quick fix adding the USE statement
/// that brings it in (hansec #62)
pub fn addUseActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const diags = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    const uri = try paths.pathToUri(a, file.path);
    for (diags) |d| {
        if (d.code != .object_not_found or d.sln < sline or d.sln > eline) continue;
        const name = d.subject orelse continue;
        const unit = autouse.unitOf(try ast.getScopes(a, d.sln + 1)) orelse continue;
        const at = try autouse.insertionPoint(a, file, unit);
        for (try autouse.exports(a, try completion.usableModules(self, a), .{ .exact = name }, 10)) |e| {
            if (autouse.isWithin(unit, e.module)) continue;
            const text = try autouse.statement(a, at.indent, e.module.name, e.obj.name);
            const edits = try a.alloc(lsp.TextEdit, 1);
            edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = text };
            const files = try a.alloc(lsp.Changes.File, 1);
            files[0] = .{ .uri = uri, .edits = edits };
            const dv = try a.alloc(lsp.Diagnostic, 1);
            dv[0] = try self.diagnosticOf(a, file, d);
            try out.append(a, .{
                .title = try std.fmt.allocPrint(a, "Add use {s}, only: {s}", .{ e.module.name, e.obj.name }),
                .kind = "quickfix",
                .edit = .{ .changes = .{ .files = files } },
                .diagnostics = dv,
            });
        }
    }
}

pub fn diagnosticsOf(self: *Server, a: Allocator, uri: []const u8) !?[]const lsp.Diagnostic {
    const file = (try self.fileFromUri(a, uri)) orelse return null;
    const diags = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    const hidden = try suppress.of(a, file);
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    for (diags) |d| {
        if (hidden.hides(d.code, d.sln)) continue;
        if (d.code == .module_not_found) if (d.subject) |m| if (isExternalModule(self, m)) continue;
        var dd = d;
        dd.severity = severityOf(self, d.code) orelse d.severity;
        if (dd.severity == 0) continue;
        try out.append(a, try self.diagnosticOf(a, file, dd));
    }
    return out.items;
}

/// The severity `diagnostic_severity` gives the diagnostics of `code`
/// (0: hidden), if it names it
pub fn severityOf(self: *const Server, code: C.DiagCode) ?i32 {
    for (self.s.diagnostic_severity.items) |l| if (std.mem.eql(u8, l.code, code.name())) {
        return Server.severity_names.get(l.level);
    };
    return null;
}

/// Whether `external_modules` names module `name`
pub fn isExternalModule(self: *const Server, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, name);
    for (self.s.external_modules.slice()) |pat| {
        var pbuf: [256]u8 = undefined;
        if (pat.len > pbuf.len) continue;
        if (glob.fnmatch(std.ascii.lowerString(&pbuf, pat), lower)) return true;
    }
    return false;
}

/// Warns about the codes and severities of `diagnostic_severity` that
/// zfls does not know
pub fn checkDiagnosticSeverity(self: *Server, a: Allocator) !void {
    for (self.s.diagnostic_severity.items) |l| {
        if (C.DiagCode.fromName(l.code) == null) {
            self.postMessage(a, try std.fmt.allocPrint(a, "diagnostic_severity: unknown diagnostic code \"{s}\"", .{l.code}), C.Severity.warn);
        } else if (Server.severity_names.get(l.level) == null) {
            self.postMessage(a, try std.fmt.allocPrint(a, "diagnostic_severity: \"{s}\" for \"{s}\" is not off, error, warning, information or hint", .{ l.level, l.code }), C.Severity.warn);
        }
    }
}

/// The diagnostics of a file as a JSON array (used by the debug CLI)
pub fn getDiagnostics(self: *Server, a: Allocator, uri: []const u8) !?Value {
    const diags = (try diagnosticsOf(self, a, uri)) orelse return null;
    return try json.from(a, diags);
}

pub fn sendDiagnostics(self: *Server, a: Allocator, uri: []const u8) void {
    const res = diagnosticsOf(self, a, uri) catch |e| {
        self.writeError(a, .{ .integer = -1 }, -32603, @errorName(e), .{ .traceback = @errorName(e) }) catch |e2| self.logSendFailure(e2);
        return;
    };
    if (res) |diags| {
        self.sendNotification(a, "textDocument/publishDiagnostics", json.from(a, lsp.PublishDiagnosticsParams{ .uri = uri, .diagnostics = diags }) catch return) catch |e| self.logSendFailure(e);
    }
}
