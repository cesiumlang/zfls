//! Renamed and moved files (#198): the INCLUDE statements and `#include`
//! directives that name them, rewritten before the editor renames them.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const patterns = @import("../patterns.zig");
const parser = @import("../parser.zig");

const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");

fn R() *const patterns.Patterns {
    return patterns.get();
}

const Move = struct { old: []const u8, new: []const u8 };

/// `workspace/willRenameFiles`: for every include, in a workspace file,
/// of a file that moves (itself, or a directory it is in), or in a file
/// that moves, the name it would have after the moves, relative as it was:
/// to the including file's directory when it was found there, else to the
/// include directory it was found in (or, when the new place is outside
/// that directory, to the including file's directory); absolute names stay
/// absolute
pub fn serveWillRenameFiles(self: *Server, a: Allocator, params: lsp.RenameFilesParams) !Value {
    var moves: std.ArrayList(Move) = .empty;
    for (params.files) |f| try moves.append(a, .{
        .old = try paths.abspath(a, try self.pathFromUri(a, f.oldUri)),
        .new = try paths.abspath(a, try self.pathFromUri(a, f.newUri)),
    });
    const include_dirs = try definition.includeDirs(self, a);
    var files: std.ArrayList(lsp.Changes.File) = .empty;
    for (self.workspace.values()) |file| {
        var edits: std.ArrayList(lsp.TextEdit) = .empty;
        const file_dir = paths.dirname(file.path);
        const new_dir = paths.dirname((try movedTo(a, moves.items, file.path)) orelse file.path);
        for (0..file.nLines()) |i| {
            const text = file.getLine(i, false) orelse continue;
            const m = R().INCLUDE_DIRECTIVE.match(text) orelse R().INCLUDE.match(text) orelse continue;
            const name = m.group(1).?;
            const found = (try findIn(self, a, file_dir, include_dirs, name)) orelse continue;
            const target_moved = try movedTo(a, moves.items, found.path);
            if (target_moved == null and std.mem.eql(u8, new_dir, file_dir)) continue;
            const target = target_moved orelse found.path;
            const new_name: []const u8 = blk: {
                if (std.Io.Dir.path.isAbsolute(name)) break :blk target;
                if (found.dir) |d| {
                    // found in an include directory: only its file's move matters
                    if (target_moved == null) continue;
                    if (isUnder(target, d)) break :blk try relative(a, d, target);
                }
                break :blk try relative(a, new_dir, target);
            };
            if (std.mem.eql(u8, new_name, name)) continue;
            try edits.append(a, .{ .range = Server.rangeOf(file, i, m.start(1), i, m.end(1)), .newText = new_name });
        }
        if (edits.items.len > 0) try files.append(a, .{ .uri = try paths.pathToUri(a, file.path), .edits = edits.items });
    }
    if (files.items.len == 0) return .null;
    return json.from(a, lsp.WorkspaceEdit{ .changes = .{ .files = files.items } });
}

/// Where `path` is after the moves: a move of the file itself, or of a
/// directory it is in
fn movedTo(a: Allocator, moves: []const Move, path: []const u8) !?[]const u8 {
    for (moves) |mv| {
        if (paths.eql(path, mv.old)) return mv.new;
        // the rest after the directory, with its separator
        if (isUnder(path, mv.old)) return try std.mem.concat(a, u8, &.{ mv.new, path[mv.old.len..] });
    }
    return null;
}

/// The file an include of `name` reads, and the include directory it was
/// found in (null: next to the including file)
fn findIn(self: *Server, a: Allocator, file_dir: []const u8, include_dirs: []const []const u8, name: []const u8) !?struct { path: []const u8, dir: ?[]const u8 } {
    const local = try paths.abspath(a, try paths.join(a, &.{ file_dir, name }));
    if (paths.isFile(self.io, local)) return .{ .path = local, .dir = null };
    for (include_dirs) |d| {
        const candidate = try paths.abspath(a, try paths.join(a, &.{ d, name }));
        if (paths.isFile(self.io, candidate)) return .{ .path = candidate, .dir = try paths.abspath(a, d) };
    }
    return null;
}

/// `to` from directory `from`, with forward slashes, as include names are
/// written
fn relative(a: Allocator, from: []const u8, to: []const u8) ![]const u8 {
    const rel = try std.Io.Dir.path.relativeAlloc(a, paths.getCwd(), null, from, to);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    return rel;
}

const isUnder = paths.isUnder;
