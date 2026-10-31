//! Reading the definition on a line (port of the `read_*_def` functions of
//! fortls): variables, procedures, modules, types, constructs, USE and IMPORT
//! statements, and what a line is about for completion.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const regex = @import("../regex.zig");
const objects = @import("../objects.zig");

fn R() *const patterns.Patterns {
    return patterns.get();
}

const parser = @import("../parser.zig");

pub const ResultSig = struct {
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
};

pub const VarInfo = struct {
    var_type: []const u8,
    keywords: []const []const u8,
    var_names: ?[]const []const u8,
    var_kind: ?[]const u8 = null,
};

pub const SubInfo = struct {
    name: []const u8,
    args: []const u8,
    keywords: []const []const u8 = &.{},
    mod_flag: bool = false,
};

pub const FunSig = struct {
    name: []const u8,
    args: []const u8,
    keywords: []const []const u8 = &.{},
    mod_flag: bool = false,
    result: ResultSig = .{},
};

pub const SelectInfo = struct { type: i32, binding: ?[]const u8, desc: ?[]const u8 };

pub const ClassInfo = struct { name: []const u8, parent: ?[]const u8, keywords: []const []const u8 };

pub const GenProcDefInfo = struct { bound_name: []const u8, pro_links: []const []const u8, vis_flag: objects.Vis };

/// `SUBMODULE (ancestor[:parent]) name`
pub const SmodInfo = struct { name: []const u8, ancestor: []const u8, parent: []const u8 };

pub const InterInfo = struct { name: ?[]const u8, abstract: bool };

pub const VisInfo = struct { private: bool, obj_names: []const []const u8 };

pub const UseInfo = struct {
    mod_name: []const u8,
    only_list: []const []const u8,
    renames: []const [2][]const u8,
};

pub const ImportInfo = struct {
    import_type: objects.ImportType,
    only_list: []const []const u8 = &.{},
};

pub const DefResult = union(enum) {
    var_: VarInfo,
    sub: SubInfo,
    fun: FunSig,
    block: ?[]const u8,
    block_data: ?[]const u8,
    do_: []const u8,
    where: bool,
    if_,
    assoc: []const []const u8,
    select: SelectInfo,
    typ: ClassInfo,
    enum_,
    use: UseInfo,
    import: ImportInfo,
    int: InterInfo,
    gen: GenProcDefInfo,
    int_pro: []const []const u8,
    mod: []const u8,
    prog: []const u8,
    smod: SmodInfo,
    inc: []const u8,
    vis: VisInfo,
};

pub const E = Allocator.Error;

pub fn lstripChars(s: []const u8, chars: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, chars);
}

/// Parse Fortran variable declaration keywords
pub fn parseVarKeywords(a: Allocator, test_str_in: []const u8) E!struct { keywords: []const []const u8, rest: []const u8 } {
    var test_str = test_str_in;
    var keywords: std.ArrayList([]const u8) = .empty;
    var keyword_match = R().KEYWORD_LIST.match(test_str);
    while (keyword_match) |m| {
        var tmp_str: []const u8 = lstripChars(m.str(), ", ");
        test_str = test_str[m.end(0)..];
        if (std.ascii.startsWithIgnoreCase(tmp_str, "codimension")) {
            // the cobounds, up to the matching `]`
            var depth: usize = 1;
            const close = for (test_str, 0..) |ch, i| {
                if (ch == '[') depth += 1;
                if (ch == ']') {
                    depth -= 1;
                    if (depth == 0) break i;
                }
            } else break;
            tmp_str = try std.mem.concat(a, u8, &.{ tmp_str, test_str[0 .. close + 1] });
            test_str = test_str[close + 1 ..];
        } else if (std.ascii.startsWithIgnoreCase(tmp_str, "dimension")) {
            const mc = helpers.findParenMatch(test_str);
            if (mc < 0) break;
            const mcu: usize = @intCast(mc);
            tmp_str = try std.mem.concat(a, u8, &.{ tmp_str, test_str[0 .. mcu + 1] });
            test_str = test_str[mcu + 1 ..];
        }
        tmp_str = lstripChars(tmp_str, ", ");
        try keywords.append(a, try std.ascii.allocUpperString(a, str.strip(tmp_str)));
        keyword_match = R().KEYWORD_LIST.match(test_str);
    }
    return .{ .keywords = keywords.items, .rest = test_str };
}

