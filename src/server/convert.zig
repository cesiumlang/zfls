//! Converting a file between fixed and free form with findent (#279): the
//! request `zfls/convertForm` answers the converted text of a document, and
//! a `source` code action creates the free-form file for clients that can
//! create files. The source form comes from the file's extension, so the
//! converted text belongs in a file with another one; the old file is left.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const parser = @import("../parser.zig");

const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const format = @import("format.zig");
const Formatter = format.Formatter;

/// The form to convert to
pub const Form = enum { free, fixed };

/// findent's arguments for a conversion to `to`: the user's findent
/// arguments of the source form first, then the input and output forms,
/// which findent takes last
pub fn findentArgs(a: Allocator, to: Form, user: []const []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, user);
    try args.appendSlice(a, switch (to) {
        .free => &.{ "-ifixed", "-ofree" },
        .fixed => &.{ "-ifree", "-ofixed" },
    });
    return args.items;
}

/// The path of the converted file: the same name, with `.f90` for free
/// form and `.f` for fixed form (`.F90`/`.F` for a preprocessed one)
pub fn convertedPath(a: Allocator, path: []const u8, to: Form) ![]const u8 {
    const ext = std.Io.Dir.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    // an upper-case extension (`.F`, `.FOR`): a preprocessed file
    const upper = ext.len > 1 and std.ascii.isUpper(ext[1]);
    const new_ext = switch (to) {
        .free => if (upper) ".F90" else ".f90",
        .fixed => if (upper) ".F" else ".f",
    };
    return std.mem.concat(a, u8, &.{ stem, new_ext });
}

/// The user's findent arguments for files of the source form, when findent
/// is the formatter of that form
fn userArgs(self: *const Server, from_fixed: bool) []const []const u8 {
    if (from_fixed and self.s.formatter_fixed != null) {
        return if (Formatter.fromName(self.s.formatter_fixed) == .findent) self.s.formatter_fixed_args.slice() else &.{};
    }
    return if (Formatter.fromName(self.s.formatter) == .findent) self.s.formatter_args.slice() else &.{};
}

/// The findent executables to try: `formatter_path` when findent is the
/// formatter (or when it is a directory, which may hold findent too), else
/// `findent` on the PATH
fn executables(self: *Server, a: Allocator) ![]const []const u8 {
    const uses_findent = Formatter.fromName(self.s.formatter) == .findent or Formatter.fromName(self.s.formatter_fixed) == .findent;
    const configured = std.mem.trim(u8, self.s.formatter_path orelse "", " ");
    if (configured.len > 0) {
        const p = if (std.Io.Dir.path.isAbsolute(configured)) configured else try paths.join(a, &.{ self.root_path, configured });
        if (uses_findent or paths.isDir(self.io, p)) return format.executables(self, a, .findent);
    }
    return a.dupe([]const u8, &.{"findent"});
}

pub const Result = union(enum) { text: []const u8, err: []const u8 };

/// The text of `file`, as the editor has it, converted to `to` by findent
pub fn convert(self: *Server, a: Allocator, file: *const FortranFile, to: Form) !Result {
    const args = try findentArgs(a, to, userArgs(self, to == .free));
    var input: std.ArrayList(u8) = .empty;
    for (file.editLines()) |l| {
        try input.appendSlice(a, l);
        try input.append(a, '\n');
    }
    const dir = paths.dirname(file.path);
    const cwd: ?[]const u8 = if (paths.isDir(self.io, dir)) dir else null;
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(format.timeout_s), .clock = .awake } };
    const run: format.Run = for (try executables(self, a)) |exe| {
        const argv = try a.alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        self.log.debug("[convert] {s} {s}", .{ exe, try std.mem.join(a, " ", args) });
        break format.runWithInput(a, self.io, argv, cwd, self.toolEnv(), input.items, timeout) catch |e| switch (e) {
            error.FileNotFound => continue,
            error.OutOfMemory => return e,
            else => return .{ .err = try a.print("running findent failed ({s})", .{@errorName(e)}) },
        };
    } else return .{ .err = try a.print("findent was not found. Install it with {s}, or set formatter_path to it", .{Formatter.findent.installHint()}) };
    const stderr = std.mem.trim(u8, run.stderr, " \t\r\n");
    if (!run.term.success()) {
        return .{ .err = try a.print("findent {f}{s}{s}", .{ run.term, if (stderr.len > 0) ": " else "", stderr }) };
    }
    if (std.mem.trim(u8, run.stdout, " \t\r\n").len == 0 and std.mem.trim(u8, input.items, " \t\r\n").len > 0) {
        return .{ .err = try a.print("findent printed nothing{s}{s}", .{ if (stderr.len > 0) ": " else "", stderr }) };
    }
    // the line ends of the output as one: `\n`
    return .{ .text = try std.mem.replaceOwned(u8, a, run.stdout, "\r\n", "\n") };
}

