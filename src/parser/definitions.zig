//! Reading the definition on a line (port of the `read_*_def` functions of
//! fortls): variables, procedures, modules, types, constructs, USE and IMPORT
//! statements, and what a line is about for completion. Constructs are read
//! in def_constructs.zig, the CUDA Fortran prefix in cuda_prefix.zig, the
//! context of a line in line_context.zig.

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
const def_constructs = @import("def_constructs.zig");
const cuda_prefix = @import("cuda_prefix.zig");
const line_context = @import("line_context.zig");

pub const readBlockDef = def_constructs.readBlockDef;
pub const stripNoComment = def_constructs.stripNoComment;
pub const readDoDef = def_constructs.readDoDef;
pub const readWhereDef = def_constructs.readWhereDef;
pub const readIfDef = def_constructs.readIfDef;
pub const readAssociateDef = def_constructs.readAssociateDef;
pub const readChangeTeamDef = def_constructs.readChangeTeamDef;
pub const readSelectDef = def_constructs.readSelectDef;
pub const afterCudaAttributes = cuda_prefix.afterCudaAttributes;
pub const withoutCudaAttributes = cuda_prefix.withoutCudaAttributes;
pub const LineContext = line_context.LineContext;
pub const getLineContext = line_context.getLineContext;

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

/// `kind`: of a type guard of an intrinsic type, `type is (real(8))`;
/// `rank`: of a case of SELECT RANK, `2` or `*` (none for RANK DEFAULT)
pub const SelectInfo = struct { type: i32, binding: ?[]const u8, desc: ?[]const u8, kind: ?[]const u8 = null, rank: ?[]const u8 = null };

pub const ClassInfo = struct { name: []const u8, parent: ?[]const u8, keywords: []const []const u8 };

pub const GenProcDefInfo = struct { bound_name: []const u8, pro_links: []const []const u8, vis_flag: objects.Vis };

/// `SUBMODULE (ancestor[:parent]) name`
pub const SmodInfo = struct { name: []const u8, ancestor: []const u8, parent: []const u8 };

/// `[ABSTRACT] INTERFACE [name]`; `generic`: named, or `OPERATOR(...)` or
/// `ASSIGNMENT(=)` (#472)
pub const InterInfo = struct { name: ?[]const u8, abstract: bool, generic: bool = false };

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
    /// CHANGE TEAM: its coarray associations, `x => y` (`x[*] => y`)
    team: []const []const u8,
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
        } else if (std.ascii.startsWithIgnoreCase(tmp_str, "dimension") or std.ascii.startsWithIgnoreCase(tmp_str, "rank")) {
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

/// The RANK clause (F2023) of a declaration's `keywords`, replaced by the
/// DIMENSION it gives: `(:,:)` of a literal rank (none for 0), else assumed
/// rank, `(..)`, until linking evaluates it; its expression then, else null
/// (#729)
pub fn rankClause(a: Allocator, keywords: *std.ArrayList([]const u8)) E!?[]const u8 {
    for (keywords.items, 0..) |kw, i| {
        if (!std.ascii.startsWithIgnoreCase(kw, "rank")) continue;
        const expr = str.strip(helpers.getParenSubstring(kw) orelse "");
        const n = std.fmt.parseInt(u8, expr, 10) catch {
            keywords.items[i] = "DIMENSION(..)";
            return expr;
        };
        if (n == 0 or n > 15) {
            _ = keywords.orderedRemove(i);
        } else {
            var dims: std.ArrayList(u8) = .empty;
            for (0..n) |k| try dims.appendSlice(a, if (k == 0) ":" else ",:");
            keywords.items[i] = try a.print("DIMENSION({s})", .{dims.items});
        }
        return null;
    }
    return null;
}

pub const KindResult = struct { kind: ?[]const u8, line: []const u8 };

pub fn parseKind(a: Allocator, line: []const u8) E!?KindResult {
    const m = R().KIND_SPEC.match(line) orelse return .{ .kind = null, .line = line };
    var kind_str: []const u8 = try std.mem.replaceOwned(u8, a, m.group(1).?, " ", "");
    var rest = line[m.end(0)..];
    // `()` is whole; the match of `((4))` ends inside the inner parentheses
    if (std.mem.findScalar(u8, kind_str, '(') != null and !std.mem.endsWith(u8, kind_str, ")")) {
        const open = std.mem.findScalar(u8, line, '(').?;
        const mc = helpers.findParenMatch(line[open + 1 ..]);
        if (mc < 0) return null; // Incomplete kind specification
        const end = open + 1 + @as(usize, @intCast(mc)) + 1;
        kind_str = try std.mem.concat(a, u8, &.{ kind_str, str.strip(line[m.end(0)..end]) });
        rest = line[end..];
    }
    return .{ .kind = kind_str, .line = rest };
}

/// TYPEOF or CLASSOF (F2023), whose "kind" is the entity whose type a
/// declaration takes (#728)
pub fn isTypeOf(var_type: []const u8) bool {
    return std.mem.eql(u8, var_type, "TYPEOF") or std.mem.eql(u8, var_type, "CLASSOF");
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
    trailing = helpers.beforeComment(trailing);
    if (trailing.len == 0) return null;

    const kr = (try parseKind(a, trailing)) orelse return null;
    const kind_str = kr.kind;
    trailing = kr.line;
    const has_kind = kind_str != null and kind_str.?.len > 0;
    if (!has_kind and (std.mem.eql(u8, var_type, "TYPE") or std.mem.eql(u8, var_type, "CLASS") or isTypeOf(var_type))) return null;
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
    var trailing = str.strip(helpers.beforeComment(line[m.end(0)..]));
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
        !(std.ascii.findIgnoreCase(line, "recursive") != null) and !(std.ascii.findIgnoreCase(line, "simple") != null)) return .{ &.{}, line };
    return .{ try R().SUB_MOD.findall(a, line), try R().SUB_MOD.sub(a, "", line) };
}

