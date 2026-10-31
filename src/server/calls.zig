//! Call hierarchy (`textDocument/prepareCallHierarchy`,
//! `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`): the
//! procedures that call a procedure, found among its references, and those
//! its body calls.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const paths = @import("../paths.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");
const references = @import("references.zig");
const signature = @import("signature.zig");

fn isProcedure(o: *const Obj) bool {
    return switch (o.kind) {
        .subroutine, .function, .program => true,
        else => false,
    };
}

/// The item of a procedure or program, or null for one without a file
fn itemOf(self: *Server, a: Allocator, o: *const Obj) !?lsp.CallHierarchyItem {
    const path = o.file_ast.path orelse return null;
    if (o.sline == 0) return null;
    const file = self.fileForPath(path);
    const line = o.sline - 1;
    const end_line = @max(o.eline, o.sline) - 1;
    var sel = Server.rangeOf(file, line, 0, line, 0);
    if (file) |f| if (f.getLine(line, false)) |text| {
        var it = helpers.words(text);
        while (it.next()) |w| if (std.ascii.eqlIgnoreCase(w.str, o.name)) {
            sel = Server.rangeOf(f, line, w.start, line, w.end);
            break;
        };
    };
    const end_len = if (file) |f| (if (f.getLine(end_line, false)) |t| t.len else 0) else 0;
    return .{
        .name = o.name,
        .kind = if (o.kind == .program) 2 else 12,
        .detail = if (o.parent) |p| (if (p.name.len > 0 and p.name[0] != '#') p.name else null) else null,
        .uri = try paths.pathToUri(a, path),
        .range = Server.rangeOf(file, line, 0, end_line, end_len),
        .selectionRange = sel,
    };
}

/// The procedure an item stands for
fn procedureOf(self: *Server, a: Allocator, item: lsp.CallHierarchyItem) !?*Obj {
    const file = (try self.fileFromUri(a, item.uri)) orelse return null;
    const line = item.selectionRange.start.line;
    const col = Server.toByteCol(file, line, item.selectionRange.start.character);
    const ast = file.ast orelse return null;
    // the scope that starts there, else what the name resolves to
    for (ast.scope_list.items) |sc| if (isProcedure(sc) and sc.sline == line + 1) return sc;
    const o = (try definition.getDefinition(self, a, file, line, col, false)) orelse return null;
    return if (isProcedure(o)) o else null;
}

pub fn servePrepare(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const d = (try definition.definitionAt(self, a, params, false)) orelse return .null;
    var o = d.obj;
    if (o.kind == .interface) o = (try signature.genericSpecific(self, a, d.file, d.line, d.col, o)) orelse return .null;
    // a procedure's interface: its implementation, when there is one
    if (o.linkObj()) |impl| if (isProcedure(impl)) {
        o = impl;
    };
    if (!isProcedure(o)) return .null;
    const item = (try itemOf(self, a, o)) orelse return .null;
    return json.from(a, &[_]lsp.CallHierarchyItem{item});
}

/// The innermost procedure or program around 0-based line `line` of `file`
fn callerAt(file: *FortranFile, line: usize) ?*Obj {
    const ast = file.ast orelse return null;
    var cur = ast.getInnerScope(line + 1);
    var depth: usize = 0;
    while (cur) |c| : (cur = c.parent) {
        depth += 1;
        if (depth > 64) break;
        if (isProcedure(c)) return c;
    }
    return null;
}