pub const KindResult = struct { kind: ?[]const u8, line: []const u8 };

pub fn parseKind(a: Allocator, line: []const u8) E!?KindResult {
    const m = R().KIND_SPEC.match(line) orelse return .{ .kind = null, .line = line };
    var kind_str: []const u8 = try std.mem.replaceOwned(u8, a, m.group(1).?, " ", "");
    var rest = line[m.end(0)..];
    if (std.mem.indexOfScalar(u8, kind_str, '(') != null) {
        const mc = helpers.findParenMatch(rest);
        if (mc < 0) return null; // Incomplete kind specification
        const mcu: usize = @intCast(mc);
        kind_str = try std.mem.concat(a, u8, &.{ kind_str, str.strip(rest[0 .. mcu + 1]) });
        rest = rest[mcu + 1 ..];
    }
    return .{ .kind = kind_str, .line = rest };
}

/// Attempt to read variable definition line
pub fn readVarDef(a: Allocator, line: []const u8, var_type_in: ?[]const u8, fun_only: bool) E!?DefResult {
    var var_type: []const u8 = undefined;
    var trailing: []const u8 = undefined;
    if (var_type_in) |vt| {
        var_type = vt;
        trailing = str.from(line, vt.len);
    } else {
        const tm = R().VAR.match(line) orelse return null;
        var_type = str.strip(tm.str());
        trailing = line[tm.end(0)..];
    }
    var_type = try std.ascii.allocUpperString(a, var_type);
    trailing = str.beforeFirst(trailing, "!");
    if (trailing.len == 0) return null;

    const kr = (try parseKind(a, trailing)) orelse return null;
    const kind_str = kr.kind;
    trailing = kr.line;
    const has_kind = kind_str != null and kind_str.?.len > 0;
    if (!has_kind and (std.mem.eql(u8, var_type, "TYPE") or std.mem.eql(u8, var_type, "CLASS"))) return null;
    if (!has_kind) {
        if (trailing.len == 0) return null;
        const c0 = trailing[0];
        if (!(c0 == ' ' or c0 == ',' or c0 == ':')) return null;
    }

    const kw = try parseVarKeywords(a, trailing);
    trailing = kw.rest;
    const fun_def = try readFunDef(a, trailing, .{ .type = var_type, .keywords = kw.keywords, .kind = kind_str }, false);
    if (fun_def != null or fun_only) return fun_def;

    var var_words: ?[]const []const u8 = null;
    const line_split = try str.split(a, trailing, "::");
    if (line_split.len == 1) {
        if (kw.keywords.len > 0) {
            var_words = null;
        } else {
            var_words = try helpers.separateDefList(a, str.strip(line_split[0]));
        }
    } else {
        var_words = (try helpers.separateDefList(a, str.strip(line_split[1]))) orelse &.{};
    }
    return .{ .var_ = .{ .var_type = var_type, .keywords = kw.keywords, .var_names = var_words, .var_kind = kind_str } };
}

pub const ProcMods = struct { name: []const u8, args: []const u8, trailing: []const u8 };

pub fn getProcedureModifiers(a: Allocator, line: []const u8, re: *const regex.Regex) E!?ProcMods {
    const m = re.match(line) orelse return null;
    const name = m.group(1).?;
    var trailing = str.strip(str.beforeFirst(line[m.end(0)..], "!"));
    var args: []const u8 = "";
    if (R().SUB_PAREN.match(trailing)) |pm| {
        const words = try R().WORD.findall(a, pm.str());
        args = try std.mem.join(a, ",", words);
        trailing = trailing[pm.end(0)..];
    }
    return .{ .name = name, .args = args, .trailing = trailing };
}