/// Attempt to read FUNCTION definition line
pub fn readFunDef(a: Allocator, line_in: []const u8, result_in: ?ResultSig, mod_flag_in: bool) E!?DefResult {
    const keywords, var line = try splitSubMod(a, line_in);
    // MODULE after the type, among the prefixes, which go in any order:
    // `real(dp) module function f(x)` (a MODULE first is readModDef's)
    var mod_flag = mod_flag_in;
    if (result_in != null) if (afterModulePrefix(line)) |rest| {
        line = rest;
        mod_flag = true;
    };
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

/// The text after a MODULE prefix that a FUNCTION follows, `module function
/// f(x)`
fn afterModulePrefix(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len < 7 or !std.ascii.startsWithIgnoreCase(t, "module") or t[6] != ' ') return null;
    const rest = t[6..];
    if (!std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, rest, " "), "function")) return null;
    return rest;
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

pub fn readTypeDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().TYPE_DEF.match(line) orelse return null;
    var trailing = str.strip(helpers.beforeComment(line[m.end(1)..]));
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
    const trailing = str.strip(helpers.beforeComment(line[m.end(0) - 1 ..]));
    if (trailing.len == 0) return null;
    var vis_flag: objects.Vis = .default;
    if (m.group(2)) |v| {
        vis_flag = if (std.ascii.eqlIgnoreCase(v, "private")) .private else .public;
    }
    const i_1 = std.mem.find(u8, trailing, "=>") orelse return null;
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
    const trailing = str.strip(helpers.beforeComment(line[m.end(0)..]));
    const close = std.mem.findScalar(u8, trailing, ')') orelse trailing.len;
    const parents = trailing[0..close];
    const colon = std.mem.findScalar(u8, parents, ':') orelse parents.len;
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
    if (std.mem.eql(u8, int_name, "assignment") or std.mem.eql(u8, int_name, "operator")) return .{ .int = .{ .name = null, .abstract = false, .generic = true } };
    return .{ .int = .{ .name = raw, .abstract = is_abstract, .generic = !is_abstract } };
}

pub fn readUseStmt(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().USE.match(line) orelse return null;
    const trailing = helpers.beforeComment(try std.ascii.allocLowerString(a, line[m.end(0)..]));
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
    const trailing = helpers.beforeComment(line[m.end(0)..]);
    const words = try R().WORD.findall(a, trailing);
    return .{ .vis = .{ .private = is_private, .obj_names = words } };
}

pub const DefTest = *const fn (Allocator, []const u8) E!?DefResult;

/// A definition test and the words a line it can match may start with
/// (lowercase prefixes of the line's first word, so that fixed-form words
/// written together, `DOUBLEPRECISION` or `BLOCKDATA`, still qualify)
pub const DefTestEntry = struct { read: DefTest, starts: []const []const u8 };

/// PURE, IMPURE, ELEMENTAL, RECURSIVE, NON_RECURSIVE and SIMPLE are removed
/// from a line before it is tested for a procedure (`splitSubMod`), so they
/// can come first
pub const proc_prefixes = [_][]const u8{ "pure", "impure", "elemental", "recursive", "non_recursive", "simple" };

