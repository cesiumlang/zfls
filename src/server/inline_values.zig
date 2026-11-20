//! Inline values while debugging (#195): where the editor shows the values
//! of variables at the end of the lines above a stop.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const objects = @import("../objects.zig");

const Obj = objects.Obj;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const modvars = @import("modvars.zig");

/// `textDocument/inlineValue`: in the visible range, up to the line the
/// debugger stopped at, a variable lookup at each use of a variable the
/// procedure (or program) that holds the stop can see: its locals and dummy
/// arguments, its host procedures', and the module variables the line sees
/// (`zfls/moduleVariables`, under their local names, as `zfls dap` lists
/// them). Named constants, procedures and types are left out; the editor
/// asks the debug adapter for the values, by name.
pub fn serveInlineValues(self: *Server, a: Allocator, params: lsp.InlineValueParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const stop = params.context.stoppedLocation.start.line;
    var unit = ast.getInnerScope(stop + 1) orelse return .null;
    while (!(unit.kind.isSubroutine() or unit.kind == .program)) unit = unit.parent orelse return .null;

    var names: std.StringHashMapUnmanaged(void) = .empty;
    // the procedure's own, and its hosts' up to the module
    var scope: ?*Obj = unit;
    while (scope) |s| : (scope = s.parent) {
        if (s.kind == .module or s.kind == .submodule) break;
        for (s.childList()) |c| if (c.kind == .variable and !c.isParameter() and !c.isGroup())
            try names.put(a, try std.ascii.allocLowerString(a, c.name), {});
    }
    for (try modvars.visibleModuleVariables(self, a, ast, stop)) |v|
        try names.put(a, try std.ascii.allocLowerString(a, v.local), {});

    var out: std.ArrayList(lsp.InlineValueVariableLookup) = .empty;
    const first = @max(params.range.start.line, unit.sline -| 1);
    const last = @min(stop, params.range.end.line);
    var line = first;
    while (line <= last) : (line += 1) {
        const raw = file.getLine(line, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        var text = try helpers.stripStrings(a, raw, true);
        if (std.mem.findScalar(u8, text, '!')) |i| text = text[0..i];
        var it = helpers.words(text);
        while (it.next()) |w| {
            // a component (`a%b`) is not the variable `b`
            if (w.start > 0 and text[w.start - 1] == '%') continue;
            const lower = try std.ascii.allocLowerString(a, w.str);
            if (!names.contains(lower)) continue;
            try out.append(a, .{
                .range = Server.rangeOf(file, line, w.start, line, w.end),
                .variableName = w.str,
            });
        }
    }
    return json.from(a, out.items);
}