/// `SUB_MOD.findall` and `SUB_MOD.sub` of a line: its procedure prefixes
/// (PURE, ELEMENTAL, ...) and the line without them. The pattern can only
/// match where one of those words is, so the many lines without one skip
/// both scans, which otherwise try a match at every character.
pub fn splitSubMod(a: Allocator, line: []const u8) E!struct { []const []const u8, []const u8 } {
    // IMPURE contains PURE
    if (!(std.ascii.findIgnoreCase(line, "pure") != null) and !(std.ascii.findIgnoreCase(line, "elemental") != null) and
        !(std.ascii.findIgnoreCase(line, "recursive") != null)) return .{ &.{}, line };
    return .{ try R().SUB_MOD.findall(a, line), try R().SUB_MOD.sub(a, "", line) };
}

/// Attempt to read FUNCTION definition line
pub fn readFunDef(a: Allocator, line_in: []const u8, result_in: ?ResultSig, mod_flag: bool) E!?DefResult {
    const keywords, const line = try splitSubMod(a, line_in);
    if (keywords.len > 0) {
        if (try readVarDef(a, line, null, true)) |tmp_var| {
            var tv = tmp_var;
            switch (tv) {
                .fun => |*f| f.keywords = keywords,
                .var_ => |*v| v.keywords = keywords,
                else => {},
            }
            return tv;
        }
    }
    const pm = (try getProcedureModifiers(a, line, &R().FUN)) orelse return null;
    const trailing = str.strip(pm.trailing);
    var result = result_in orelse ResultSig{};
    if (R().RESULT.match(trailing)) |rm| {
        result.name = try std.ascii.allocLowerString(a, str.strip(rm.group(1).?));
    }
    if (result.name == null or result.name.?.len == 0) result.name = pm.name;
    return .{ .fun = .{ .name = pm.name, .args = pm.args, .keywords = keywords, .mod_flag = mod_flag, .result = result } };
}

pub fn readSubDef(a: Allocator, line_in: []const u8, mod_flag: bool) E!?DefResult {
    const keywords, const line = try splitSubMod(a, line_in);
    const pm = (try getProcedureModifiers(a, line, &R().SUB)) orelse return null;
    return .{ .sub = .{ .name = pm.name, .args = pm.args, .keywords = keywords, .mod_flag = mod_flag } };
}

pub fn readBlockDataDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    const m = R().BLOCK_DATA.match(line) orelse return null;
    return .{ .block_data = m.group(1) };
}

pub fn readBlockDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().BLOCK.match(line) orelse return null;
    var name = m.group(1);
    if (name) |n| if (n.len > 0) {
        name = str.strip(try std.mem.replaceOwned(u8, a, n, ":", " "));
    };
    return .{ .block = name };
}

pub fn stripNoComment(a: Allocator, line: []const u8) E![]const u8 {
    const stripped = try helpers.stripStrings(a, line, true);
    return str.rstrip(str.beforeFirst(stripped, "!"));
}

pub fn readDoDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    const m = R().DO.match(nc) orelse return null;
    return .{ .do_ = str.strip(m.group(1).?) };
}

pub fn readWhereDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    const m = R().WHERE.match(nc) orelse return null;
    const trailing = str.from(line, m.end(0));
    const close_paren = helpers.findParenMatch(trailing);
    if (close_paren < 0) return .{ .where = true };
    const after = str.strip(str.from(trailing, @as(usize, @intCast(close_paren)) + 1));
    if (R().WORD.match(after) != null) return .{ .where = true };
    return .{ .where = false };
}

pub fn readIfDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    if (R().IF.match(nc) != null and R().THEN.search(nc) != null) return .if_;
    return null;
}

pub fn readAssociateDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().ASSOCIATE.match(line) orelse return null;
    const trailing = line[m.end(0)..];
    const mc = helpers.findParenMatch(trailing);
    if (mc < 0) return .{ .assoc = &.{} };
    const words = try helpers.separateDefList(a, str.strip(trailing[0..@intCast(mc)]));
    return .{ .assoc = words orelse &.{} };
}

