//! Preprocessor macros: go to definition, references and document
//! highlights, and hover on the names of directive lines (#265). A macro's
//! definition is the `#define` in effect at a use: the last one before it,
//! in the file or in a header that an `#include` before it reads, with no
//! `#undef` after it. Only preprocessed files have macros.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const regex = @import("../regex.zig");
const paths = @import("../paths.zig");
const parser = @import("../parser.zig");
const pp = @import("../preprocessor.zig");
const str = @import("../str.zig");
const objects = @import("../objects.zig");

const FortranFile = parser.FortranFile;
const Obj = objects.Obj;
const Value = json.Value;
const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// How deep `#include`s are followed
const max_depth = 16;

/// Where a macro is defined: the name in its `#define` line (0-based)
pub const Site = struct { path: []const u8, line: usize, start: usize, end: usize };

/// A macro's name at a position
pub const At = struct { file: *FortranFile, name: []const u8, line: usize, directive: bool };

/// The directive words that are no macro names
fn isDirectiveWord(w: []const u8) bool {
    const kws = [_][]const u8{ "define", "undef", "if", "ifdef", "ifndef", "elif", "else", "endif", "defined", "include", "error", "warning", "pragma", "line" };
    for (kws) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

/// The word of `text` around byte `col`
fn wordAround(text: []const u8, col: usize) ?helpers.Word {
    var it = helpers.words(text);
    while (it.next()) |w| {
        if (w.start <= col and col <= w.end) return w;
        if (w.start > col) break;
    }
    return null;
}

/// Whether byte `col` of a code line is outside its strings and comments
fn inCode(a: Allocator, file: *const FortranFile, text: []const u8, col: usize) !bool {
    if (helpers.isComment(file.fixed, text)) return false;
    const stripped = try helpers.stripStrings(a, text, true);
    if (col < stripped.len and (stripped[col] == '\'' or stripped[col] == '"')) return false;
    const end = std.mem.findScalar(u8, stripped, '!') orelse stripped.len;
    if (col >= end) return false;
    // inside a string: the blanks stripStrings left differ from the text
    return col >= text.len or stripped[col] == text[col];
}

/// The macro whose name is at byte `col` of line `line` of `file`, if any:
/// a name that `file`'s preprocessing defines, `pp_defs`, or a `#define`
/// before it, in code or in a directive's line
pub fn at(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !?At {
    if (!file.preproc) return null;
    const text = file.getLine(line, false) orelse return null;
    const w = wordAround(text, col) orelse return null;
    const directive = helpers.isPpDirective(text);
    if (directive) {
        if (R().INCLUDE_DIRECTIVE.match(text) != null) return null;
        if (isDirectiveWord(w.str)) return null;
    } else if (!try inCode(a, file, text, w.start)) return null;
    // a macro that an #undef removes before the end of the file is not in
    // the file's macros: then its #define says
    const known = file.pp_defs.contains(w.str) or self.pp_defs.contains(w.str) or
        (undefines(file, w.str) and (try site(self, a, file, w.str, limitOf(file, line))) != null);
    if (!known) return null;
    return .{ .file = file, .name = w.str, .line = line, .directive = directive };
}

/// Whether `file` has an `#undef` of `name`
fn undefines(file: *const FortranFile, name: []const u8) bool {
    for (0..file.nLines()) |ln| {
        const text = file.getLine(ln, false) orelse continue;
        if (std.mem.find(u8, text, name) == null) continue;
        const m = R().PP_DEF.match(text) orelse continue;
        if (!std.ascii.eqlIgnoreCase(m.group(1).?, "define") and std.mem.eql(u8, m.group(2).?, name)) return true;
    }
    return false;
}

/// The lines whose directives give the #define in effect at line `line`:
/// those up to it, or before it for an `#undef` (which hover and definition
/// show the #define of)
fn limitOf(file: *const FortranFile, line: usize) usize {
    const text = file.getLine(line, false) orelse return line + 1;
    const m = R().PP_DEF.match(text) orelse return line + 1;
    return if (std.ascii.eqlIgnoreCase(m.group(1).?, "define")) line + 1 else line;
}

/// `at` for a request's position
pub fn atPosition(self: *Server, a: Allocator, params: lsp.PositionParams) !?At {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const line = params.position.line;
    return at(self, a, file, line, Server.toByteCol(file, line, params.position.character));
}

/// The text of a file that a macro search reads: the workspace's, or else
/// the file on disk (a header that is not a source)
fn source(self: *Server, a: Allocator, path: []const u8) !?*FortranFile {
    if (self.workspace.get(path)) |f| return f;
    const f = try FortranFile.create(a, path, &.{});
    if (f.loadFromDisk(self.io)) |_| {} else |_| return null;
    return f;
}

/// The file that `#include` of `name` in a file of directory `dir` reads:
/// next to it, else in the include directories
fn resolve(self: *Server, a: Allocator, dir: []const u8, name: []const u8) !?[]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.append(a, dir);
    try dirs.appendSlice(a, try definition.includeDirs(self, a));
    for (dirs.items) |d| {
        const candidate = try paths.abspath(a, try paths.join(a, &.{ d, name }));
        if (paths.isFile(self.io, candidate)) return candidate;
    }
    return null;
}

/// Whether line `ln` (0-based) is in a branch that the preprocessor leaves
/// out (`pp.Skip`s run from the directive that starts it to the one that
/// ends it)
fn skipped(file: *const FortranFile, ln: usize) bool {
    for (file.pp_skips) |s| if (ln + 1 > s.start and ln + 1 < s.end) return true;
    return false;
}

const Walk = struct {
    self: *Server,
    a: Allocator,
    name: []const u8,
    found: ?Site = null,

    /// The `#define`s and `#undef`s of `name` in lines `0..upto` of `file`,
    /// and in the headers that its `#include`s read, in order
    fn lines(w: *Walk, file: *const FortranFile, upto: usize, depth: usize) !void {
        const n = @min(upto, file.nLines());
        for (0..n) |ln| {
            if (skipped(file, ln)) continue;
            const text = file.getLine(ln, false) orelse continue;
            if (!helpers.isPpDirective(text)) continue;
            if (R().PP_DEF.match(text)) |m| {
                if (!std.mem.eql(u8, m.group(2).?, w.name)) continue;
                if (std.ascii.eqlIgnoreCase(m.group(1).?, "define")) {
                    w.found = .{ .path = file.path, .line = ln, .start = m.start(2), .end = m.end(2) };
                } else w.found = null;
                continue;
            }
            if (depth >= max_depth) continue;
            const inc = R().INCLUDE_DIRECTIVE.match(text) orelse continue;
            const path = (try resolve(w.self, w.a, paths.dirname(file.path), inc.group(1).?)) orelse continue;
            const header = (try source(w.self, w.a, path)) orelse continue;
            try w.lines(header, std.math.maxInt(usize), depth + 1);
        }
    }
};

/// The `#define` of `name` in effect before line `upto` (0-based,
/// excluded) of `file`; null for a macro of `pp_defs`, `-D` or none
pub fn site(self: *Server, a: Allocator, file: *const FortranFile, name: []const u8, upto: usize) !?Site {
    var w: Walk = .{ .self = self, .a = a, .name = name };
    try w.lines(file, upto, 0);
    return w.found;
}

/// The location of the definition of the macro at a position (null: a
/// macro without `#define`)
pub fn definitionOf(self: *Server, a: Allocator, m: At) !Value {
    const s = (try site(self, a, m.file, m.name, limitOf(m.file, m.line))) orelse return .null;
    const f = (try source(self, a, s.path)) orelse return .null;
    return json.from(a, Server.locationOf(try paths.pathToUri(a, s.path), f, s.line, s.start, s.line, s.end));
}

/// A macro's description for hover: `#define NAME(args) value`
pub fn describe(a: Allocator, name: []const u8, d: pp.Def) ![]const u8 {
    var arg_str: []const u8 = "";
    if (d.args) |args| {
        var parts: std.ArrayList([]const u8) = .empty;
        for (try str.split(a, args, ",")) |p| try parts.append(a, str.strip(p));
        arg_str = try a.print("({s})", .{try std.mem.join(a, ", ", parts.items)});
    }
    return a.print("#define {s}{s} {s}", .{ name, arg_str, d.value });
}

/// The object hover shows for a macro named in a directive's line
/// (`#ifdef X`, `#undef X`): as for one in code
pub fn directiveObj(self: *Server, a: Allocator, m: At) !?*Obj {
    const ast = m.file.ast orelse return null;
    const d = m.file.pp_defs.get(m.name) orelse self.pp_defs.get(m.name) orelse blk: {
        // one that is #undef'd at the end of the file: as its #define says
        const s = (try site(self, a, m.file, m.name, limitOf(m.file, m.line))) orelse return null;
        const f = (try source(self, a, s.path)) orelse return null;
        const text = f.getLine(s.line, false) orelse return null;
        const pm = R().PP_DEF.match(text) orelse return null;
        break :blk pp.Def{ .args = pm.group(4), .value = str.strip(text[pm.end(0)..]) };
    };
    return try definition.tempVariable(a, ast, m.line + 1, m.name, try describe(a, m.name, d), &.{});
}

/// The places of `name` in `file`: as a word of its directives' lines, and
/// of its code outside strings and comments
fn placesIn(a: Allocator, file: *const FortranFile, name: []const u8, out: *std.ArrayList(lsp.Location)) !void {
    const uri = try paths.pathToUri(a, file.path);
    for (0..file.nLines()) |ln| {
        const text = file.getLine(ln, false) orelse continue;
        if (std.mem.find(u8, text, name) == null) continue;
        const directive = helpers.isPpDirective(text);
        if (directive and R().INCLUDE_DIRECTIVE.match(text) != null) continue;
        var it = helpers.words(text);
        while (it.next()) |w| {
            if (!std.mem.eql(u8, w.str, name)) continue;
            if (!directive and !try inCode(a, file, text, w.start)) continue;
            try out.append(a, Server.locationOf(uri, file, ln, w.start, ln, w.end));
        }
    }
}

/// Whether the `#include`s of `file` reach `header`
fn reaches(self: *Server, a: Allocator, file: *const FortranFile, header: []const u8, depth: usize) !bool {
    if (depth >= max_depth) return false;
    for (0..file.nLines()) |ln| {
        const text = file.getLine(ln, false) orelse continue;
        const inc = R().INCLUDE_DIRECTIVE.match(text) orelse continue;
        const path = (try resolve(self, a, paths.dirname(file.path), inc.group(1).?)) orelse continue;
        if (std.mem.eql(u8, path, header)) return true;
        const f = (try source(self, a, path)) orelse continue;
        if (try reaches(self, a, f, header, depth + 1)) return true;
    }
    return false;
}

/// References of the macro at a position (`all_files`), or its document
/// highlights: its places in the file, and, for one a header defines, in
/// that header and in the workspace's files whose `#include`s reach it
pub fn references(self: *Server, a: Allocator, m: At, all_files: bool) !Value {
    var out: std.ArrayList(lsp.Location) = .empty;
    try placesIn(a, m.file, m.name, &out);
    if (all_files) if (try site(self, a, m.file, m.name, limitOf(m.file, m.line))) |s| if (!std.mem.eql(u8, s.path, m.file.path)) {
        if (try source(self, a, s.path)) |header| {
            if (self.workspace.get(s.path) == null) try placesIn(a, header, m.name, &out);
        }
        for (self.workspace.values()) |f| {
            if (f == m.file) continue;
            if (std.mem.eql(u8, f.path, s.path) or (f.preproc and try reaches(self, a, f, s.path, 0))) try placesIn(a, f, m.name, &out);
        }
    };
    return json.from(a, out.items);
}
