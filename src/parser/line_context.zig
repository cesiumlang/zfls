//! Part of reading definitions (definitions.zig): what the end of a line
//! is about, for completion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const definitions = @import("definitions.zig");
const E = definitions.E;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const readVarDef = definitions.readVarDef;
const readUseStmt = definitions.readUseStmt;

pub const LineContext = enum {
    var_key,
    pro_line,
    var_only,
    mod_mems,
    mod_only,
    pro_link,
    skip,
    import,
    vis,
    call,
    type_only,
    int_only,
    first,
    default,
};

/// Get context of ending position in line (for completion)
pub fn getLineContext(a: Allocator, line: []const u8) E!struct { ctx: LineContext, info: ?[]const u8 = null } {
    const pl = try helpers.getParenLevel(a, line);
    const last_level = pl.str;
    const sections = pl.sections;
    const lev1_end = sections[sections.len - 1].end;
    const line_len: isize = @intCast(line.len);
    if (try readVarDef(a, line, null, false)) |tm| {
        if (tm == .var_) {
            const v = tm.var_;
            if (v.var_names == null and lev1_end == line_len) return .{ .ctx = .var_key };
            if (std.mem.eql(u8, v.var_type, "PROCEDURE") and (std.mem.find(u8, line, "=>") orelse 0) > 0) return .{ .ctx = .pro_link };
            return .{ .ctx = .var_only };
        }
    }
    if (try readUseStmt(a, line)) |u| {
        if (u.use.only_list.len > 0) return .{ .ctx = .mod_mems, .info = u.use.mod_name };
        return .{ .ctx = .mod_only };
    }
    if (R().PRO_LINK.match(line) != null) return .{ .ctx = .pro_link };
    if (R().SCOPE_DEF.match(line) != null or R().END.match(line) != null) return .{ .ctx = .skip };
    if (R().IMPORT.match(line) != null) return .{ .ctx = .import };
    if (R().VIS.match(line) != null) return .{ .ctx = .vis };
    const type_def = R().TYPE_DEF.match(line) != null;
    if (lev1_end == line_len and R().CALL.match(last_level) != null) return .{ .ctx = .call };
    if (sections.len == 1 and sections[0].start >= 1) {
        const up = try helpers.getParenLevel(a, str.slice(line, 0, sections[0].start - 1));
        const test_str = up.str;
        if (R().TYPE_STMNT.match(test_str) != null or (type_def and R().EXTENDS.search(test_str) != null)) {
            return .{ .ctx = .type_only };
        }
        if (R().PROCEDURE_STMNT.match(test_str) != null) return .{ .ctx = .int_only };
    }
    if (R().INT_STMNT.match(line) != null) return .{ .ctx = .first };
    if (type_def) return .{ .ctx = .skip };
    return .{ .ctx = .default };
}
