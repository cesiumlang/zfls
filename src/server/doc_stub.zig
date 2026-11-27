//! A documentation comment written from a procedure's arguments (#982): a
//! code action on the SUBROUTINE or FUNCTION statement of a procedure that
//! has none. `!>` lines before it, as zfls and FORD read them; Doxygen's
//! tags (`@brief`, `@param[in]`, `@return`) in a file that uses them.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const helpers = @import("../helpers.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const srv = @import("../server.zig");
const Server = srv.Server;
const code_actions = @import("code_actions.zig");

/// The actions for the procedures whose first line is in lines `sline` to
/// `eline` (0-based) and that have no documentation
pub fn addDocStubActions(self: *Server, a: Allocator, file: *FortranFile, ast: *objects.Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    _ = self;
    const doxygen = usesDoxygen(file);
    for (ast.scope_list.items) |sc| {
        if (sc.kind != .subroutine and sc.kind != .function) continue;
        if (sc.sline == 0 or sc.sline - 1 < sline or sc.sline - 1 > eline) continue;
        if (sc.getDocumentation()) |d| if (std.mem.trim(u8, d, " \t\r\n").len > 0) continue;
        const at = sc.sline - 1;
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(file, at, 0, at, 0), .newText = try stub(a, file, sc, doxygen) };
        try out.append(a, try code_actions.action(a, try paths.pathToUri(a, file.path), try a.print("Add a documentation comment to {s}", .{sc.name}), "refactor.rewrite", edits));
    }
}

/// Whether a comment of `file` has a Doxygen tag
fn usesDoxygen(file: *const FortranFile) bool {
    for (0..file.nLines()) |i| {
        const line = file.getLine(i, false) orelse continue;
        const bang = std.mem.findScalar(u8, line, '!') orelse continue;
        const comment = line[bang..];
        for ([_][]const u8{ "@brief", "@param", "@return", "\\brief", "\\param" }) |tag| {
            if (std.mem.find(u8, comment, tag) != null) return true;
        }
    }
    return false;
}

/// The comment's lines for procedure `proc`, at its statement's indent
fn stub(a: Allocator, file: *const FortranFile, proc: *const Obj, doxygen: bool) ![]const u8 {
    const raw = file.getLine(proc.sline - 1, false) orelse "";
    // fixed form: from column 1, where a `!` is always a comment
    const indent = if (file.fixed) "" else raw[0 .. raw.len - std.mem.trimStart(u8, raw, " \t").len];
    var out: std.ArrayList(u8) = .empty;
    if (doxygen) try out.print(a, "{s}!> @brief {s}\n", .{ indent, proc.name }) else try out.print(a, "{s}!> {s}\n{s}!>\n", .{ indent, proc.name, indent });
    for (proc.procDataConst().arg_objs.items) |arg_opt| {
        const arg = arg_opt orelse continue;
        const desc = try declaration(a, arg);
        if (doxygen) {
            try out.print(a, "{s}!> @param{s} {s} {s}\n", .{ indent, direction(arg), arg.name, desc });
        } else try out.print(a, "{s}!> - {s}: {s}\n", .{ indent, arg.name, desc });
    }
    if (proc.kind == .function) {
        const result = proc.procDataConst().result_type orelse "";
        if (doxygen) {
            try out.print(a, "{s}!> @return {s}\n", .{ indent, result });
        } else if (result.len > 0) try out.print(a, "{s}!> Returns {s}\n", .{ indent, result });
    }
    return out.items;
}

/// A dummy argument's type and attributes: `REAL(8), INTENT(IN)`
fn declaration(a: Allocator, arg: *const Obj) ![]const u8 {
    const desc = try arg.getDescNoLink(a);
    const keywords = try helpers.getKeywords(a, arg.keywords.items, arg.keyword_info.*);
    if (keywords.len == 0) return desc;
    return std.mem.concat(a, u8, &.{ desc, ", ", try std.mem.join(a, ", ", keywords) });
}

/// Doxygen's direction of a dummy argument, by its INTENT
fn direction(arg: *const Obj) []const u8 {
    const intent = arg.keyword_info.intent orelse return "";
    if (std.ascii.eqlIgnoreCase(intent, "in")) return "[in]";
    if (std.ascii.eqlIgnoreCase(intent, "out")) return "[out]";
    return "[in,out]";
}
