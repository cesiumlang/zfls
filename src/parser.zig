//! Fortran source file handling and parsing (port of
//! `fortls.parsers.internal.parser`)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const helpers = @import("helpers.zig");
const patterns = @import("patterns.zig");
const regex = @import("regex.zig");
const C = @import("constants.zig");
const objects = @import("objects.zig");
const pp = @import("preprocessor.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const UseStmt = objects.UseStmt;
const Range = helpers.Range;

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// Receives parser/preprocessor trace lines (debug CLI)
pub const Trace = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, msg: []const u8) void,

    /// Write a trace line to `t`, if there is one
    pub fn print(t: ?Trace, comptime fmt: []const u8, args: anytype) void {
        const tr = t orelse return;
        var buf: [16384]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        tr.writeFn(tr.ctx, s);
    }
};

/// Parameters of parsing a file that do not depend on the file
pub const Options = struct {
    /// Order the keywords of a definition by id (`--sort_keywords`)
    sort_keywords: bool = false,
    trace: ?Trace = null,
};

// --------------------------------------------------------------------------
// Line definition readers

/// What can go wrong with a workspace file
pub const FileError = error{ ReadFailed, ParseFailed, FileNotFound, RecursionLimit, OutOfMemory };

/// The text shown to the user for `e`
pub fn describeFileError(e: FileError) []const u8 {
    return switch (e) {
        error.ReadFailed => "Could not read/decode file",
        error.ParseFailed => "Error during parsing",
        error.FileNotFound => "File does not exist",
        error.RecursionLimit => "An exception has occured while initialising the workspace.\nException(<class 'RecursionError'>): maximum recursion depth exceeded",
        error.OutOfMemory => "Out of memory",
    };
}

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
pub const SmodInfo = struct { name: []const u8, parent: []const u8 };
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

const E = Allocator.Error;

fn lstripChars(s: []const u8, chars: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, chars);
}

/// Parse Fortran variable declaration keywords
fn parseVarKeywords(a: Allocator, test_str_in: []const u8) E!struct { keywords: []const []const u8, rest: []const u8 } {
    var test_str = test_str_in;
    var keywords: std.ArrayList([]const u8) = .empty;
    var keyword_match = R().KEYWORD_LIST.match(test_str);
    while (keyword_match) |m| {
        var tmp_str: []const u8 = lstripChars(m.str(), ", ");
        test_str = test_str[m.end(0)..];
        if (std.ascii.startsWithIgnoreCase(tmp_str, "dimension")) {
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

const KindResult = struct { kind: ?[]const u8, line: []const u8 };

fn parseKind(a: Allocator, line: []const u8) E!?KindResult {
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

const ProcMods = struct { name: []const u8, args: []const u8, trailing: []const u8 };

fn getProcedureModifiers(a: Allocator, line: []const u8, re: *const regex.Regex) E!?ProcMods {
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
fn splitSubMod(a: Allocator, line: []const u8) E!struct { []const []const u8, []const u8 } {
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

fn readBlockDataDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    const m = R().BLOCK_DATA.match(line) orelse return null;
    return .{ .block_data = m.group(1) };
}

fn readBlockDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().BLOCK.match(line) orelse return null;
    var name = m.group(1);
    if (name) |n| if (n.len > 0) {
        name = str.strip(try std.mem.replaceOwned(u8, a, n, ":", " "));
    };
    return .{ .block = name };
}

fn stripNoComment(a: Allocator, line: []const u8) E![]const u8 {
    const stripped = try helpers.stripStrings(a, line, true);
    return str.rstrip(str.beforeFirst(stripped, "!"));
}

fn readDoDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    const m = R().DO.match(nc) orelse return null;
    return .{ .do_ = str.strip(m.group(1).?) };
}

fn readWhereDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    const m = R().WHERE.match(nc) orelse return null;
    const trailing = str.from(line, m.end(0));
    const close_paren = helpers.findParenMatch(trailing);
    if (close_paren < 0) return .{ .where = true };
    const after = str.strip(str.from(trailing, @as(usize, @intCast(close_paren)) + 1));
    if (R().WORD.match(after) != null) return .{ .where = true };
    return .{ .where = false };
}

fn readIfDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    if (R().IF.match(nc) != null and R().THEN.search(nc) != null) return .if_;
    return null;
}

fn readAssociateDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().ASSOCIATE.match(line) orelse return null;
    const trailing = line[m.end(0)..];
    const mc = helpers.findParenMatch(trailing);
    if (mc < 0) return .{ .assoc = &.{} };
    const words = try helpers.separateDefList(a, str.strip(trailing[0..@intCast(mc)]));
    return .{ .assoc = words orelse &.{} };
}

