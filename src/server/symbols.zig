//! Document and workspace symbols, folding ranges and semantic tokens.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const outline = @import("../outline.zig");
const fuzzy = @import("../fuzzy.zig");
const semantic = @import("../semantic.zig");

const Obj = objects.Obj;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");

/// The symbols whose names contain the query, by name (as fortls), then
/// those it matches fuzzily, best first (hansec #195)
pub fn serveWorkspaceSymbol(self: *Server, a: Allocator, params: lsp.WorkspaceSymbolParams) !Value {
    var items: std.ArrayList(lsp.SymbolInformation) = .empty;
    const Fuzzy = struct { obj: *Obj, score: u32 };
    var fuzzy_matches: std.ArrayList(Fuzzy) = .empty;
    for (try objects.findInWorkspace(self.env(a), "", false, false)) |cand| {
        if (std.ascii.findIgnoreCase(cand.name, params.query) != null) {
            try items.append(a, try workspaceSymbolOf(a, cand));
        } else if (fuzzy.score(cand.name, params.query)) |s| {
            try fuzzy_matches.append(a, .{ .obj = cand, .score = s });
        }
    }
    std.mem.sort(lsp.SymbolInformation, items.items, {}, struct {
        fn lt(_: void, x: lsp.SymbolInformation, y: lsp.SymbolInformation) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    std.mem.sort(Fuzzy, fuzzy_matches.items, {}, struct {
        fn lt(_: void, x: Fuzzy, y: Fuzzy) bool {
            if (x.score != y.score) return x.score > y.score;
            if (x.obj.name.len != y.obj.name.len) return x.obj.name.len < y.obj.name.len;
            return std.mem.order(u8, x.obj.name, y.obj.name) == .lt;
        }
    }.lt);
    for (fuzzy_matches.items[0..@min(fuzzy_matches.items.len, 200)]) |f| try items.append(a, try workspaceSymbolOf(a, f.obj));
    return json.from(a, items.items);
}

pub fn workspaceSymbolOf(a: Allocator, cand: *const Obj) !lsp.SymbolInformation {
    const kind: i64 = switch (cand.getType(false)) {
        .module => 2,
        .subroutine => 6,
        .function => 12,
        .class => 5,
        .interface => 11,
        .variable => 13,
        .method => 6,
        else => 1,
    };
    const container: ?[]const u8 = if (std.mem.indexOf(u8, cand.fqsn, "::")) |i| (if (i > 0) cand.fqsn[0..i] else null) else null;
    return .{
        .name = cand.name,
        .kind = kind,
        .location = .{
            .uri = try paths.pathToUri(a, cand.file_ast.path orelse "None"),
            .range = .{
                .start = .{ .line = cand.sline -| 1, .character = 0 },
                .end = .{ .line = cand.eline -| 1, .character = 0 },
            },
        },
        .containerName = container,
    };
}

pub fn symbolOf(name: []const u8, kind: i64, uri: []const u8, sln: usize, eln: ?usize, container: ?[]const u8) lsp.SymbolInformation {
    return .{
        .name = name,
        .kind = kind,
        .location = Server.locationOf(uri, null, sln, 0, eln, 0),
        .containerName = if (container) |c| (if (c.len > 0) c else null) else null,
    };
}

pub fn serveDocumentSymbols(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
    const uri = params.textDocument.uri;
    const file = (try self.fileFromUri(a, uri)) orelse return .{ .array = .init(a) };
    const ast = file.ast orelse return .{ .array = .init(a) };
    if (self.hierarchical_symbols) return json.from(a, try outline.documentSymbols(a, file, ast, self.s.symbol_skip_mem));
    var out: std.ArrayList(lsp.SymbolInformation) = .empty;
    for (try ast.getScopes(a, null)) |scope| {
        if (scope.name.len == 0 or std.mem.startsWith(u8, scope.name, "#") or scope.getType(false) == C.TypeId.select) continue;
        const tree = try str.split(a, scope.fqsn, "::");
        var scope_type: i64 = undefined;
        if (tree.len > 2) {
            if (std.mem.startsWith(u8, tree[1], "#gen_int")) scope_type = 11 else continue;
        } else {
            scope_type = outline.flatKind(scope.getType(false), false);
        }
        const container: ?[]const u8 = if (std.mem.indexOf(u8, scope.fqsn, "::")) |i| (if (i > 0) tree[0] else null) else null;
        try out.append(a, symbolOf(scope.name, scope_type, uri, scope.sline -| 1, scope.eline -| 1, container));
        if (scope.getType(false) == C.TypeId.class and !self.s.symbol_skip_mem) {
            for (scope.childList()) |child| {
                try out.append(a, symbolOf(child.name, outline.flatKind(child.getType(false), true), uri, child.sline -| 1, null, scope.name));
            }
        }
    }
    return json.from(a, out.items);
}

pub fn serveSemanticTokens(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    return json.from(a, lsp.SemanticTokens{ .data = try semantic.tokens(a, self.env(a), file, ast) });
}

pub fn serveFoldingRanges(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    return json.from(a, try outline.foldingRanges(a, file, ast));
}
