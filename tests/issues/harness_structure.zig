//! The requests of the harness about a workspace's structure: document and
//! workspace symbols, folding ranges, semantic tokens, call and type
//! hierarchies, the compile order.
//! Part of `Workspace` (harness.zig): each function takes it as `w`.

const std = @import("std");
const h = @import("harness.zig");
const zfls = h.zfls;
const json = h.json;
const Value = json.Value;
const Workspace = h.Workspace;
const Pos = h.Pos;
const Fold = h.Fold;
const Token = h.Token;
/// The call hierarchy item at a position (its JSON), or null
pub fn prepareCallHierarchy(w: *Workspace, name: []const u8, p: Pos) !?Value {
    const v = try w.server.dispatchPublic(w.a(), "textDocument/prepareCallHierarchy", try w.posParams(name, p));
    const items = json.items(v);
    return if (items.len > 0) items[0] else null;
}

/// The type hierarchy item at a position (its JSON), or null
pub fn prepareTypeHierarchy(w: *Workspace, name: []const u8, p: Pos) !?Value {
    const v = try w.server.dispatchPublic(w.a(), "textDocument/prepareTypeHierarchy", try w.posParams(name, p));
    const items = json.items(v);
    return if (items.len > 0) items[0] else null;
}

/// The names of the supertypes (`super`) or subtypes of a type item
pub fn typeHierarchy(w: *Workspace, item: Value, super: bool) ![]const []const u8 {
    const v = try w.request(if (super) "typeHierarchy/supertypes" else "typeHierarchy/subtypes", .{ .item = item });
    var out: std.ArrayList([]const u8) = .empty;
    for (json.items(v)) |t| try out.append(w.a(), json.str(json.get(t, "name")) orelse "");
    return out.items;
}

/// `zfls/compileOrder`: the module names in order, and the cycles
pub fn compileOrder(w: *Workspace) !struct { order: []const []const u8, cycles: usize } {
    const v = try w.request("zfls/compileOrder", .{});
    var order: std.ArrayList([]const u8) = .empty;
    for (json.items(json.get(v, "order"))) |u| try order.append(w.a(), json.str(json.get(u, "name")) orelse "");
    return .{ .order = order.items, .cycles = json.items(json.get(v, "cycles")).len };
}

/// The name of a call hierarchy item
pub fn itemName(item: Value) []const u8 {
    return json.str(json.get(item, "name")) orelse "";
}

/// A call of the hierarchy: the other procedure, and how many call
/// sites
pub const Call = struct { name: []const u8, sites: usize };

/// `callHierarchy/incomingCalls` (`incoming`) or `outgoingCalls`
pub fn calls(w: *Workspace, item: Value, incoming: bool) ![]const Call {
    const method = if (incoming) "callHierarchy/incomingCalls" else "callHierarchy/outgoingCalls";
    const v = try w.request(method, .{ .item = item });
    var out: std.ArrayList(Call) = .empty;
    for (json.items(v)) |c| {
        const other = json.get(c, if (incoming) "from" else "to") orelse continue;
        try out.append(w.a(), .{ .name = json.str(json.get(other, "name")) orelse "", .sites = json.items(json.get(c, "fromRanges")).len });
    }
    return out.items;
}

/// Names of the symbols of a document
pub fn documentSymbols(w: *Workspace, name: []const u8) ![]const []const u8 {
    const v = try w.server.dispatchPublic(w.a(), "textDocument/documentSymbol", try w.docParams(name));
    var out: std.ArrayList([]const u8) = .empty;
    for (json.items(v)) |s| try out.append(w.a(), json.str(json.get(s, "name")) orelse "");
    return out.items;
}

/// The document symbols of a client with `hierarchical_symbols`, as
/// paths from the outermost (`mod/proc/var`), parents before children
pub fn symbolPaths(w: *Workspace, name: []const u8) ![]const []const u8 {
    const v = try w.server.dispatchPublic(w.a(), "textDocument/documentSymbol", try w.docParams(name));
    var out: std.ArrayList([]const u8) = .empty;
    try appendSymbolPaths(w, v, "", &out);
    return out.items;
}