/// Whether the name at `start`..`end` of `text` is called: after CALL, or
/// before `(` (or a CUDA `<<<`)
fn isCall(text: []const u8, start: usize, end: usize) bool {
    var j = end;
    while (j < text.len and text[j] == ' ') j += 1;
    if (j < text.len and (text[j] == '(' or std.mem.startsWith(u8, text[j..], "<<<"))) return true;
    var s = start;
    while (s > 0 and (text[s - 1] == ' ' or text[s - 1] == '%')) s -= 1;
    // skip a type-bound chain `obj%member%`
    while (s > 0 and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_' or text[s - 1] == '%' or text[s - 1] == ')' or text[s - 1] == '(')) s -= 1;
    const before = std.mem.trimEnd(u8, text[0..s], " ");
    return before.len >= 4 and std.ascii.eqlIgnoreCase(before[before.len - 4 ..], "call") and
        (before.len == 4 or !(std.ascii.isAlphanumeric(before[before.len - 5]) or before[before.len - 5] == '_'));
}

/// Whether 0-based line `line` of `file` opens a procedure (or the
/// prototype of one in an interface) named `name`: its definition, no call
fn opensProcedureNamed(file: *FortranFile, line: usize, name: []const u8) bool {
    const ast = file.ast orelse return false;
    for (ast.scope_list.items) |sc| {
        if (sc.sline == line + 1 and (sc.kind == .subroutine or sc.kind == .function) and sc.nameLowerEql(name)) return true;
    }
    return false;
}

const Group = struct { obj: *Obj, ranges: std.ArrayList(lsp.Range) };

fn addTo(a: Allocator, groups: *std.ArrayList(Group), o: *Obj, r: lsp.Range) !void {
    for (groups.items) |*g| if (g.obj == o) {
        try g.ranges.append(a, r);
        return;
    };
    var g: Group = .{ .obj = o, .ranges = .empty };
    try g.ranges.append(a, r);
    try groups.append(a, g);
}

pub fn serveIncoming(self: *Server, a: Allocator, params: lsp.CallHierarchyCallsParams) !Value {
    const callee = (try procedureOf(self, a, params.item)) orelse return .null;
    const rs = references.referenceScope(self, callee) orelse return .null;
    var groups: std.ArrayList(Group) = .empty;
    for (try references.getAllReferences(self, a, callee, rs.type_mem, rs.restrict, false)) |fr| {
        for (fr.refs.items) |r| {
            const text = fr.file.getLine(r.line, false) orelse continue;
            if (!isCall(text, r.start, r.end)) continue;
            if (opensProcedureNamed(fr.file, r.line, callee.name)) continue;
            const caller = callerAt(fr.file, r.line) orelse continue;
            try addTo(a, &groups, caller, Server.rangeOf(fr.file, r.line, r.start, r.line, r.end));
        }
    }
    var out: std.ArrayList(lsp.CallHierarchyIncomingCall) = .empty;
    for (groups.items) |g| {
        const item = (try itemOf(self, a, g.obj)) orelse continue;
        try out.append(a, .{ .from = item, .fromRanges = g.ranges.items });
    }
    return json.from(a, out.items);
}

pub fn serveOutgoing(self: *Server, a: Allocator, params: lsp.CallHierarchyCallsParams) !Value {
    const caller = (try procedureOf(self, a, params.item)) orelse return .null;
    const path = caller.file_ast.path orelse return .null;
    const file = self.fileForPath(path) orelse return .null;
    if (caller.sline == 0) return .null;
    const first = caller.sline - 1;
    const last = @min(@max(caller.eline, caller.sline) - 1, file.nLines() -| 1);
    var groups: std.ArrayList(Group) = .empty;
    var ln = first + 1;
    while (ln <= last) : (ln += 1) {
        // the procedures it contains call for themselves
        if (callerAt(file, ln) != caller) continue;
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        var code = try helpers.stripStrings(a, raw, true);
        if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
        var it = helpers.words(code);
        while (it.next()) |w| {
            if (!isCall(code, w.start, w.end)) continue;
            const o = (try definition.getDefinition(self, a, file, ln, w.start, false)) orelse continue;
            var callee = switch (o.kind) {
                .subroutine, .function => o,
                .method => o.linkObj() orelse continue,
                .interface => (try signature.genericSpecific(self, a, file, ln, w.start, o)) orelse continue,
                else => continue,
            };
            if (callee.linkObj()) |impl| if (isProcedure(impl)) {
                callee = impl;
            };
            if (callee.file_ast.file == null or !isProcedure(callee)) continue;
            try addTo(a, &groups, callee, Server.rangeOf(file, ln, w.start, ln, w.end));
        }
    }
    var out: std.ArrayList(lsp.CallHierarchyOutgoingCall) = .empty;
    for (groups.items) |g| {
        const item = (try itemOf(self, a, g.obj)) orelse continue;
        try out.append(a, .{ .to = item, .fromRanges = g.ranges.items });
    }
    return json.from(a, out.items);
}