pub fn readSelectDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    if (R().SELECT.match(line)) |m| {
        const word = m.group(1).?;
        var st: i32 = -1;
        if (std.ascii.startsWithIgnoreCase(word, "case")) {
            st = 1;
        } else if (std.ascii.startsWithIgnoreCase(word, "type")) {
            st = 2;
        }
        return .{ .select = .{ .type = st, .binding = m.group(2), .desc = null } };
    }
    if (R().SELECT_TYPE.match(line)) |m| {
        var buf: [5]u8 = undefined;
        const d = m.group(1).?;
        const up = std.ascii.upperString(buf[0..d.len], d);
        const desc: []const u8 = if (std.mem.eql(u8, up, "TYPE")) "TYPE" else "CLASS";
        return .{ .select = .{ .type = 3, .binding = m.group(2), .desc = desc } };
    }
    if (R().SELECT_DEFAULT.match(line) != null) return .{ .select = .{ .type = 4, .binding = null, .desc = null } };
    return null;
}

pub fn readTypeDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().TYPE_DEF.match(line) orelse return null;
    var trailing = str.strip(str.beforeFirst(line[m.end(1)..], "!"));
    var keywords: std.ArrayList([]const u8) = .empty;
    var parent: ?[]const u8 = null;
    var km = R().TATTR_LIST.match(trailing);
    while (km) |k| {
        const ks = try std.ascii.allocUpperString(a, str.strip(try std.mem.replaceOwned(u8, a, k.str(), ",", " ")));
        if (R().EXTENDS.match(ks)) |em| {
            parent = try std.ascii.allocLowerString(a, em.group(1).?);
        } else {
            try keywords.append(a, ks);
        }
        trailing = trailing[k.end(0)..];
        km = R().TATTR_LIST.match(trailing);
    }
    const line_split = try str.split(a, trailing, "::");
    if (line_split.len == 1) {
        if (keywords.items.len > 0 and parent == null) return null;
        const first = try std.ascii.allocLowerString(a, str.strip(str.beforeFirst(trailing, "(")));
        if (std.mem.eql(u8, first, "is")) return null;
        trailing = line_split[0];
    } else {
        trailing = line_split[1];
    }
    const wm = R().WORD.match(str.strip(trailing)) orelse return null;
    return .{ .typ = .{ .name = wm.str(), .parent = parent, .keywords = keywords.items } };
}

pub fn readEnumDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    if (R().ENUM_DEF.match(line) != null) return .enum_;
    return null;
}

pub fn readGenericDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().GENERIC_PRO.match(line) orelse return null;
    const trailing = str.strip(str.beforeFirst(line[m.end(0) - 1 ..], "!"));
    if (trailing.len == 0) return null;
    var vis_flag: objects.Vis = .default;
    if (m.group(2)) |v| {
        vis_flag = if (std.ascii.eqlIgnoreCase(v, "private")) .private else .public;
    }
    const i_1 = std.mem.indexOf(u8, trailing, "=>") orelse return null;
    const bound_name = str.strip(trailing[0..i_1]);
    if (R().GEN_ASSIGN.match(bound_name) != null) return null;
    var pro_out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trailing[i_1 + 2 ..], ',');
    while (it.next()) |p| {
        const s = str.strip(p);
        if (s.len > 0) try pro_out.append(a, s);
    }
    if (pro_out.items.len == 0) return null;
    return .{ .gen = .{ .bound_name = bound_name, .pro_links = pro_out.items, .vis_flag = vis_flag } };
}