fn appendSymbolPaths(w: *Workspace, v: Value, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    for (json.items(v)) |s| {
        const sym = json.str(json.get(s, "name")) orelse "";
        const p = if (prefix.len == 0) sym else try w.a().print("{s}/{s}", .{ prefix, sym });
        try out.append(w.a(), p);
        if (json.get(s, "children")) |c| try appendSymbolPaths(w, c, p, out);
    }
}

/// The folding ranges of a file, as 0-based `start-end` line pairs
pub fn foldingRanges(w: *Workspace, name: []const u8) ![]const Fold {
    const v = try w.server.dispatchPublic(w.a(), "textDocument/foldingRange", try w.docParams(name));
    var out: std.ArrayList(Fold) = .empty;
    for (json.items(v)) |f| try out.append(w.a(), .{
        .start = json.int(json.get(f, "startLine")) orelse -1,
        .end = json.int(json.get(f, "endLine")) orelse -1,
    });
    return out.items;
}

/// The semantic tokens of a file, decoded
pub fn semanticTokens(w: *Workspace, name: []const u8) ![]const Token {
    return decodeTokens(w, name, try w.server.dispatchPublic(w.a(), "textDocument/semanticTokens/full", try w.docParams(name)));
}

/// The semantic tokens of lines `first` to `last` (0-based) of a file,
/// decoded (`semanticTokens/range`)
pub fn semanticTokensRange(w: *Workspace, name: []const u8, first: i64, last: i64) ![]const Token {
    return decodeTokens(w, name, try w.request("textDocument/semanticTokens/range", .{
        .textDocument = .{ .uri = try w.uri(name) },
        .range = .{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last, .character = 0 } },
    }));
}

fn decodeTokens(w: *Workspace, name: []const u8, v: Value) ![]const Token {
    const data = json.items(json.get(v, "data"));
    var lines = std.mem.splitScalar(u8, w.text(name), '\n');
    var line_texts: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |l| try line_texts.append(w.a(), l);
    var out: std.ArrayList(Token) = .empty;
    var line: i64 = 0;
    var col: i64 = 0;
    var i: usize = 0;
    while (i + 5 <= data.len) : (i += 5) {
        const dl = json.int(data[i]) orelse 0;
        const dc = json.int(data[i + 1]) orelse 0;
        const n: usize = @intCast(json.int(data[i + 2]) orelse 0);
        const t: usize = @intCast(json.int(data[i + 3]) orelse 0);
        if (dl != 0) {
            line += dl;
            col = dc;
        } else col += dc;
        const lt = if (line < line_texts.items.len) line_texts.items[@intCast(line)] else "";
        const s: usize = @min(lt.len, @as(usize, @intCast(col)));
        try out.append(w.a(), .{
            .line = line,
            .text = lt[s..@min(lt.len, s + n)],
            .type = if (t < zfls.semantic.legend.tokenTypes.len) zfls.semantic.legend.tokenTypes[t] else "?",
        });
    }
    return out.items;
}

/// Names of the workspace symbols matching `query`
pub fn workspaceSymbols(w: *Workspace, query: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.workspaceSymbolInfos(query)) |s| try out.append(w.a(), s.name);
    return out.items;
}

pub const WorkspaceSymbol = struct { name: []const u8, uri: []const u8, container: ?[]const u8 };

/// The workspace symbols matching `query`: names, files and containers
pub fn workspaceSymbolInfos(w: *Workspace, query: []const u8) ![]const WorkspaceSymbol {
    const v = try w.request("workspace/symbol", .{ .query = query });
    var out: std.ArrayList(WorkspaceSymbol) = .empty;
    for (json.items(v)) |s| try out.append(w.a(), .{
        .name = json.str(json.get(s, "name")) orelse "",
        .uri = json.str(json.get(json.get(s, "location"), "uri")) orelse "",
        .container = json.str(json.get(s, "containerName")),
    });
    return out.items;
}