/// `ENUMERATOR [::] a = 1, b`: the enumerators of an ENUM, named integer
/// constants (fortls reads none)
pub fn readEnumeratorDef(a: Allocator, line: []const u8) E!?DefResult {
    const word = "enumerator";
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len <= word.len or !std.ascii.startsWithIgnoreCase(t, word)) return null;
    var rest = t[word.len..];
    if (rest[0] != ' ' and rest[0] != ':') return null;
    rest = str.strip(helpers.beforeComment(rest));
    if (std.mem.startsWith(u8, rest, "::")) rest = str.strip(rest[2..]);
    const names = (try helpers.separateDefList(a, rest)) orelse return null;
    return .{ .var_ = .{ .var_type = "INTEGER", .keywords = &.{"PARAMETER"}, .var_names = names, .var_kind = null } };
}

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
    .{ .read = readVarDef1, .starts = &.{ "integer", "real", "double", "complex", "character", "logical", "procedure", "external", "class", "type", "byte", "unsigned" } },
    .{ .read = readSubDef1, .starts = &(.{"subroutine"} ++ proc_prefixes) },
    .{ .read = readFunDef1, .starts = &(.{"function"} ++ proc_prefixes) },
    .{ .read = readBlockDataDef, .starts = &.{"block"} },
    .{ .read = readBlockDef, .starts = &.{ "block", "critical" } },
    .{ .read = readWhereDef, .starts = &.{"where"} },
    .{ .read = readDoDef, .starts = &.{"do"} },
    .{ .read = readIfDef, .starts = &.{"if"} },
    .{ .read = readAssociateDef, .starts = &.{"associate"} },
    .{ .read = readChangeTeamDef, .starts = &.{"change"} },
    .{ .read = readSelectDef, .starts = &.{ "select", "type", "class", "rank" } },
    .{ .read = readTypeDef, .starts = &.{"type"} },
    .{ .read = readEnumeratorDef, .starts = &.{"enumerator"} },
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
pub fn getFortranDefinition(a: Allocator, line: []const u8) E!?DefResult {
    // CUDA Fortran kernels and device procedures (`attributes(global)
    // subroutine k(...)`, `pure attributes(device) function f(...)`) are
    // procedures
    if (afterCudaAttributes(line)) |rest| return getFortranDefinition(a, rest);
    if (try withoutCudaAttributes(a, line)) |rest| return getFortranDefinition(a, rest);
    var buf: [32]u8 = undefined;
    const word = firstWord(line, &buf) orelse return (try runDefTests(a, line, null)).result;
    const found = try runDefTests(a, line, word);
    if (builtin.optimize == .debug) {
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

test "read definitions" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try readVarDef(a, "  integer(kind=8), intent(in) :: x, y(3)", null, false)).?;
    try std.testing.expectEqualStrings("INTEGER", r.var_.var_type);
    try std.testing.expectEqualStrings("(kind=8)", r.var_.var_kind.?);
    try std.testing.expectEqual(@as(usize, 2), r.var_.var_names.?.len);
    try std.testing.expectEqualStrings("INTENT(IN)", r.var_.keywords[0]);
    // a kind in parentheses (#690)
    for ([_]struct { []const u8, []const u8 }{ .{ "INTEGER((4)) INT_KIND_IMP", "((4))" }, .{ "real ((8)+0) :: x", "((8)+0)" } }) |c| {
        const p = (try readVarDef(a, c[0], null, false)).?;
        try std.testing.expectEqualStrings(c[1], p.var_.var_kind.?);
        try std.testing.expectEqual(@as(usize, 1), p.var_.var_names.?.len);
    }

    const f = (try readFunDef(a, "pure real function foo(a, b) result(c)", null, false)).?;
    try std.testing.expectEqualStrings("foo", f.fun.name);
    try std.testing.expectEqualStrings("a,b", f.fun.args);

    const s = (try getFortranDefinition(a, "subroutine bar(x)")).?;
    try std.testing.expectEqualStrings("bar", s.sub.name);

    const ctx = try getLineContext(a, "call foo");
    try std.testing.expectEqual(LineContext.call, ctx.ctx);

    // MODULE after the type (stdlib): a separate module procedure, not a
    // variable named `module`
    for ([_][]const u8{ "real(RTICKS) module function lifetime(p) result(t)", "pure real(dp) module function lifetime(p)" }) |line| {
        const m = (try getFortranDefinition(a, line)).?;
        try std.testing.expectEqualStrings("lifetime", m.fun.name);
        try std.testing.expect(m.fun.mod_flag);
    }
    // a variable of that name stays one
    const v = (try getFortranDefinition(a, "      REAL MODULE")).?;
    try std.testing.expectEqualStrings("MODULE", v.var_.var_names.?[0]);
}

test "the definition tests are chosen by the first word, labels fall back to all" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("integer", firstWord("  INTEGER :: x", &buf).?);
    try std.testing.expectEqualStrings("doubleprecision", firstWord("      DOUBLEPRECISION X", &buf).?);
    try std.testing.expect(firstWord("  outer: do i = 1, n", &buf) == null);
    // `\w` takes bytes past ASCII, so this is a construct label too
    try std.testing.expect(firstWord("add\xe2\x88\x911 : BLOCK", &buf) == null);
    try std.testing.expectEqualStrings("use", firstWord("use m, only: a", &buf).?);
    try std.testing.expect(firstWord("_x: block", &buf) == null);
    try std.testing.expect(firstWord("#include \"a\"", &buf) == null);
}