pub fn readModDef(a: Allocator, line_in: []const u8) E!?DefResult {
    const keywords, const line = try splitSubMod(a, line_in);
    const m = R().MOD.match(line) orelse return null;
    const name = m.group(1).?;
    if (std.ascii.eqlIgnoreCase(name, "procedure")) {
        const trailing = line[m.end(1)..];
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, trailing, ',');
        while (it.next()) |n| try names.append(a, try std.ascii.allocLowerString(a, str.strip(n)));
        return .{ .int_pro = names.items };
    }
    const trailing = line[m.start(1)..];
    if (try readSubDef(a, trailing, true)) |r| return r;
    if (try readVarDef(a, trailing, null, true)) |r| {
        var res = r;
        switch (res) {
            .fun => |*f| {
                f.mod_flag = true;
                f.keywords = keywords;
            },
            .var_ => |*v| v.keywords = keywords,
            else => {},
        }
        return res;
    }
    if (try readFunDef(a, trailing, null, true)) |r| {
        var res = r;
        switch (res) {
            .fun => |*f| f.keywords = keywords,
            .var_ => |*v| v.keywords = keywords,
            else => {},
        }
        return res;
    }
    return .{ .mod = name };
}

/// `SUBMODULE (ancestor[:parent]) name`: the name follows the parentheses,
/// not the parent submodule inside them
pub fn readSubmodDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().SUBMOD.match(line) orelse return null;
    var ancestor_name: []const u8 = "";
    var parent_name: []const u8 = "";
    var name: []const u8 = "";
    const trailing = str.strip(str.beforeFirst(line[m.end(0)..], "!"));
    const close = std.mem.indexOfScalar(u8, trailing, ')') orelse trailing.len;
    const parents = trailing[0..close];
    const colon = std.mem.indexOfScalar(u8, parents, ':') orelse parents.len;
    if (R().WORD.search(parents[0..colon])) |am| ancestor_name = try std.ascii.allocLowerString(a, am.str());
    if (colon < parents.len) if (R().WORD.search(parents[colon + 1 ..])) |pm| {
        parent_name = try std.ascii.allocLowerString(a, pm.str());
    };
    if (close < trailing.len) if (R().WORD.search(trailing[close + 1 ..])) |nm| {
        name = try std.ascii.allocLowerString(a, nm.str());
    };
    return .{ .smod = .{ .name = name, .ancestor = ancestor_name, .parent = parent_name } };
}

pub fn readProgDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    const m = R().PROG.match(line) orelse return null;
    return .{ .prog = m.group(1).? };
}

pub fn readIntDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().INT.match(line) orelse return null;
    const raw = m.group(2) orelse "";
    const int_name = try std.ascii.allocLowerString(a, raw);
    const is_abstract = m.group(1) != null;
    if (int_name.len == 0) return .{ .int = .{ .name = null, .abstract = is_abstract } };
    if (std.mem.eql(u8, int_name, "assignment") or std.mem.eql(u8, int_name, "operator")) return .{ .int = .{ .name = null, .abstract = false } };
    return .{ .int = .{ .name = raw, .abstract = is_abstract } };
}

pub fn readUseStmt(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().USE.match(line) orelse return null;
    const trailing = str.beforeFirst(try std.ascii.allocLowerString(a, line[m.end(0)..]), "!");
    const use_mod = m.group(2).?;
    var only: std.ArrayList([]const u8) = .empty;
    var renames: std.ArrayList([2][]const u8) = .empty;
    if (m.group(3) == null or m.group(3).?.len == 0) {
        // without ONLY every public name comes, some renamed: `use m, a => b`
        var it = std.mem.splitScalar(u8, trailing, ',');
        while (it.next()) |item| {
            const parts = try str.split(a, item, "=>");
            if (parts.len != 2) continue;
            const local = str.strip(parts[0]);
            const original = str.strip(parts[1]);
            if (local.len == 0 or original.len == 0) continue;
            try renames.append(a, .{ local, original });
        }
    } else {
        var it = std.mem.splitScalar(u8, trailing, ',');
        while (it.next()) |only_stmt| {
            const parts = try str.split(a, only_stmt, "=>");
            const only_name = str.strip(parts[0]);
            var dup = false;
            for (only.items) |o| if (std.mem.eql(u8, o, only_name)) {
                dup = true;
            };
            if (!dup) try only.append(a, only_name);
            if (parts.len == 2) {
                var replaced = false;
                for (renames.items) |*r| if (std.mem.eql(u8, r[0], only_name)) {
                    r[1] = str.strip(parts[1]);
                    replaced = true;
                };
                if (!replaced) try renames.append(a, .{ only_name, str.strip(parts[1]) });
            }
        }
    }
    return .{ .use = .{ .mod_name = use_mod, .only_list = only.items, .renames = renames.items } };
}