fn readSelectDef(a: Allocator, line: []const u8) E!?DefResult {
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

fn readTypeDef(a: Allocator, line: []const u8) E!?DefResult {
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

fn readEnumDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    if (R().ENUM_DEF.match(line) != null) return .enum_;
    return null;
}

fn readGenericDef(a: Allocator, line: []const u8) E!?DefResult {
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

fn readModDef(a: Allocator, line_in: []const u8) E!?DefResult {
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

fn readSubmodDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().SUBMOD.match(line) orelse return null;
    var parent_name: []const u8 = "";
    var name: []const u8 = "";
    var trailing = str.strip(str.beforeFirst(line[m.end(0)..], "!"));
    if (R().WORD.match(trailing)) |pm| {
        parent_name = try std.ascii.allocLowerString(a, pm.str());
        if (trailing.len > pm.end(0) + 1) {
            trailing = str.strip(trailing[pm.end(0) + 1 ..]);
        } else {
            trailing = "";
        }
    }
    if (R().WORD.search(trailing)) |nm| name = try std.ascii.allocLowerString(a, nm.str());
    return .{ .smod = .{ .name = name, .parent = parent_name } };
}

fn readProgDef(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    const m = R().PROG.match(line) orelse return null;
    return .{ .prog = m.group(1).? };
}

fn readIntDef(a: Allocator, line: []const u8) E!?DefResult {
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
    if (m.group(3) != null and m.group(3).?.len > 0) {
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

fn readImpStmt(a: Allocator, line: []const u8) E!?DefResult {
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

fn readIncStmt(a: Allocator, line: []const u8) E!?DefResult {
    _ = a;
    const m = R().INCLUDE.match(line) orelse return null;
    return .{ .inc = m.group(1).? };
}

fn readVisStmnt(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().VIS.match(line) orelse return null;
    const is_private = std.ascii.eqlIgnoreCase(m.group(1).?, "private");
    const trailing = str.beforeFirst(line[m.end(0)..], "!");
    const words = try R().WORD.findall(a, trailing);
    return .{ .vis = .{ .private = is_private, .obj_names = words } };
}

const DefTest = *const fn (Allocator, []const u8) E!?DefResult;

/// A definition test and the words a line it can match may start with
/// (lowercase prefixes of the line's first word, so that fixed-form words
/// written together, `DOUBLEPRECISION` or `BLOCKDATA`, still qualify)
const DefTestEntry = struct { read: DefTest, starts: []const []const u8 };

/// PURE, IMPURE, ELEMENTAL and RECURSIVE are removed from a line before it is
/// tested for a procedure (`splitSubMod`), so they can come first
const proc_prefixes = [_][]const u8{ "pure", "impure", "elemental", "recursive" };

fn readVarDef1(a: Allocator, line: []const u8) E!?DefResult {
    return readVarDef(a, line, null, false);
}
fn readSubDef1(a: Allocator, line: []const u8) E!?DefResult {
    return readSubDef(a, line, false);
}
fn readFunDef1(a: Allocator, line: []const u8) E!?DefResult {
    return readFunDef(a, line, null, false);
}

/// The definition tests in the order fortls tries them. Each pattern is
/// anchored at the start of the line, after spaces; the words are those its
/// pattern (VAR, SUB, FUN, BLOCK_DATA, ...) can begin with.
const def_tests = [_]DefTestEntry{
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
fn firstWord(line: []const u8, buf: []u8) ?[]const u8 {
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

fn canStart(entry: DefTestEntry, word: []const u8) bool {
    for (entry.starts) |w| if (std.mem.startsWith(u8, word, w)) return true;
    return false;
}

/// The first definition test that matches the line (`get_fortran_definition`).
/// Only the tests whose pattern can begin with the line's first word run,
/// in order; a line without a usable first word runs all of them. Debug builds
/// also run all of them and check that the result is the same.
pub fn getFortranDefinition(a: Allocator, line: []const u8) E!?DefResult {
    var buf: [32]u8 = undefined;
    const word = firstWord(line, &buf) orelse return (try runDefTests(a, line, null)).result;
    const found = try runDefTests(a, line, word);
    if (builtin.mode == .debug) {
        const all = try runDefTests(a, line, null);
        if (all.index != found.index) std.debug.panic("definition test {?d} matches \"{s}\" but the first-word dispatch chose {?d}", .{ all.index, line, found.index });
    }
    return found.result;
}

fn runDefTests(a: Allocator, line: []const u8, word: ?[]const u8) E!struct { index: ?usize, result: ?DefResult } {
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

// --------------------------------------------------------------------------
// EXTERNAL handling

// Both lookups are within the current scope: the same name can be declared
// external in several procedures of a file (upstream #406).

fn findExternalType(file_ast: *Ast, desc_string: []const u8, name: []const u8) !bool {
    if (!std.ascii.eqlIgnoreCase(desc_string, "EXTERNAL")) return false;
    var counter: usize = 0;
    for (file_ast.variable_list.items) |v| {
        if (!std.mem.eql(u8, name, v.name) or v.parent != file_ast.current_scope) continue;
        for (file_ast.external_objs.items) |e| if (e == v) return false;
        try v.setExternalAttr();
        try file_ast.external_objs.append(file_ast.allocator(), v);
        counter += 1;
    }
    return counter == 1;
}

fn findExternalAttr(file_ast: *Ast, name: []const u8, new_var: *Obj) !bool {
    var counter: usize = 0;
    for (file_ast.external_objs.items) |v| {
        if (!std.mem.eql(u8, v.name, name) or v.parent != file_ast.current_scope) continue;
        if (!std.ascii.eqlIgnoreCase(v.desc, "EXTERNAL")) continue;
        if (counter == 0) {
            v.desc = new_var.desc;
            try v.setExternalAttr();
        }
        counter += 1;
    }
    return counter == 1;
}

fn findExternal(file_ast: *Ast, desc_string: []const u8, name: []const u8, new_var: *Obj) !bool {
    if (try findExternalType(file_ast, desc_string, name)) return true;
    if (!std.ascii.eqlIgnoreCase(desc_string, "EXTERNAL")) {
        if (try findExternalAttr(file_ast, name, new_var)) return true;
    }
    return false;
}

// --------------------------------------------------------------------------
// Paths

/// `os.path.normpath`
pub fn normPath(a: Allocator, path: []const u8) ![]const u8 {
    return std.fs.path.resolve(a, &.{path}) catch path;
}

/// Split text into lines by \r\n, \n, or \r
pub fn splitLines(a: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n' or c == '\r') {
            try out.append(a, text[start..i]);
            if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
            i += 1;
            start = i;
        } else i += 1;
    }
    try out.append(a, text[start..]);
    return out.items;
}

// --------------------------------------------------------------------------
// FortranFile

pub const Change = struct {
    text: []const u8,
    range: ?struct { sl: usize, sc: usize, el: usize, ec: usize } = null,
};

pub const CodeLine = struct {
    pre: []const []const u8,
    curr: ?[]const u8,
    post: []const []const u8,
};

/// Index of the `&` of a free-form line that continues on the next line: the
/// first one, unless a comment starts before it
fn continuationAmpersand(line: []const u8) ?usize {
    const amper = std.mem.indexOfScalar(u8, line, '&') orelse return null;
    const comment = std.mem.indexOfScalar(u8, line, '!') orelse return amper;
    return if (amper < comment) amper else null;
}

pub const FortranFile = struct {
    gpa: Allocator,
    path: []const u8,
    /// Raw lines: slices of `text`
    lines: std.ArrayList([]const u8) = .empty,
    /// The lines one after another, without line breaks, owned by `gpa`
    text: []u8 = &.{},
    /// Preprocessed lines (null: identical to `lines`), owned by `pp_arena`
    pp_lines: ?[][]const u8 = null,
    pp_arena: std.heap.ArenaAllocator,
    pp_defs: pp.Defs = .empty,
    fixed: bool = false,
    preproc: bool = false,
    ast: ?*Ast = null,
    hash: ?u64 = null,

    pub fn create(gpa: Allocator, path: []const u8, pp_suffixes: ?[]const []const u8) !*FortranFile {
        const self = try gpa.create(FortranFile);
        self.* = .{
            .gpa = gpa,
            .path = try gpa.dupe(u8, path),
            .pp_arena = std.heap.ArenaAllocator.init(gpa),
        };
        const ext = std.fs.path.extension(std.fs.path.basename(path));
        if (pp_suffixes) |sfx| {
            self.preproc = false;
            for (sfx) |s| if (std.mem.eql(u8, s, ext)) {
                self.preproc = true;
            };
        } else {
            var upper_buf: [64]u8 = undefined;
            if (ext.len <= upper_buf.len) {
                const up = std.ascii.upperString(upper_buf[0..ext.len], ext);
                self.preproc = std.mem.eql(u8, up, ext);
            }
        }
        return self;
    }

    /// Frees the file but not its AST (ASTs are managed by the workspace)
    pub fn destroy(self: *FortranFile) void {
        self.gpa.free(self.text);
        self.lines.deinit(self.gpa);
        self.pp_arena.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    pub fn nLines(self: *const FortranFile) usize {
        return self.lines.items.len;
    }

    fn resetPp(self: *FortranFile) void {
        self.pp_lines = null;
        // pp_defs live in pp_arena too, keep them: they are replaced by preprocess
    }

    /// Set file contents (copies the lines into one buffer)
    pub fn setContents(self: *FortranFile, new_lines: []const []const u8, detect_format: bool) !void {
        var total: usize = 0;
        for (new_lines) |l| total += l.len;
        const buf = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(buf);
        var fresh: std.ArrayList([]const u8) = .empty;
        errdefer fresh.deinit(self.gpa);
        try fresh.ensureTotalCapacity(self.gpa, new_lines.len);
        var at: usize = 0;
        for (new_lines) |l| {
            @memcpy(buf[at .. at + l.len], l);
            fresh.appendAssumeCapacity(buf[at .. at + l.len]);
            at += l.len;
        }
        self.replaceText(buf, fresh);
        if (detect_format) self.fixed = helpers.detectFixedFormat(self.lines.items);
    }

    /// Take `buf` (owned by `gpa`) and the lines in it as the contents
    fn replaceText(self: *FortranFile, buf: []u8, new_lines: std.ArrayList([]const u8)) void {
        self.gpa.free(self.text);
        self.lines.deinit(self.gpa);
        self.text = buf;
        self.lines = new_lines;
        self.resetPp();
    }

    /// Set contents from text; returns false if unchanged (same hash)
    pub fn setText(self: *FortranFile, text_in: []const u8) !bool {
        return self.setTextOwned(try self.gpa.dupe(u8, text_in));
    }

    /// `setText` taking ownership of `text` (allocated by `gpa`): the lines
    /// are slices of it, without a copy
    pub fn setTextOwned(self: *FortranFile, text: []u8) !bool {
        errdefer self.gpa.free(text);
        std.mem.replaceScalar(u8, text, '\t', ' ');
        const h = std.hash.Wyhash.hash(0, text);
        if (self.hash != null and self.hash.? == h) {
            self.gpa.free(text);
            return false;
        }
        var fresh: std.ArrayList([]const u8) = .empty;
        errdefer fresh.deinit(self.gpa);
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\n' or c == '\r') {
                try fresh.append(self.gpa, text[start..i]);
                if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
                i += 1;
                start = i;
            } else i += 1;
        }
        try fresh.append(self.gpa, text[start..]);
        self.hash = h;
        self.replaceText(text, fresh);
        self.fixed = helpers.detectFixedFormat(self.lines.items);
        return true;
    }

    pub const LoadError = error{ ReadFailed, OutOfMemory };

    /// Read the file from disk; returns whether its contents changed
    pub fn loadFromDisk(self: *FortranFile, io: Io) LoadError!bool {
        const data = Io.Dir.cwd().readFileAlloc(io, self.path, self.gpa, .limited(1 << 30)) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
        return self.setTextOwned(data);
    }

    pub fn getLine(self: *const FortranFile, line_no: usize, pp_content: bool) ?[]const u8 {
        if (line_no >= self.nLines()) return null;
        if (pp_content) if (self.pp_lines) |pl| return pl[line_no];
        return self.lines.items[line_no];
    }

    /// Get full code line from file including any adjacent continuations
    pub fn getCodeLine(self: *const FortranFile, a: Allocator, line_no: usize, forward: bool, backward: bool, pp_content: bool, strip_comment: bool) !CodeLine {
        var curr_line = self.getLine(line_no, pp_content) orelse return .{ .pre = &.{}, .curr = null, .post = &.{} };
        const n = self.nLines();
        var line_ind = line_no -| 1;
        var pre_lines: std.ArrayList([]const u8) = .empty;
        if (backward) {
            if (self.fixed) {
                var tmp_line = curr_line;
                while (line_ind > 0) {
                    if (R().FIXED_CONT.match(tmp_line) != null) {
                        const prev_line = tmp_line;
                        tmp_line = self.getLine(line_ind, pp_content) orelse "";
                        if (line_ind == line_no -| 1) {
                            curr_line = try std.mem.concat(a, u8, &.{ "      ", str.from(curr_line, 6) });
                        } else {
                            pre_lines.items[pre_lines.items.len - 1] = try std.mem.concat(a, u8, &.{ "      ", str.from(prev_line, 6) });
                        }
                        try pre_lines.append(a, tmp_line);
                    } else break;
                    line_ind -= 1;
                }
            } else {
                if (R().FREE_CONT.match(curr_line)) |m| {
                    curr_line = try std.mem.concat(a, u8, &.{ try str.spaces(a, m.end(0)), curr_line[m.end(0)..] });
                }
                while (line_ind > 0) {
                    const tmp_line = try helpers.stripStrings(a, self.getLine(line_ind, pp_content) orelse "", true);
                    var tmp_no_comm = str.beforeFirst(tmp_line, "!");
                    const cont_ind = std.mem.lastIndexOfScalar(u8, tmp_no_comm, '&');
                    if (R().FREE_CONT.match(tmp_no_comm)) |m| {
                        if (cont_ind == m.end(0) - 1) break;
                        tmp_no_comm = try std.mem.concat(a, u8, &.{ try str.spaces(a, m.end(0)), tmp_no_comm[m.end(0)..] });
                    }
                    if (cont_ind) |ci| {
                        try pre_lines.append(a, tmp_no_comm[0..ci]);
                    } else break;
                    line_ind -= 1;
                }
            }
        }
        line_ind = line_no + 1;
        var post_lines: std.ArrayList([]const u8) = .empty;
        if (forward) {
            if (self.fixed) {
                if (line_ind < n) {
                    var next_line = self.getLine(line_ind, pp_content) orelse "";
                    line_ind += 1;
                    var cont = R().FIXED_CONT.match(next_line) != null;
                    while (cont and line_ind < n) {
                        try post_lines.append(a, try std.mem.concat(a, u8, &.{ "      ", str.from(next_line, 6) }));
                        next_line = self.getLine(line_ind, pp_content) orelse "";
                        line_ind += 1;
                        cont = R().FIXED_CONT.match(next_line) != null;
                    }
                }
            } else {
                var line_stripped = try helpers.stripStrings(a, curr_line, true);
                var cont_amper = continuationAmpersand(line_stripped);
                var next_line: []const u8 = "";
                while (cont_amper) |amper| {
                    if (line_ind == line_no + 1) {
                        curr_line = str.upto(curr_line, amper);
                    } else if (next_line.len > 0) {
                        post_lines.items[post_lines.items.len - 1] = str.upto(next_line, amper);
                    }
                    next_line = self.getLine(line_ind, pp_content) orelse break;
                    line_ind += 1;
                    if (R().PP_ANY.match(next_line) != null) {
                        next_line = "";
                        try post_lines.append(a, "");
                        continue;
                    }
                    if (str.rstrip(next_line).len == 0 or R().FREE_COMMENT.match(next_line) != null) {
                        next_line = "";
                        try post_lines.append(a, "");
                        continue;
                    }
                    if (R().FREE_CONT.match(next_line)) |m| next_line = next_line[m.end(0)..];
                    try post_lines.append(a, next_line);
                    line_stripped = try helpers.stripStrings(a, next_line, true);
                    cont_amper = continuationAmpersand(line_stripped);
                }
            }
        }
        if (strip_comment) curr_line = self.stripComment(curr_line);
        std.mem.reverse([]const u8, pre_lines.items);
        return .{ .pre = pre_lines.items, .curr = curr_line, .post = post_lines.items };
    }

    pub fn stripComment(self: *const FortranFile, line: []const u8) []const u8 {
        if (self.fixed) {
            if (R().FIXED_COMMENT.match(line) != null and R().FIXED_OPENMP.match(line) == null) return "";
        } else {
            if (R().FREE_OPENMP.match(line) == null) return str.beforeFirst(line, "!");
        }
        return line;
    }

    pub fn findWordInCodeLine(self: *const FortranFile, a: Allocator, line_no_in: usize, word: []const u8, forward: bool, backward: bool, pp_content: bool) !struct { line: usize, range: Range } {
        var line_no = line_no_in;
        const cl = try self.getCodeLine(a, line_no, forward, backward, pp_content, false);
        var word_range: Range = .{ .start = -1, .end = -1 };
        if (cl.curr) |c| word_range = helpers.findWordInLineIgnoreCase(c, word);
        if (backward and word_range.start < 0) {
            var i: usize = cl.pre.len;
            var k: usize = 0;
            while (i > 0) : (k += 1) {
                i -= 1;
                word_range = helpers.findWordInLineIgnoreCase(cl.pre[i], word);
                if (word_range.start >= 0) {
                    line_no -|= k + 1;
                    return .{ .line = line_no, .range = word_range };
                }
            }
        }
        if (forward and word_range.start < 0) {
            for (cl.post, 0..) |l, i| {
                word_range = helpers.findWordInLineIgnoreCase(l, word);
                if (word_range.start >= 0) {
                    line_no += i + 1;
                    return .{ .line = line_no, .range = word_range };
                }
            }
        }
        return .{ .line = line_no, .range = word_range };
    }

    /// Apply a change to the file; returns whether a reparse is required
    pub fn applyChange(self: *FortranFile, change: Change) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        self.hash = null;
        const text = change.text;
        const text_split: []const []const u8 = if (text.len == 0) &.{""} else try splitLines(a, text);
        const rng = change.range orelse {
            try self.setContents(text_split, true);
            return true;
        };
        const n = self.nLines();
        if (rng.sl == n) {
            var all: std.ArrayList([]const u8) = .empty;
            for (self.lines.items) |l| try all.append(a, l);
            try all.appendSlice(a, text_split);
            try self.setContents(all.items, true);
            return true;
        }
        if (rng.sl > n or rng.el >= n + 1) return error.InvalidRange;
        const start_line = self.lines.items[rng.sl];
        const end_line = if (rng.el < n) self.lines.items[rng.el] else "";
        const start_col = @min(str.utf16ToByte(start_line, rng.sc), start_line.len);
        const end_col = @min(str.utf16ToByte(end_line, rng.ec), end_line.len);

        // Single line edit
        if (rng.sl == rng.el and text_split.len == 1) {
            const prev = self.lines.items[rng.sl];
            const new_line = try std.mem.concat(a, u8, &.{ prev[0..start_col], text, prev[@max(end_col, start_col)..] });
            const replaced = try a.dupe([]const u8, self.lines.items);
            replaced[rng.sl] = new_line;
            // The buffer is rebuilt, which the preprocessed lines that are
            // the raw lines themselves must follow; the others are in pp_arena
            const old_pp = self.pp_lines;
            var raw: []bool = &.{};
            if (old_pp) |pl| {
                raw = try a.alloc(bool, pl.len);
                const lo = @intFromPtr(self.text.ptr);
                const hi = lo + self.text.len;
                for (pl, raw) |l, *r| r.* = @intFromPtr(l.ptr) >= lo and @intFromPtr(l.ptr) < hi;
            }
            try self.setContents(replaced, false);
            if (old_pp) |pl| {
                for (pl, raw, 0..) |*l, r, i| {
                    if (r) l.* = self.lines.items[i];
                }
                pl[rng.sl] = try self.pp_arena.allocator().dupe(u8, self.lines.items[rng.sl]);
                self.pp_lines = pl;
            }
            return self.checkChangeReparse(@intCast(rng.sl));
        }

        var new_contents: std.ArrayList([]const u8) = .empty;
        for (self.lines.items, 0..) |line, i| {
            if (i < rng.sl or i > rng.el) {
                try new_contents.append(a, line);
                continue;
            }
            if (i == rng.sl) {
                for (text_split, 0..) |cl, j| {
                    if (j == 0) {
                        try new_contents.append(a, try std.mem.concat(a, u8, &.{ line[0..start_col], cl }));
                    } else {
                        try new_contents.append(a, cl);
                    }
                }
            }
            if (i == rng.el) {
                const last = new_contents.items.len - 1;
                new_contents.items[last] = try std.mem.concat(a, u8, &.{ new_contents.items[last], line[end_col..] });
            }
        }
        try self.setContents(new_contents.items, true);
        return true;
    }

    fn checkChangeReparse(self: *FortranFile, line_no: usize) !bool {
        if (line_no >= self.nLines()) return true;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const cl = try self.getCodeLine(a, line_no, false, true, false, false);
        const curr_line = cl.curr.?;
        if (self.fixed) {
            if (R().FIXED_COMMENT.match(curr_line) != null) return false;
        } else {
            if (R().FREE_COMMENT.match(curr_line) != null) return false;
        }
        var full_line: []const u8 = try std.mem.concat(a, u8, &.{ try std.mem.concat(a, u8, cl.pre), curr_line });
        const lr = try helpers.stripLineLabel(a, full_line);
        full_line = lr.line;
        if (lr.label != null) return true;
        const line_stripped = try helpers.stripStrings(a, full_line, true);
        if (std.mem.indexOfScalar(u8, line_stripped, ';') != null) return true;
        const line_no_comment = if (std.mem.indexOfScalar(u8, line_stripped, '!')) |ci| full_line[0..ci] else full_line;
        if (R().END_WORD.match(line_no_comment) != null) return true;
        if (R().IMPLICIT.match(line_no_comment) != null) return true;
        if (R().CONTAINS.match(line_no_comment) != null) return true;
        if (R().NON_DEF.match(line_no_comment) != null) return false;
        return (try getFortranDefinition(a, line_no_comment)) != null;
    }

    /// Run the preprocessor over the file contents
    pub fn preprocess(self: *FortranFile, io: Io, defs: ?*const pp.Defs, include_dirs: []const []const u8, trace: ?Trace) !pp.Output {
        _ = self.pp_arena.reset(.free_all);
        self.pp_lines = null;
        self.pp_defs = .empty;
        const a = self.pp_arena.allocator();
        const out = try pp.preprocessFile(a, io, self.lines.items, self.path, defs, include_dirs, trace);
        self.pp_lines = out.lines;
        self.pp_defs = out.defs;
        return out;
    }

    // ----------------------------------------------------------------------
    // Diagnostics

    pub const FileDiags = struct {
        built: std.ArrayList(objects.BuiltDiag) = .empty,
    };

    /// Port of `FortranFile.check_file`
    pub fn checkFile(self: *FortranFile, env: objects.Env, max_line_length: i64, max_comment_line_length: i64) ![]objects.BuiltDiag {
        const a = env.tmp;
        const ast = self.ast orelse return &.{};
        var out: std.ArrayList(objects.BuiltDiag) = .empty;
        const res = try ast.checkFile(env);
        try out.appendSlice(a, res.parse_errors);
        if (max_line_length > 0 or max_comment_line_length > 0) {
            const msg_line = try std.fmt.allocPrint(a, "Line length exceeds \"max_line_length\" ({d})", .{max_line_length});
            const msg_comment = try std.fmt.allocPrint(a, "Comment line length exceeds \"max_comment_line_length\" ({d})", .{max_comment_line_length});
            const comment_re = if (self.fixed) &R().FIXED_COMMENT else &R().FREE_COMMENT;
            // a limit that is not positive is off
            const max_code: usize = @intCast(@max(max_line_length, 0));
            const max_comment: usize = @intCast(@max(max_comment_line_length, 0));
            for (self.lines.items, 0..) |line, ln| {
                const len = str.codepointLen(line);
                if (comment_re.match(line) == null) {
                    // Code is held to max_line_length; a comment after it is
                    // held to max_comment_line_length, not to the code limit
                    // (upstream #489)
                    const stripped = try helpers.stripStrings(a, line, true);
                    const has_comment = std.mem.indexOfScalar(u8, stripped, '!');
                    const code = if (has_comment) |ci| str.rstrip(line[0..ci]) else line;
                    const code_len = str.codepointLen(code);
                    if (0 < max_code and max_code < code_len) {
                        try out.append(a, .{ .sln = ln, .sch = max_code, .eln = ln, .ech = code_len, .message = msg_line, .severity = C.Severity.warn, .cols_are_codepoints = true });
                    }
                    if (has_comment != null and 0 < max_comment and max_comment < len) {
                        try out.append(a, .{ .sln = ln, .sch = max_comment, .eln = ln, .ech = len, .message = msg_comment, .severity = C.Severity.warn, .cols_are_codepoints = true });
                    }
                } else {
                    if (0 < max_comment and max_comment < len) {
                        try out.append(a, .{ .sln = ln, .sch = max_comment, .eln = ln, .ech = len, .message = msg_comment, .severity = C.Severity.warn, .cols_are_codepoints = true });
                    }
                }
            }
        }
        for (res.errors) |e| try out.append(a, try e.build(a, self));
        return out.items;
    }

    // ----------------------------------------------------------------------
    // Parsing

    /// Parse the file contents and build a new AST (the caller owns it)
    pub fn parse(self: *FortranFile, io: Io, defs: ?*const pp.Defs, include_dirs: []const []const u8, opts: Options) !*Ast {
        var p: Parser = .{
            .opts = opts,
            .file = self,
            .file_ast = try Ast.create(self.gpa, self),
            .scratch = std.heap.ArenaAllocator.init(self.gpa),
        };
        defer p.scratch.deinit();
        errdefer p.file_ast.destroy();
        if (self.preproc) {
            p.dbg("=== PreProc Pass ===\n", .{});
            const out = try self.preprocess(io, defs, include_dirs, opts.trace);
            p.pp_skips = out.skips;
            p.pp_defines = out.defines;
            // an `#include` links the file like an INCLUDE statement would
            for (out.includes) |inc| try p.file_ast.addInclude(inc.path, inc.line);
            p.dbg("\n=== Parsing Pass ===\n", .{});
        } else {
            p.dbg("=== No PreProc ===\n", .{});
            self.pp_lines = null;
        }
        try p.run();
        return p.file_ast;
    }
};

const Counters = struct {
    do_: u32 = 0,
    if_: u32 = 0,
    block: u32 = 0,
    select: u32 = 0,
    interface: u32 = 0,
};

const Parser = struct {
    opts: Options,
    file: *FortranFile,
    file_ast: *Ast,
    scratch: std.heap.ArenaAllocator,
    pp_skips: []const pp.Skip = &.{},
    pp_defines: []const usize = &.{},
    docs: std.ArrayList([]const u8) = .empty,
    comment_re: *const regex.Regex = undefined,
    cur_line: usize = 0,
    doc_re: *const regex.Regex = undefined,

    fn dbg(p: *const Parser, comptime fmt: []const u8, args: anytype) void {
        Trace.print(p.opts.trace, fmt, args);
    }

    fn run(p: *Parser) !void {
        const f = p.file;
        const ast = p.file_ast;
        const sa = p.scratch.allocator();
        if (f.fixed) {
            p.comment_re = &R().FIXED_COMMENT;
            p.doc_re = &R().FIXED_DOC;
        } else {
            p.comment_re = &R().FREE_COMMENT;
            p.doc_re = &R().FREE_DOC;
        }
        const n_lines = f.nLines();
        var line_no: usize = 0;
        var line_no_end: usize = 0;
        var block_id_stack: std.ArrayList([]const u8) = .empty;
        var counters: Counters = .{};
        // stack of pending statements split by ';' (popped from the end)
        var multi_lines: std.ArrayList([]const u8) = .empty;

        // Per-line temporary arena
        var line_arena = std.heap.ArenaAllocator.init(f.gpa);
        defer line_arena.deinit();

        while (line_no_end < n_lines or multi_lines.items.len > 0) {
            if (multi_lines.items.len == 0) _ = line_arena.reset(.retain_capacity);
            const a = line_arena.allocator();
            var line: []const u8 = undefined;
            var get_full: bool = undefined;
            if (multi_lines.items.len == 0) {
                line_no = if (line_no_end > line_no) line_no_end else line_no;
                line = f.getLine(line_no, true) orelse "";
                line_no += 1;
                line_no_end = line_no;
                get_full = true;
            } else {
                line = multi_lines.pop().?;
                get_full = false;
            }
            if (line.len == 0) continue;
            // a fixed-form comment line (C, D or * in column 1) has no code,
            // whatever it contains, even a semicolon (#411)
            if (get_full and f.fixed and std.mem.indexOfScalar(u8, "cCdD*", line[0]) != null) continue;

            p.cur_line = line_no;
            if (try p.parseDocs(line, line_no)) |idx| {
                line_no = idx;
                line_no_end = line_no;
                continue;
            }
            // Handle preprocessing regions
            var do_skip = false;
            for (p.pp_skips) |reg| {
                if (line_no >= reg.start and line_no <= reg.end) {
                    do_skip = true;
                    break;
                }
            }
            for (p.pp_defines) |d| if (d == line_no) {
                do_skip = true;
            };
            if (do_skip) continue;

            if (get_full) {
                const cl = try f.getCodeLine(a, line_no -| 1, true, false, true, false);
                line_no_end += @intCast(cl.post.len);
                var parts: std.ArrayList([]const u8) = .empty;
                try parts.append(a, cl.curr.?);
                try parts.appendSlice(a, cl.post);
                line = try std.mem.concat(a, u8, parts.items);
            }
            const lr = try helpers.stripLineLabel(a, line);
            line = lr.line;
            const line_label = lr.label;
            var line_stripped = try helpers.stripStrings(a, line, true);
            var line_no_comment = line;
            if (std.mem.indexOfScalar(u8, line_stripped, '!')) |ci| {
                line_no_comment = line[0..ci];
                line_stripped = line_stripped[0..ci];
                try p.setSingleLineDocstring(line[ci..]);
            }
            if (std.mem.indexOfScalar(u8, line_stripped, ';') != null) {
                const pieces = try str.split(sa, line_stripped, ";");
                // extendleft + pop: process pieces in order
                var k: usize = pieces.len;
                var tmp: std.ArrayList([]const u8) = .empty;
                while (k > 0) {
                    k -= 1;
                    try tmp.append(sa, try sa.dupe(u8, pieces[k]));
                }
                // existing entries stay on the left (bottom) of the stack
                var merged: std.ArrayList([]const u8) = .empty;
                try merged.appendSlice(sa, multi_lines.items);
                try merged.appendSlice(sa, tmp.items);
                multi_lines = merged;
                // deque.extendleft puts pieces on the left; pop() takes from the
                // right, so existing entries are processed first. Since the
                // stack is empty here in practice, take the first piece.
                line = multi_lines.pop().?;
                line_stripped = line;
                line_no_comment = line;
            }
            // Test for scope end
            if (ast.end_scope_regex != null) {
                const m = R().END_WORD.match(line_no_comment);
                if (try p.parseEndScopeWord(line_no_comment, line_no, m)) {
                    ast.pending_doc = null;
                    continue;
                }
                if (try p.parseDoFixedFormat(line, line_no, line_label, &block_id_stack)) {
                    ast.pending_doc = null;
                    continue;
                }
            }
            // A `!>` comment documents what follows it, not a statement that
            // cannot have documentation: it must not wait for a later
            // procedure (upstream #237)
            if (R().NON_DEF.match(line_no_comment) != null) {
                ast.pending_doc = null;
                continue;
            }
            if (try p.parseParameterStmt(a, line_no_comment)) {
                ast.pending_doc = null;
                continue;
            }
            if (try p.parseImplicit(line_no_comment, line_no)) {
                ast.pending_doc = null;
                continue;
            }
            if (try p.parseContains(line_no_comment, line_no)) {
                ast.pending_doc = null;
                continue;
            }
            const obj_read = (try getFortranDefinition(a, line)) orelse continue;
            try p.handleDef(a, obj_read, line, line_no, &counters, &block_id_stack);
        }
        try ast.closeFile(line_no);
    }

    fn handleDef(p: *Parser, a: Allocator, obj_read: DefResult, line: []const u8, line_no: usize, counters: *Counters, block_id_stack: *std.ArrayList([]const u8)) !void {
        const ast = p.file_ast;
        const pa = ast.allocator();
        switch (obj_read) {
            .var_ => |info| {
                const var_names = info.var_names orelse return;
                var procedure_def = false;
                if (std.mem.startsWith(u8, info.var_type, "PRO")) {
                    if (ast.current_scope) |cs| if (cs.getType(false) == C.TypeId.interface) {
                        for (var_names) |vn| try ast.addIntMember(vn);
                        p.dbg("{s} !!! INTERFACE-PRO - Ln:{d}", .{ str.strip(line), line_no });
                        return;
                    };
                    procedure_def = true;
                }
                for (var_names) |var_name| {
                    var desc: []const u8 = info.var_type;
                    var link_name: ?[]const u8 = null;
                    var name: []const u8 = undefined;
                    if (std.mem.indexOf(u8, var_name, "=>")) |_| {
                        const parts = try str.split(a, var_name, "=>");
                        name = parts[0];
                        const ln = str.strip(str.beforeFirst(parts[1], "("));
                        link_name = if (std.ascii.eqlIgnoreCase(ln, "null")) null else ln;
                    } else {
                        name = str.beforeFirst(var_name, "=");
                    }
                    var var_keywords: std.ArrayList([]const u8) = .empty;
                    try var_keywords.appendSlice(a, info.keywords);
                    if (std.mem.startsWith(u8, name, "(")) continue;
                    const dim = try parseImpDim(a, name);
                    name = dim.line;
                    const chr = try parseImpChar(a, name);
                    name = chr.line;
                    if (dim.extra) |d| try var_keywords.append(a, d);
                    if (chr.extra) |c| desc = try std.mem.concat(a, u8, &.{ desc, c });
                    // the codimensions of a coarray, x[:], are not part of its name (upstream #172)
                    if (std.mem.indexOfScalar(u8, name, '[')) |bracket| name = name[0..bracket];
                    name = str.strip(name);
                    const mk = try helpers.mapKeywords(a, var_keywords.items, p.opts.sort_keywords);
                    var new_var: *Obj = undefined;
                    if (procedure_def) {
                        new_var = try Obj.newMethod(ast, line_no, name, desc, mk.ids, mk.info, info.var_kind, link_name);
                    } else {
                        new_var = try Obj.newVariable(ast, line_no, name, desc, mk.ids, .{
                            .keyword_info = mk.info,
                            .kind = info.var_kind,
                            .link_obj = link_name,
                        });
                        if (new_var.isParameter()) {
                            const r = helpers.findWordInLine(line, name);
                            const col: usize = @intCast(@max(r.end, 0));
                            if (helpers.parameterValue(str.from(line, col))) |value| {
                                const words = try str.splitWhitespace(a, value);
                                new_var.param_val = try pa.dupe(u8, try std.mem.join(a, " ", words));
                            }
                        }
                        if (try findExternal(ast, desc, name, new_var)) continue;
                    }
                    try ast.addVariable(new_var);
                }
                p.dbg("{s} !!! VARIABLE - Ln:{d}", .{ line, line_no });
            },
            .mod => |name| {
                const o = try Obj.newScope(ast, .module, line_no, name, &.{});
                try ast.addScope(o, &R().END_MOD, true, false);
                p.dbg("{s} !!! MODULE - Ln:{d}", .{ line, line_no });
            },
            .smod => |info| {
                const o = try Obj.newSubmodule(ast, line_no, info.name, info.parent);
                try ast.addScope(o, &R().END_SMOD, true, false);
                p.dbg("{s} !!! SUBMODULE - Ln:{d}", .{ line, line_no });
            },
            .prog => |name| {
                const o = try Obj.newScope(ast, .program, line_no, name, &.{});
                try ast.addScope(o, &R().END_PROG, true, false);
                p.dbg("{s} !!! PROGRAM - Ln:{d}", .{ line, line_no });
            },
            .sub => |info| {
                const mk = try helpers.mapKeywords(a, info.keywords, p.opts.sort_keywords);
                const o = try Obj.newSubroutine(ast, line_no, info.name, info.args, info.mod_flag, mk.ids);
                try ast.addScope(o, &R().END_SUB, true, false);
                p.dbg("{s} !!! SUBROUTINE - Ln:{d}", .{ line, line_no });
            },
            .fun => |info| {
                const mk = try helpers.mapKeywords(a, info.keywords, p.opts.sort_keywords);
                const o = try Obj.newFunction(ast, line_no, info.name, .{
                    .args = info.args,
                    .mod_flag = info.mod_flag,
                    .keywords = mk.ids,
                    .keyword_info = mk.info,
                    .result_type = info.result.type,
                    .result_name = info.result.name,
                });
                try ast.addScope(o, &R().END_FUN, true, false);
                if (info.result.type) |rt| if (rt.len > 0) {
                    const rk = try helpers.mapKeywords(a, info.result.keywords, p.opts.sort_keywords);
                    const v = try Obj.newVariable(ast, line_no, info.result.name orelse info.name, rt, rk.ids, .{
                        .keyword_info = rk.info,
                        .kind = info.result.kind,
                    });
                    try ast.addVariable(v);
                };
                p.dbg("{s} !!! FUNCTION - Ln:{d}", .{ line, line_no });
            },
            .block => |name_opt| {
                var name = name_opt orelse "";
                if (name_opt == null) {
                    counters.block += 1;
                    name = try std.fmt.allocPrint(a, "#BLOCK{d}", .{counters.block});
                }
                const o = try Obj.newScope(ast, .block, line_no, name, &.{});
                try ast.addScope(o, &R().END_BLOCK, true, true);
                p.dbg("{s} !!! BLOCK - Ln:{d}", .{ line, line_no });
            },
            .block_data => |name_opt| {
                var name = name_opt orelse "";
                if (name_opt == null) {
                    counters.block += 1;
                    name = try std.fmt.allocPrint(a, "#BLOCKDATA{d}", .{counters.block});
                }
                const o = try Obj.newScope(ast, .block, line_no, name, &.{});
                try ast.addScope(o, &R().END_BLOCK_DATA, true, false);
                p.dbg("{s} !!! BLOCK DATA - Ln:{d}", .{ line, line_no });
            },
            .do_ => |label| {
                counters.do_ += 1;
                const name = try std.fmt.allocPrint(a, "#DO{d}", .{counters.do_});
                if (label.len > 0) try block_id_stack.append(p.scratch.allocator(), try p.scratch.allocator().dupe(u8, label));
                const o = try Obj.newScope(ast, .do_, line_no, name, &.{});
                try ast.addScope(o, &R().END_DO, true, true);
                p.dbg("{s} !!! DO - Ln:{d}", .{ line, line_no });
            },
            .where => |single| {
                if (!single) {
                    counters.do_ += 1;
                    const name = try std.fmt.allocPrint(a, "#WHERE{d}", .{counters.do_});
                    const o = try Obj.newScope(ast, .where, line_no, name, &.{});
                    try ast.addScope(o, &R().END_WHERE, true, true);
                }
                p.dbg("{s} !!! WHERE - Ln:{d}", .{ line, line_no });
            },
            .assoc => |bound| {
                counters.block += 1;
                const name = try std.fmt.allocPrint(a, "#ASSOC{d}", .{counters.block});
                const o = try Obj.newScope(ast, .associate, line_no, name, &.{});
                try ast.addScope(o, &R().END_ASSOCIATE, true, true);
                for (bound) |bv| {
                    const parts = try str.split(a, bv, "=>");
                    if (parts.len != 2) continue;
                    const bind_name = str.strip(parts[0]);
                    const link = str.strip(parts[1]);
                    const v = try Obj.newVariable(ast, line_no, bind_name, "UNKNOWN", &.{}, .{});
                    if (helpers.getParenSubstring(link)) |subscripts| {
                        var rank: i32 = 0;
                        for (try helpers.splitArgs(a, subscripts)) |sub| {
                            if (std.mem.indexOfScalar(u8, sub, ':') != null) rank += 1;
                        }
                        v.slice_rank = rank;
                    }
                    try o.links.append(pa, .{ .var_ = v, .bind_name = try pa.dupe(u8, bind_name), .link_name = try pa.dupe(u8, link) });
                    try ast.addVariable(v);
                }
                p.dbg("{s} !!! ASSOCIATE - Ln:{d}", .{ line, line_no });
            },
            .if_ => {
                counters.if_ += 1;
                const name = try std.fmt.allocPrint(a, "#IF{d}", .{counters.if_});
                const o = try Obj.newScope(ast, .if_, line_no, name, &.{});
                try ast.addScope(o, &R().END_IF, true, true);
                p.dbg("{s} !!! IF - Ln:{d}", .{ line, line_no });
            },
            .select => |info| {
                counters.select += 1;
                const name = try std.fmt.allocPrint(a, "#SELECT{d}", .{counters.select});
                const o = try Obj.newSelect(ast, line_no, name, info);
                try ast.addScope(o, &R().END_SELECT, true, true);
                const var_desc = try std.fmt.allocPrint(a, "{s}({s})", .{ info.desc orelse "None", info.binding orelse "None" });
                if (try createSelectBindingVariable(o, ast, line_no, var_desc, info.type)) |v| try ast.addVariable(v);
                p.dbg("{s} !!! SELECT - Ln:{d}", .{ line, line_no });
            },
            .typ => |info| {
                const mk = try helpers.mapKeywords(a, info.keywords, p.opts.sort_keywords);
                const o = try Obj.newScope(ast, .type, line_no, info.name, mk.ids);
                if (info.parent) |par| o.inherit = try pa.dupe(u8, par);
                try ast.addScope(o, &R().END_TYPED, true, true);
                p.dbg("{s} !!! TYPE - Ln:{d}", .{ line, line_no });
            },
            .enum_ => {
                counters.block += 1;
                const name = try std.fmt.allocPrint(a, "#ENUM{d}", .{counters.block});
                const o = try Obj.newScope(ast, .enum_, line_no, name, &.{});
                try ast.addScope(o, &R().END_ENUMD, true, true);
                p.dbg("{s} !!! ENUM - Ln:{d}", .{ line, line_no });
            },
            .int => |info| {
                var name = info.name orelse "";
                if (info.name == null) {
                    counters.interface += 1;
                    name = try std.fmt.allocPrint(a, "#GEN_INT{d}", .{counters.interface});
                }
                const o = try Obj.newInterface(ast, line_no, name, info.abstract);
                try ast.addScope(o, &R().END_INT, true, true);
                p.dbg("{s} !!! INTERFACE - Ln:{d}", .{ line, line_no });
            },
            .gen => |info| {
                const o = try Obj.newInterface(ast, line_no, info.bound_name, false);
                o.vis = info.vis_flag;
                try ast.addScope(o, &R().END_INT, true, true);
                for (info.pro_links) |pl| try ast.addIntMember(pl);
                try ast.endScope(line_no, true);
                p.dbg("{s} !!! GENERIC - Ln:{d}", .{ line, line_no });
            },
            .int_pro => |names| {
                if (ast.current_scope) |cs| {
                    if (cs.getType(false) == C.TypeId.interface) {
                        for (names) |nm| try ast.addIntMember(nm);
                        p.dbg("{s} !!! INTERFACE-PRO - Ln:{d}", .{ line, line_no });
                    } else if (cs.getType(false) == C.TypeId.submodule) {
                        const o = try Obj.newScope(ast, .scope, line_no, names[0], &.{});
                        try ast.addScope(o, &R().END_PRO, true, false);
                        p.dbg("{s} !!! INTERFACE-IMPL - Ln:{d}", .{ line, line_no });
                    }
                }
            },
            .use => |info| {
                const u = try UseStmt.init(pa, info.mod_name, info.only_list, info.renames);
                u.line_number = line_no;
                try ast.addUse(u);
                p.dbg("{s} !!! USE - Ln:{d}", .{ line, line_no });
            },
            .import => |info| {
                // fortls appends counters["import"], which is always 0
                const u = try UseStmt.init(pa, "#import0", info.only_list, &.{});
                u.is_import = true;
                u.import_type = info.import_type;
                u.line_number = line_no;
                try ast.addUse(u);
                p.dbg("{s} !!! IMPORT - Ln:{d}", .{ line, line_no });
            },
            .inc => |path| {
                try ast.addInclude(path, line_no);
                p.dbg("{s} !!! INCLUDE - Ln:{d}", .{ line, line_no });
            },
            .vis => |info| {
                if (ast.current_scope) |cs| {
                    if (info.obj_names.len == 0 and info.private) {
                        cs.def_vis = .private;
                    } else if (info.private) {
                        for (info.obj_names) |w| try ast.addPrivate(w);
                    } else {
                        for (info.obj_names) |w| try ast.addPublic(w);
                    }
                } else {
                    try ast.addError("Visibility statement without enclosing scope", C.Severity.err, line_no, 0, null);
                }
                p.dbg("{s} !!! VISIBILITY - Ln:{d}", .{ line, line_no });
            },
        }
    }

    fn parseEndScopeWord(p: *Parser, line: []const u8, ln: usize, match: ?regex.Match) !bool {
        const m = match orelse return false;
        const ast = p.file_ast;
        const cs = ast.current_scope orelse return false;
        var end_scope_word: ?[]const u8 = null;
        if (m.group(1) == null) {
            end_scope_word = "";
            if (cs.reqNamedEnd() and cs != ast.none_scope) {
                try ast.end_errors.append(ast.allocator(), .{ .end_line = ln, .scope_line = cs.sline });
            }
        } else {
            if (ast.end_scope_regex.?.match(line[m.start(1)..])) |sm| end_scope_word = sm.str();
        }
        if (end_scope_word != null) {
            if (cs.getType(false) == C.TypeId.select and cs.isTypeRegion()) try ast.endScope(ln, true);
            try ast.endScope(ln, true);
            if (p.opts.trace != null) {
                var ub: [64]u8 = undefined;
                const w = end_scope_word.?;
                const n = @min(w.len, ub.len);
                p.dbg("{s} !!! END {s} Scope - Ln:{d}", .{ line, std.ascii.upperString(ub[0..n], w[0..n]), ln });
            }
            return true;
        }
        return false;
    }

    fn parseDoFixedFormat(p: *Parser, line: []const u8, ln: usize, line_label: ?[]const u8, block_id_stack: *std.ArrayList([]const u8)) !bool {
        const ast = p.file_ast;
        const cs = ast.current_scope orelse return false;
        const label = line_label orelse return false;
        if (cs.getType(false) != C.TypeId.do_) return false;
        var did_close = false;
        while (block_id_stack.items.len > 0 and std.mem.eql(u8, label, block_id_stack.items[block_id_stack.items.len - 1])) {
            try ast.endScope(ln, true);
            _ = block_id_stack.pop();
            did_close = true;
            p.dbg("{s} !!! END DO-LABELLED - Ln:{d}", .{ line, ln });
        }
        return did_close;
    }

    /// `PARAMETER (name = value, ...)`: makes variables already declared in
    /// the current scope constants, with their values (upstream #203)
    fn parseParameterStmt(p: *Parser, a: Allocator, line: []const u8) !bool {
        const m = R().PARAMETER_STMT.match(line) orelse return false;
        const ast = p.file_ast;
        const cs = ast.current_scope orelse return false;
        const pa = ast.allocator();
        for (try helpers.splitArgs(a, m.group(1) orelse "")) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            const name = str.strip(item[0..eq]);
            for (cs.children.items) |child| {
                if (child.kind != .variable or !std.ascii.eqlIgnoreCase(child.name, name)) continue;
                if (!child.is_const) {
                    child.is_const = true;
                    try child.keywords.append(pa, C.KW.parameter);
                }
                const words = try str.splitWhitespace(a, str.strip(item[eq + 1 ..]));
                child.param_val = try pa.dupe(u8, try std.mem.join(a, " ", words));
            }
        }
        p.dbg("{s} !!! PARAMETER statement - Ln:{d}", .{ str.strip(line), p.cur_line });
        return true;
    }

    fn parseImplicit(p: *Parser, line: []const u8, ln: usize) !bool {
        const m = R().IMPLICIT.match(line) orelse return false;
        const ast = p.file_ast;
        if (ast.current_scope) |cs| {
            cs.setImplicit(!std.ascii.eqlIgnoreCase(m.group(1).?, "none"), ln);
        } else {
            try ast.addError("IMPLICIT statement without enclosing scope", C.Severity.err, ln, @intCast(m.start(1)), @intCast(m.end(1)));
        }
        p.dbg("{s} !!! IMPLICIT - Ln:{d}", .{ line, ln });
        return true;
    }

    fn parseContains(p: *Parser, line: []const u8, ln: usize) !bool {
        const m = R().CONTAINS.match(line) orelse return false;
        const ast = p.file_ast;
        var msg: ?[]const u8 = null;
        if (ast.current_scope) |cs| {
            cs.markContains(ln) catch {
                msg = "Multiple CONTAINS statements in scope";
            };
        } else {
            msg = "CONTAINS statement without enclosing scope";
        }
        if (msg) |mm| try ast.addError(mm, C.Severity.err, ln, @intCast(m.start(1)), @intCast(m.end(1)));
        p.dbg("{s} !!! CONTAINS - Ln:{d}", .{ line, ln });
        return true;
    }

    fn setSingleLineDocstring(p: *Parser, line: []const u8) !void {
        p.docs = .empty;
        const m = R().FREE_DOC.match(line) orelse return;
        const doc = str.strip(line[m.end(0)..]);
        if (doc.len > 0) try p.docs.append(p.scratch.allocator(), try p.scratch.allocator().dupe(u8, doc));
    }

    fn formatDocs(p: *Parser, docs: []const []const u8) ![]const u8 {
        const a = p.scratch.allocator();
        if (docs.len == 1) return docs[0];
        var docstr: std.ArrayList(u8) = .empty;
        var has_args = true;
        var idx_args: isize = -1;
        for (docs) |line| {
            if (std.mem.startsWith(u8, line, "@brief")) {
                try docstr.appendSlice(a, str.strip(try str.replaceFirst(a, line, "@brief", "")));
                try docstr.append(a, '\n');
            } else if (std.mem.startsWith(u8, line, "@param")) {
                if (has_args) {
                    try docstr.appendSlice(a, "\n**Parameters:**  \n");
                    has_args = false;
                    idx_args = @intCast(docstr.items.len);
                }
                try docstr.appendSlice(a, try R().DOC_PARAM.sub(a, "  \\n`\\1` - ", try std.mem.concat(a, u8, &.{ line, " " })));
            } else if (std.mem.startsWith(u8, line, "@return")) {
                try docstr.appendSlice(a, "\n**Returns:**  \n");
                try docstr.appendSlice(a, str.strip(try str.replaceFirst(a, line, "@return", "")));
                try docstr.append(a, '\n');
            } else {
                try docstr.appendSlice(a, str.strip(line));
                try docstr.append(a, '\n');
            }
        }
        if (idx_args > 0) {
            const ia: usize = @intCast(idx_args);
            const head = str.slice(docstr.items, 0, idx_args - 3);
            const tail = try str.replaceFirst(a, docstr.items[ia..], "  \n ", "");
            return std.mem.concat(a, u8, &.{ head, tail });
        }
        return docstr.items;
    }

    fn addLineComment(p: *Parser) !void {
        if (p.docs.items.len > 0) {
            const fd = try p.formatDocs(p.docs.items);
            try p.file_ast.addDoc(fd, false);
            p.dbg("{s} !!! Doc string - Line:{d}", .{ fd, p.cur_line });
            p.docs.clearRetainingCapacity();
        }
    }

    /// Parse documentation strings; returns the new line number, or null when the line is no documentation
    fn parseDocs(p: *Parser, line: []const u8, ln: usize) !?usize {
        if (p.comment_re.match(line) == null) {
            try p.addLineComment();
            return null;
        }
        const doc_match = p.doc_re.match(line) orelse {
            try p.addLineComment();
            return null;
        };
        const sa = p.scratch.allocator();
        // get_docstring
        try p.docs.append(sa, str.strip(line[doc_match.end(0)..]));
        const predocmark = std.mem.eql(u8, doc_match.group(1).?, ">");
        var new_ln = ln;
        const n = p.file.nLines();
        if (ln < n) {
            var i = ln;
            while (i < n) : (i += 1) {
                const next_line = p.file.getLine(i, true) orelse "";
                const m = p.doc_re.match(next_line) orelse {
                    new_ln = i;
                    break;
                };
                try p.docs.append(sa, str.strip(next_line[m.end(0)..]));
            }
        }
        var total: usize = 0;
        for (p.docs.items) |d| total += d.len;
        if (total > 0) try p.file_ast.addDoc(try p.formatDocs(p.docs.items), predocmark);
        for (p.docs.items, 0..) |d, k| p.dbg("{s} !!! Doc string - Line:{d}", .{ d, ln + k });
        p.docs.clearRetainingCapacity();
        return new_ln;
    }
};

fn createSelectBindingVariable(self: *Obj, ast: *Ast, line_number: usize, var_desc: []const u8, case_type: i32) !?*Obj {
    const parent = self.parent orelse return null;
    if (parent.getType(false) != C.TypeId.select) return null;
    var binding_name: ?[]const u8 = null;
    var bound_var: ?[]const u8 = null;
    if (parent.isTypeBinding()) {
        binding_name = parent.binding_name;
        bound_var = parent.bound_var;
    }
    if (binding_name != null and case_type != 4) bound_var = null;
    if (binding_name) |bn| {
        return try Obj.newVariable(ast, line_number, bn, var_desc, &.{}, .{ .link_obj = bound_var });
    } else if (bound_var) |bv| {
        return try Obj.newVariable(ast, line_number, bv, var_desc, &.{}, .{});
    }
    return null;
}

const Split = struct { line: []const u8, extra: ?[]const u8 };

/// Parse the implicit dimension of an array e.g. var(3,4)
fn parseImpDim(a: Allocator, line: []const u8) !Split {
    const m = R().IMP_DIM.match(line) orelse return .{ .line = line, .extra = null };
    const i = helpers.findParenMatch(line[m.end(1)..]);
    if (i < 0) return .{ .line = line, .extra = null };
    const iu: usize = @intCast(i);
    const dims = line[m.start(1) .. m.end(1) + iu + 1];
    const rest = try std.mem.concat(a, u8, &.{ line[0..m.start(1)], line[m.end(1) + iu + 1 ..] });
    return .{ .line = rest, .extra = try std.mem.concat(a, u8, &.{ "dimension", dims }) };
}

/// Parse the implicit character length from a variable e.g. var_name*10
fn parseImpChar(a: Allocator, line: []const u8) !Split {
    const m = R().IMP_CHAR.match(line) orelse return .{ .line = line, .extra = null };
    const g2 = m.group(2).?;
    var char_len: []const u8 = undefined;
    if (std.mem.eql(u8, g2, "(")) {
        const i = helpers.findParenMatch(line[m.end(2)..]);
        if (i < 0) return .{ .line = line, .extra = null };
        char_len = line[m.start(2) .. m.end(2) + @as(usize, @intCast(i)) + 1];
    } else {
        char_len = g2;
    }
    return .{ .line = m.group(1).?, .extra = try std.mem.concat(a, u8, &.{ "*", char_len }) };
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

    const f = (try readFunDef(a, "pure real function foo(a, b) result(c)", null, false)).?;
    try std.testing.expectEqualStrings("foo", f.fun.name);
    try std.testing.expectEqualStrings("a,b", f.fun.args);

    const s = (try getFortranDefinition(a, "subroutine bar(x)")).?;
    try std.testing.expectEqualStrings("bar", s.sub.name);

    const ctx = try getLineContext(a, "call foo");
    try std.testing.expectEqual(LineContext.call, ctx.ctx);
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
