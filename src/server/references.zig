//! References, document highlights and rename.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const regex = @import("../regex.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const intrinsics = @import("../intrinsics.zig");
const constructs = @import("../constructs.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const operators = @import("operators.zig");
const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");

pub fn hasLinkAttr(o: *const Obj) bool {
    return switch (o.kind) {
        .variable, .method, .subroutine, .function => true,
        else => false,
    };
}

/// Whether `v` is the result variable of function `fun`: without a RESULT
/// clause it is named like the function, and renaming the function renames
/// it (upstream #322)
pub fn isImplicitResult(fun: *const Obj, v: *const Obj) bool {
    return fun.kind == .function and v.kind == .variable and v.parent == fun and std.ascii.eqlIgnoreCase(v.name, fun.name);
}

/// Whether `x` and `y` are the interface and the implementation of the
/// same separate module procedure, in either order (hansec #168)
pub fn isSeparateProcedurePair(x: *const Obj, y: *const Obj) bool {
    return isSeparateInterfaceOf(x, y) or isSeparateInterfaceOf(y, x);
}

pub fn isSeparateInterfaceOf(iface: *const Obj, impl: *const Obj) bool {
    const p = iface.parent orelse return false;
    return p.kind == .interface and iface.isModScope() and iface.linkObj() == impl;
}

/// Whether the name at `col` is the original name of a renamed import of
/// `def_obj`, as in `use m, only: local => NAME` where `m` defines it. The
/// original name is not visible under that name in the importing scope,
/// so the definition lookup cannot find it (upstream #52).
pub fn isRenamedOriginal(line: []const u8, col: usize, def_obj: *const Obj) bool {
    const parent = def_obj.parent orelse return false;
    if (parent.kind != .module) return false;
    if (!std.mem.endsWith(u8, str.rstrip(line[0..col]), "=>")) return false;
    const t = str.lstrip(line);
    if (!std.ascii.startsWithIgnoreCase(t, "use")) return false;
    var rest = str.lstrip(t[3..]);
    if (std.mem.startsWith(u8, rest, "::")) rest = str.lstrip(rest[2..]);
    var n: usize = 0;
    while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
    return std.ascii.eqlIgnoreCase(rest[0..n], parent.name);
}

/// The renamed import that the word at (`line`, `col`) is the local name
/// of, if it is one (upstream #52)
pub fn renamedImport(a: Allocator, file: *FortranFile, line: usize, col: usize, target: *const Obj) !?Server.RenamedImport {
    const text = file.getLine(line, false) orelse return null;
    var it = helpers.words(text);
    const word = while (it.next()) |m| {
        if (m.start <= col and col <= m.end) break m.str;
    } else return null;
    if (std.ascii.eqlIgnoreCase(word, target.name)) return null;
    const lower = try std.ascii.allocLowerString(a, word);
    var scope = (file.ast orelse return null).getInnerScope(line + 1) orelse return null;
    while (true) {
        for (scope.scopeData().use.items) |u| {
            if (!u.is_import and u.rename_map.get(lower) != null) return .{ .alias = lower, .scope = scope, .use_line = u.line_number };
        }
        scope = scope.parent orelse return null;
    }
}

/// The uses of a renamed import: of its local name, in the scope of the
/// USE statement and the statement itself, not of the original name
pub fn aliasReferences(self: *Server, a: Allocator, file: *FortranFile, def_obj: *Obj, ri: Server.RenamedImport) ![]Server.FileRefs {
    var name_re = regex.Regex.compile(a, try std.fmt.allocPrint(a, "(?:\\W|^)({s})(?:\\W|$)", .{ri.alias}), regex.I) catch return &.{};
    defer name_re.deinit();
    var refs: std.ArrayList(Server.Ref) = .empty;
    const first = ri.scope.sline -| 1;
    const last = @min(ri.scope.eline -| 1, file.lines.items.len -| 1);
    for (file.lines.items[first .. last + 1], first..) |raw_line, i| {
        const line = file.stripComment(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.ascii.findIgnoreCase(line, ri.alias) == null) continue;
        var it = name_re.iterator(line);
        while (it.next()) |m| {
            if (i == ri.use_line -| 1) {
                // in the USE statement only the local name, before the arrow
                const after = str.lstrip(line[m.end(1)..]);
                if (!std.mem.startsWith(u8, after, "=>")) continue;
            } else {
                const var_def = (try definition.getDefinition(self, a, file, i, m.start(1) + 1, false)) orelse continue;
                if (!std.mem.eql(u8, def_obj.fqsn, var_def.fqsn)) continue;
            }
            try refs.append(a, .{ .line = i, .start = m.start(1), .end = m.end(1) });
        }
    }
    if (refs.items.len == 0) return &.{};
    const out = try a.alloc(Server.FileRefs, 1);
    out[0] = .{ .path = file.path, .file = file, .refs = refs };
    return out;
}

/// The references to `def_obj`. A rename also takes what only it must change:
/// the result variable of a function and the original name in a renamed
/// import; "find references" leaves them out, as fortls does.
pub fn getAllReferences(self: *Server, a: Allocator, def_obj: *Obj, type_mem: bool, restrict: ?*FortranFile, for_rename: bool) ![]Server.FileRefs {
    const def_name = try std.ascii.allocLowerString(a, def_obj.name);
    const def_fqsn = def_obj.fqsn;
    var name_re = regex.Regex.compile(a, try std.fmt.allocPrint(a, "(?:\\W|^)({s})(?:\\W|$)", .{def_name}), regex.I) catch return &.{};
    defer name_re.deinit();
    var files: std.ArrayList(*FortranFile) = .empty;
    if (restrict) |f| try files.append(a, f) else try files.appendSlice(a, self.workspace.values());
    var override_cache: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(Server.FileRefs) = .empty;
    for (files.items) |file| {
        var file_refs: std.ArrayList(Server.Ref) = .empty;
        const filename = file.path;
        for (file.lines.items, 0..) |raw_line, i| {
            if (raw_line.len == 0) continue;
            const line = file.stripComment(raw_line);
            if (line.len == 0 or line[0] == '#') continue;
            if (std.ascii.findIgnoreCase(line, def_name) == null) continue;
            var it = name_re.iterator(line);
            while (it.next()) |m| {
                if (for_rename and isRenamedOriginal(line, m.start(1), def_obj)) {
                    try file_refs.append(a, .{ .line = i, .start = m.start(1), .end = m.end(1) });
                    continue;
                }
                const var_def = (try definition.getDefinition(self, a, file, i, m.start(1) + 1, false)) orelse continue;
                if (var_def.kind == .intrinsic) continue;
                var ref_match = false;
                var in_cache = false;
                for (override_cache.items) |c| if (std.mem.eql(u8, c, var_def.fqsn)) {
                    in_cache = true;
                };
                if (std.mem.eql(u8, def_fqsn, var_def.fqsn) or in_cache or (for_rename and isImplicitResult(def_obj, var_def)) or
                    isSeparateProcedurePair(def_obj, var_def))
                {
                    ref_match = true;
                } else if (var_def.parent != null and var_def.parent.?.getType(false) == C.TypeId.class) {
                    if (type_mem) {
                        for (try var_def.parent.?.getOverridden(a, def_name)) |inherit_def| {
                            if (std.mem.eql(u8, def_fqsn, inherit_def.fqsn)) {
                                ref_match = true;
                                try override_cache.append(a, var_def.fqsn);
                                break;
                            }
                        }
                    }
                    if (!hasLinkAttr(var_def)) {
                        ref_match = false;
                    } else if (var_def.sline -| 1 == i and var_def.file_ast.path != null and
                        std.mem.eql(u8, var_def.file_ast.path.?, filename) and std.mem.count(u8, line, "=>") == 0 and
                        var_def.linkObj() == def_obj)
                    {
                        try override_cache.append(a, var_def.fqsn);
                        ref_match = true;
                    }
                } else if (def_obj.kind.isVariable() and def_obj.getType(true) == C.TypeId.method) {
                    if (def_obj.linkObj()) |l| if (l.parent) |lp| if (var_def.parent) |vp| {
                        if (std.mem.eql(u8, lp.fqsn, vp.fqsn)) {
                            ref_match = true;
                            try override_cache.append(a, var_def.fqsn);
                        }
                    };
                }
                if (ref_match) try file_refs.append(a, .{ .line = i, .start = m.start(1), .end = m.end(1) });
            }
        }
        if (file_refs.items.len > 0) try out.append(a, .{ .path = filename, .file = file, .refs = file_refs });
    }
    return out.items;
}

pub fn referenceScope(self: *Server, def_obj: *Obj) ?struct { type_mem: bool, restrict: ?*FortranFile } {
    _ = self;
    var type_mem = false;
    var restrict: ?*FortranFile = null;
    if (std.mem.count(u8, def_obj.fqsn, ":") > 2) {
        const parent = def_obj.parent orelse return null;
        // the implementation of a separate module procedure may be in
        // another file (hansec #168)
        if (parent.kind == .interface and def_obj.isModScope() and def_obj.linkObj() != null) return .{ .type_mem = false, .restrict = null };
        if (parent.getType(false) == C.TypeId.class) {
            type_mem = true;
        } else {
            restrict = def_obj.file_ast.file orelse return null;
        }
    }
    return .{ .type_mem = type_mem, .restrict = restrict };
}

pub fn serveReferences(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    if (try definition.operatorAt(self, a, params)) |op| return operators.references(self, a, op);
    if (try definition.constructAt(self, a, params)) |c| return json.from(a, try definition.constructLocations(a, try paths.pathToUri(a, c.file.path), c.file, c.target.spans));
    const d = (try definition.definitionAt(self, a, params, false)) orelse return .null;
    if (d.obj.kind == .intrinsic) return error.IntrinsicHasNoFQSN;
    const rs = referenceScope(self, d.obj) orelse return .null;
    const all = try getAllReferences(self, a, d.obj, rs.type_mem, rs.restrict, false);
    var out: std.ArrayList(lsp.Location) = .empty;
    for (all) |fr| {
        const uri = try paths.pathToUri(a, fr.path);
        for (fr.refs.items) |r| try out.append(a, Server.locationOf(uri, fr.file, r.line, r.start, r.line, r.end));
    }
    return json.from(a, out.items);
}

/// The name a rename at a position would change, or null where nothing
/// can be renamed (an intrinsic, a keyword, a name without definition)
pub fn servePrepareRename(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const line = params.position.line;
    const text = file.getLine(line, false) orelse return .null;
    const col = @min(Server.toByteCol(file, line, params.position.character), text.len);
    var s = col;
    while (s > 0 and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_')) s -= 1;
    var e = col;
    while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_')) e += 1;
    if (e == s) return .null;
    const ok = if (try definition.constructAt(self, a, params)) |_| true else if (try definition.definitionAt(self, a, params, false)) |d|
        d.obj.kind != .intrinsic and d.obj.file_ast.file != null
    else
        false;
    if (!ok) return .null;
    return json.from(a, lsp.PrepareRenameResult{ .range = Server.rangeOf(file, line, s, line, e), .placeholder = text[s..e] });
}

pub fn serveRename(self: *Server, a: Allocator, params: lsp.RenameParams) !Value {
    if (try definition.constructAt(self, a, .{ .textDocument = params.textDocument, .position = params.position })) |c| {
        return renameConstruct(self, a, params, c.file, c.target);
    }
    const d = (try definition.definitionAt(self, a, .{ .textDocument = params.textDocument, .position = params.position }, false)) orelse return .null;
    if (d.obj.kind == .intrinsic) {
        self.postMessage(a, "Rename failed: Cannot rename intrinsics", C.Severity.warn);
        return .null;
    }
    const all = if (try renamedImport(a, d.file, d.line, d.col, d.obj)) |ri|
        try aliasReferences(self, a, d.file, d.obj, ri)
    else blk: {
        const rs = referenceScope(self, d.obj) orelse return .null;
        break :blk try getAllReferences(self, a, d.obj, rs.type_mem, rs.restrict, true);
    };
    if (all.len == 0) {
        self.postMessage(a, "Rename failed: No usages found to rename", C.Severity.warn);
        return .null;
    }
    const files = try a.alloc(lsp.Changes.File, all.len);
    for (all, files) |fr, *f| {
        const edits = try a.alloc(lsp.TextEdit, fr.refs.items.len);
        for (fr.refs.items, edits) |r, *e| {
            e.* = .{ .range = Server.rangeOf(fr.file, r.line, r.start, r.line, r.end), .newText = params.newName };
        }
        f.* = .{ .uri = try paths.pathToUri(a, fr.path), .edits = edits };
    }
    return json.from(a, lsp.WorkspaceEdit{ .changes = .{ .files = files } });
}

/// Renames a construct name (to a Fortran name) or a statement label (to
/// one of up to five digits) everywhere in its program unit
pub fn renameConstruct(self: *Server, a: Allocator, params: lsp.RenameParams, file: *const FortranFile, t: constructs.Target) !Value {
    const new = params.newName;
    const valid = switch (t.kind) {
        .construct => new.len > 0 and std.ascii.isAlphabetic(new[0]) and
            for (new) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break false;
            } else true,
        .label => new.len > 0 and new.len <= 5 and std.mem.indexOfNone(u8, new, "0123456789") == null and
            (std.fmt.parseInt(u32, new, 10) catch 0) > 0,
    };
    if (!valid) {
        self.postMessage(a, try std.fmt.allocPrint(a, "Rename failed: \"{s}\" is not a valid {s}", .{ new, if (t.kind == .construct) "construct name" else "statement label" }), C.Severity.warn);
        return .null;
    }
    const edits = try a.alloc(lsp.TextEdit, t.spans.len);
    for (t.spans, edits) |s, *e| e.* = .{ .range = Server.rangeOf(file, s.line, s.start, s.line, s.end), .newText = new };
    const files = try a.alloc(lsp.Changes.File, 1);
    files[0] = .{ .uri = try paths.pathToUri(a, file.path), .edits = edits };
    return json.from(a, lsp.WorkspaceEdit{ .changes = .{ .files = files } });
}