pub fn readImpStmt(a: Allocator, line: []const u8) E!?DefResult {
    const re = &R().IMPORT;
    const m = re.match(line) orelse return null;
    const spec = m.named(re, "spec");
    const is_empty = spec == null and m.named(re, "only") == null and m.named(re, "start1") == null and m.named(re, "start2") == null;
    if (is_empty or (spec != null and std.ascii.eqlIgnoreCase(spec.?, "all"))) {
        return .{ .import = .{ .import_type = .all } };
    } else if (spec != null and std.ascii.eqlIgnoreCase(spec.?, "none")) {
        return .{ .import = .{ .import_type = .none } };
    }
    const trailing = try std.ascii.allocLowerString(a, line[m.end(0) - 1 ..]);
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trailing, ',');
    while (it.next()) |p| {
        const s = str.strip(p);
        var dup = false;
        for (list.items) |o| if (std.mem.eql(u8, o, s)) {
            dup = true;
        };
        if (!dup) try list.append(a, s);
    }
    return .{ .import = .{ .import_type = .only, .only_list = list.items } };
}

pub fn readIncStmt(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    const m = R().INCLUDE.match(line) orelse return null;
    return .{ .inc = m.group(1).? };
}

pub fn readVisStmnt(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().VIS.match(line) orelse return null;
    const is_private = std.ascii.eqlIgnoreCase(m.group(1).?, "private");
    const trailing = str.beforeFirst(line[m.end(0)..], "!");
    const words = try R().WORD.findall(a, trailing);
    return .{ .vis = .{ .private = is_private, .obj_names = words } };
}

pub const DefTest = *const fn (Allocator, []const u8) E!?DefResult;

/// A definition test and the words a line it can match may start with
/// (lowercase prefixes of the line's first word, so that fixed-form words
/// written together, `DOUBLEPRECISION` or `BLOCKDATA`, still qualify)
pub const DefTestEntry = struct { read: DefTest, starts: []const []const u8 };

/// PURE, IMPURE, ELEMENTAL and RECURSIVE are removed from a line before it is
/// tested for a procedure (`splitSubMod`), so they can come first
pub const proc_prefixes = [_][]const u8{ "pure", "impure", "elemental", "recursive" };

pub fn readVarDef1(a: Allocator, line: []const u8) E!?DefResult {
    return readVarDef(a, line, null, false);
}

pub fn readSubDef1(a: Allocator, line: []const u8) E!?DefResult {
    return readSubDef(a, line, false);
}

pub fn readFunDef1(a: Allocator, line: []const u8) E!?DefResult {
    return readFunDef(a, line, null, false);
}

/// The definition tests in the order fortls tries them. Each pattern is
/// anchored at the start of the line, after spaces; the words are those its
/// pattern (VAR, SUB, FUN, BLOCK_DATA, ...) can begin with.
pub const def_tests = [_]DefTestEntry{
    .{ .read = readVarDef1, .starts = &.{ "integer", "real", "double", "complex", "character", "logical", "procedure", "external", "class", "type" } },
    .{ .read = readSubDef1, .starts = &(.{"subroutine"} ++ proc_prefixes) },
    .{ .read = readFunDef1, .starts = &(.{"function"} ++ proc_prefixes) },
    .{ .read = readBlockDataDef, .starts = &.{"block"} },
    .{ .read = readBlockDef, .starts = &.{ "block", "critical" } },
    .{ .read = readWhereDef, .starts = &.{"where"} },
    .{ .read = readDoDef, .starts = &.{"do"} },
    .{ .read = readIfDef, .starts = &.{"if"} },
    .{ .read = readAssociateDef, .starts = &.{"associate"} },
    .{ .read = readSelectDef, .starts = &.{ "select", "type", "class" } },
    .{ .read = readTypeDef, .starts = &.{"type"} },
    .{ .read = readEnumDef, .starts = &.{"enum"} },
    .{ .read = readUseStmt, .starts = &.{"use"} },
    .{ .read = readImpStmt, .starts = &.{"import"} },
    .{ .read = readIntDef, .starts = &.{ "abstract", "interface" } },
    .{ .read = readGenericDef, .starts = &.{"generic"} },
    .{ .read = readModDef, .starts = &(.{"module"} ++ proc_prefixes) },
    .{ .read = readProgDef, .starts = &.{"program"} },
    .{ .read = readSubmodDef, .starts = &.{"submodule"} },
    .{ .read = readIncStmt, .starts = &.{"include"} },
    .{ .read = readVisStmnt, .starts = &.{ "public", "private" } },
};