pub const Params = struct {
    textDocument: lsp.TextDocumentIdentifier,
    to: []const u8,
};

/// `zfls/convertForm`: `{ text, path }`, the converted text and the path
/// it belongs in, or `{ error }`
pub fn serveConvertForm(self: *Server, a: Allocator, params: Params) !Value {
    const to = std.meta.stringToEnum(Form, params.to) orelse return error.InvalidParams;
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return json.from(a, .{ .@"error" = "the document is not a Fortran file of the workspace" });
    return switch (try convert(self, a, file, to)) {
        .text => |t| json.from(a, .{ .text = t, .path = try convertedPath(a, file.path, to) }),
        .err => |e| json.from(a, .{ .@"error" = e }),
    };
}

/// Whether the client can create files with a workspace edit
pub fn clientCreatesFiles(self: *const Server) bool {
    for (self.config.client.workspace.workspaceEdit.resourceOperations) |op| if (std.mem.eql(u8, op, "create")) return true;
    return false;
}

/// What `codeAction/resolve` knows the conversion's action by (#984)
pub const resolve_kind = "convertToFreeForm";

/// The action that creates the free-form version of a fixed-form `file`,
/// for a client that creates files; null otherwise, or when findent fails.
/// For a client that resolves actions (#984), and unless `resolved`, without
/// its edit: findent runs when the action is chosen.
pub fn freeFormAction(self: *Server, a: Allocator, file: *const FortranFile, resolved: bool) !?lsp.CodeAction {
    if (!file.fixed or !clientCreatesFiles(self)) return null;
    const new_name = std.Io.Dir.path.basename(try convertedPath(a, file.path, .free));
    const title = try a.print("Convert to free form (new file {s})", .{new_name});
    if (self.code_action_resolve and !resolved) return .{
        .title = title,
        .kind = "source.convertToFreeForm",
        .data = try json.from(a, .{ .resolve = resolve_kind, .uri = try paths.pathToUri(a, file.path) }),
    };
    const text = switch (try convert(self, a, file, .free)) {
        .text => |t| t,
        .err => |e| {
            self.log.warn("[convert] {s}", .{e});
            return null;
        },
    };
    const new_path = try convertedPath(a, file.path, .free);
    const uri = try paths.pathToUri(a, new_path);
    const start: lsp.Position = .{ .line = 0, .character = 0 };
    const changes = try json.from(a, &[_]Value{
        try json.from(a, .{ .kind = "create", .uri = uri, .options = .{ .overwrite = false, .ignoreIfExists = true } }),
        try json.from(a, .{
            .textDocument = .{ .uri = uri, .version = @as(?i64, null) },
            .edits = &[_]lsp.TextEdit{.{ .range = .{ .start = start, .end = start }, .newText = text }},
        }),
    });
    return .{
        .title = title,
        .kind = "source.convertToFreeForm",
        .edit = .{ .documentChanges = changes },
    };
}

const testing = std.testing;

fn expectArgs(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, x| try testing.expectEqualStrings(e, x);
}

test "findent converts with the input and output forms last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgs(&.{ "-ifixed", "-ofree" }, try findentArgs(a, .free, &.{}));
    try expectArgs(&.{ "-i4", "-ifree", "-ofixed" }, try findentArgs(a, .fixed, &.{"-i4"}));
}

test "the converted file's name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/w/old.f90", try convertedPath(a, "/w/old.f", .free));
    try testing.expectEqualStrings("/w/old.f90", try convertedPath(a, "/w/old.for", .free));
    try testing.expectEqualStrings("/w/OLD.F90", try convertedPath(a, "/w/OLD.F", .free));
    try testing.expectEqualStrings("/w/new.f", try convertedPath(a, "/w/new.f90", .fixed));
    try testing.expectEqualStrings("/w/new.F", try convertedPath(a, "/w/new.F90", .fixed));
}