/// The first word of a line, lowercased into `buf`, when the definition
/// tests can be chosen by it. Null when they cannot: no word (the line starts
/// with something else), a word too long for `buf`, or a construct label
/// (`name: DO`), whose name can be any word.
pub fn firstWord(line: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    const start = i;
    if (i >= line.len or !std.ascii.isAlphabetic(line[i])) return null;
    // a word as the patterns see it (`\w`, which takes bytes past ASCII)
    while (i < line.len and regex.isWordChar(line[i])) i += 1;
    if (i - start > buf.len) return null;
    var j = i;
    while (j < line.len and line[j] == ' ') j += 1;
    if (j < line.len and line[j] == ':' and !(j + 1 < line.len and line[j + 1] == ':')) return null;
    return std.ascii.lowerString(buf[0 .. i - start], line[start..i]);
}

pub fn canStart(entry: DefTestEntry, word: []const u8) bool {
    for (entry.starts) |w| if (std.mem.startsWith(u8, word, w)) return true;
    return false;
}

/// The first definition test that matches the line (`get_fortran_definition`).
/// Only the tests whose pattern can begin with the line's first word run,
/// in order; a line without a usable first word runs all of them. Debug builds
/// also run all of them and check that the result is the same.
/// A procedure statement after the CUDA Fortran prefix
/// `attributes(global|device|host|grid_global)`: the rest of the line
pub fn afterCudaAttributes(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.ascii.startsWithIgnoreCase(t, "attributes")) return null;
    var rest = std.mem.trimStart(u8, t["attributes".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return null;
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    for (rest[1..close]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ',' or c == ' ')) return null;
    rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    if (rest.len == 0 or !std.ascii.isAlphabetic(rest[0])) return null;
    return rest;
}

pub fn getFortranDefinition(a: Allocator, line: []const u8) E!?DefResult {
    // CUDA Fortran kernels and device procedures (`attributes(global)
    // subroutine k(...)`) are procedures
    if (afterCudaAttributes(line)) |rest| return getFortranDefinition(a, rest);
    var buf: [32]u8 = undefined;
    const word = firstWord(line, &buf) orelse return (try runDefTests(a, line, null)).result;
    const found = try runDefTests(a, line, word);
    if (builtin.mode == .debug) {
        const all = try runDefTests(a, line, null);
        if (all.index != found.index) std.debug.panic("definition test {?d} matches \"{s}\" but the first-word dispatch chose {?d}", .{ all.index, line, found.index });
    }
    return found.result;
}

pub fn runDefTests(a: Allocator, line: []const u8, word: ?[]const u8) E!struct { index: ?usize, result: ?DefResult } {
    for (def_tests, 0..) |t, i| {
        if (word) |w| if (!canStart(t, w)) continue;
        if (try t.read(a, line)) |r| return .{ .index = i, .result = r };
    }
    return .{ .index = null, .result = null };
}

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
            if (std.mem.eql(u8, v.var_type, "PROCEDURE") and (std.mem.indexOf(u8, line, "=>") orelse 0) > 0) return .{ .ctx = .pro_link };
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
