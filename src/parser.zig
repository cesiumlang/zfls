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

// The line readers and the parser, in parser/
const parser_definitions = @import("parser/definitions.zig");
const parser_parse = @import("parser/parse.zig");

pub const ResultSig = parser_definitions.ResultSig;
pub const VarInfo = parser_definitions.VarInfo;
pub const SubInfo = parser_definitions.SubInfo;
pub const FunSig = parser_definitions.FunSig;
pub const SelectInfo = parser_definitions.SelectInfo;
pub const ClassInfo = parser_definitions.ClassInfo;
pub const GenProcDefInfo = parser_definitions.GenProcDefInfo;
pub const SmodInfo = parser_definitions.SmodInfo;
pub const InterInfo = parser_definitions.InterInfo;
pub const VisInfo = parser_definitions.VisInfo;
pub const UseInfo = parser_definitions.UseInfo;
pub const ImportInfo = parser_definitions.ImportInfo;
pub const DefResult = parser_definitions.DefResult;
pub const readVarDef = parser_definitions.readVarDef;
pub const readFunDef = parser_definitions.readFunDef;
pub const readSubDef = parser_definitions.readSubDef;
pub const readUseStmt = parser_definitions.readUseStmt;
pub const getFortranDefinition = parser_definitions.getFortranDefinition;
pub const LineContext = parser_definitions.LineContext;
pub const getLineContext = parser_definitions.getLineContext;
const firstWord = parser_definitions.firstWord;
const Parser = parser_parse.Parser;
const Split = parser_parse.Split;

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

// --------------------------------------------------------------------------
// EXTERNAL handling

// Both lookups are within the current scope: the same name can be declared
// external in several procedures of a file (upstream #406).

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

/// A fixed-form line without its trailing `!` comment. A `!` inside a
/// string, also one left open to continue on the next line, is no comment.
fn fixedNoComment(a: Allocator, line: []const u8) ![]const u8 {
    _ = a;
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '!') {
            return str.rstrip(line[0..i]);
        }
    }
    return line;
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
    /// Line ranges of `pp_lines` excluded by preprocessor conditionals,
    /// owned by `pp_arena`
    pp_skips: []const pp.Skip = &.{},
    pp_arena: std.heap.ArenaAllocator,
    pp_defs: pp.Defs = .empty,
    fixed: bool = false,
    preproc: bool = false,
    ast: ?*Ast = null,
    hash: ?u64 = null,
    /// Further markers that start a comment as `!` does (`comment_markers`,
    /// such as `;*`): outside strings, the first byte of one is `!` in
    /// `lines`, the text zfls reads, so that it is a comment there
    comment_markers: []const []const u8 = &.{},
    /// With `comment_markers`: the lines as the editor has them, slices of
    /// `raw_text` (owned by `gpa`), to which changes apply
    raw_lines: std.ArrayList([]const u8) = .empty,
    raw_text: []u8 = &.{},

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
        self.gpa.free(self.raw_text);
        self.raw_lines.deinit(self.gpa);
        self.pp_arena.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    pub fn nLines(self: *const FortranFile) usize {
        return self.lines.items.len;
    }

    fn resetPp(self: *FortranFile) void {
        self.pp_lines = null;
        self.pp_skips = &.{};
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

    /// Take `buf` (owned by `gpa`) and the lines in it as the contents.
    /// With comment markers, they are the raw lines, and `lines` a copy
    /// with the markers made comments.
    fn replaceText(self: *FortranFile, buf: []u8, new_lines: std.ArrayList([]const u8)) void {
        if (self.comment_markers.len > 0) {
            if (self.markedCopy(buf, new_lines.items)) |marked| {
                self.gpa.free(self.raw_text);
                self.raw_lines.deinit(self.gpa);
                self.raw_text = buf;
                self.raw_lines = new_lines;
                self.gpa.free(self.text);
                self.lines.deinit(self.gpa);
                self.text = marked.text;
                self.lines = marked.lines;
                self.resetPp();
                return;
            } else |_| {}
        }
        self.gpa.free(self.text);
        self.lines.deinit(self.gpa);
        self.text = buf;
        self.lines = new_lines;
        self.resetPp();
    }

    /// A copy of `buf` and its lines with the comment markers made `!`
    fn markedCopy(self: *FortranFile, buf: []const u8, raw: []const []const u8) !struct { text: []u8, lines: std.ArrayList([]const u8) } {
        const text = try self.gpa.dupe(u8, buf);
        errdefer self.gpa.free(text);
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer lines.deinit(self.gpa);
        try lines.ensureTotalCapacity(self.gpa, raw.len);
        for (raw) |l| {
            const at = @intFromPtr(l.ptr) - @intFromPtr(buf.ptr);
            const line = text[at .. at + l.len];
            helpers.markComments(line, self.comment_markers);
            lines.appendAssumeCapacity(line);
        }
        return .{ .text = text, .lines = lines };
    }

    /// The lines that changes apply to: the editor's
    fn editLines(self: *const FortranFile) []const []const u8 {
        return if (self.comment_markers.len > 0 and self.raw_lines.items.len == self.lines.items.len) self.raw_lines.items else self.lines.items;
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
        // as many as there are lines, not more (a workspace has millions)
        const breaks = std.mem.count(u8, text, "\n");
        try fresh.ensureTotalCapacityPrecise(self.gpa, (if (breaks > 0) breaks else std.mem.count(u8, text, "\r")) + 1);
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
                    if (helpers.isFixedCont(tmp_line)) {
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
                if (helpers.freeContEnd(curr_line)) |e| {
                    curr_line = try std.mem.concat(a, u8, &.{ try str.spaces(a, e), curr_line[e..] });
                }
                while (line_ind > 0) {
                    const tmp_line = try helpers.stripStrings(a, self.getLine(line_ind, pp_content) orelse "", true);
                    var tmp_no_comm = str.beforeFirst(tmp_line, "!");
                    const cont_ind = std.mem.lastIndexOfScalar(u8, tmp_no_comm, '&');
                    if (helpers.freeContEnd(tmp_no_comm)) |e| {
                        if (cont_ind == e - 1) break;
                        tmp_no_comm = try std.mem.concat(a, u8, &.{ try str.spaces(a, e), tmp_no_comm[e..] });
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
                    var cont = helpers.isFixedCont(next_line);
                    // a comment ends its line only: one before a continuation
                    // must not cut off the rest of the statement (hansec #202)
                    if (cont) curr_line = try fixedNoComment(a, curr_line);
                    while (cont and line_ind < n) {
                        try post_lines.append(a, try std.mem.concat(a, u8, &.{ "      ", str.from(next_line, 6) }));
                        next_line = self.getLine(line_ind, pp_content) orelse "";
                        line_ind += 1;
                        cont = helpers.isFixedCont(next_line);
                        if (cont) {
                            const last = &post_lines.items[post_lines.items.len - 1];
                            last.* = try fixedNoComment(a, last.*);
                        }
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
                    // a line of an inactive conditional branch is not part of
                    // the statement (hansec #203)
                    if (helpers.isPpDirective(next_line) or (pp_content and self.ppSkipped(line_ind - 1))) {
                        next_line = "";
                        try post_lines.append(a, "");
                        continue;
                    }
                    if (str.rstrip(next_line).len == 0 or helpers.isFreeComment(next_line)) {
                        next_line = "";
                        try post_lines.append(a, "");
                        continue;
                    }
                    if (helpers.freeContEnd(next_line)) |e| next_line = next_line[e..];
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

    /// Whether line `line_no` (0-based) is excluded by a preprocessor
    /// conditional
    fn ppSkipped(self: *const FortranFile, line_no: usize) bool {
        for (self.pp_skips) |reg| if (reg.start <= line_no + 1 and line_no + 1 <= reg.end) return true;
        return false;
    }

    pub fn stripComment(self: *const FortranFile, line: []const u8) []const u8 {
        if (self.fixed) {
            if (helpers.isFixedComment(line) and !helpers.isOpenMp(true, line)) return "";
        } else {
            if (!helpers.isOpenMp(false, line)) return str.beforeFirst(line, "!");
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
        const current = self.editLines();
        if (rng.sl == n) {
            var all: std.ArrayList([]const u8) = .empty;
            for (current) |l| try all.append(a, l);
            try all.appendSlice(a, text_split);
            try self.setContents(all.items, true);
            return true;
        }
        if (rng.sl > n or rng.el >= n + 1) return error.InvalidRange;
        const start_line = current[rng.sl];
        const end_line = if (rng.el < n) current[rng.el] else "";
        const start_col = @min(str.utf16ToByte(start_line, rng.sc), start_line.len);
        const end_col = @min(str.utf16ToByte(end_line, rng.ec), end_line.len);

        // Single line edit
        if (rng.sl == rng.el and text_split.len == 1) {
            const prev = current[rng.sl];
            const new_line = try std.mem.concat(a, u8, &.{ prev[0..start_col], text, prev[@max(end_col, start_col)..] });
            const replaced = try a.dupe([]const u8, current);
            replaced[rng.sl] = new_line;
            // The buffer is rebuilt, which the preprocessed lines that are
            // the raw lines themselves must follow; the others are in pp_arena
            const old_pp = self.pp_lines;
            const old_skips = self.pp_skips;
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
                self.pp_skips = old_skips;
            }
            return self.checkChangeReparse(@intCast(rng.sl));
        }

        var new_contents: std.ArrayList([]const u8) = .empty;
        for (current, 0..) |line, i| {
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
        if (helpers.isComment(self.fixed, curr_line)) return false;
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
        self.pp_skips = &.{};
        self.pp_defs = .empty;
        const a = self.pp_arena.allocator();
        const out = try pp.preprocessFile(a, io, self.lines.items, self.path, defs, include_dirs, trace);
        self.pp_lines = out.lines;
        self.pp_skips = out.skips;
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
            // a limit that is not positive is off
            const max_code: usize = @intCast(@max(max_line_length, 0));
            const max_comment: usize = @intCast(@max(max_comment_line_length, 0));
            for (self.lines.items, 0..) |line, ln| {
                const len = str.codepointLen(line);
                if (!helpers.isComment(self.fixed, line)) {
                    // Code is held to max_line_length; a comment after it is
                    // held to max_comment_line_length, not to the code limit
                    // (upstream #489)
                    const stripped = try helpers.stripStrings(a, line, true);
                    const has_comment = std.mem.indexOfScalar(u8, stripped, '!');
                    const code = if (has_comment) |ci| str.rstrip(line[0..ci]) else line;
                    const code_len = str.codepointLen(code);
                    if (0 < max_code and max_code < code_len) {
                        try out.append(a, .{ .sln = ln, .sch = max_code, .eln = ln, .ech = code_len, .message = msg_line, .severity = C.Severity.warn, .cols_are_codepoints = true, .code = .line_too_long });
                    }
                    if (has_comment != null and 0 < max_comment and max_comment < len) {
                        try out.append(a, .{ .sln = ln, .sch = max_comment, .eln = ln, .ech = len, .message = msg_comment, .severity = C.Severity.warn, .cols_are_codepoints = true, .code = .comment_too_long });
                    }
                } else {
                    if (0 < max_comment and max_comment < len) {
                        try out.append(a, .{ .sln = ln, .sch = max_comment, .eln = ln, .ech = len, .message = msg_comment, .severity = C.Severity.warn, .cols_are_codepoints = true, .code = .comment_too_long });
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
        return self.parsePrepared(try self.prepare(io, defs, include_dirs, opts), opts);
    }

    /// The preprocessor's output for parsing (null when the file is not
    /// preprocessed), which `self` keeps too
    pub fn prepare(self: *FortranFile, io: Io, defs: ?*const pp.Defs, include_dirs: []const []const u8, opts: Options) !?pp.Output {
        if (self.preproc) {
            Trace.print(opts.trace, "=== PreProc Pass ===\n", .{});
            const out = try self.preprocess(io, defs, include_dirs, opts.trace);
            Trace.print(opts.trace, "\n=== Parsing Pass ===\n", .{});
            return out;
        }
        Trace.print(opts.trace, "=== No PreProc ===\n", .{});
        self.pp_lines = null;
        self.pp_skips = &.{};
        return null;
    }

    /// A hash of all that parsing reads, `prepared` and `opts` included,
    /// with `salt`: two parses of the same key build the same AST (the
    /// index cache keeps ASTs under it)
    pub fn parseKey(self: *const FortranFile, prepared: ?pp.Output, opts: Options, salt: u64) u64 {
        var h = std.hash.Wyhash.init(salt);
        const flags = [_]u8{ @intFromBool(self.fixed), @intFromBool(self.preproc), @intFromBool(opts.sort_keywords) };
        h.update(&flags);
        for (self.comment_markers) |m| {
            h.update(m);
            h.update("\x00");
        }
        const lines = if (prepared) |out| out.lines else self.lines.items;
        h.update(std.mem.asBytes(&lines.len));
        for (lines) |l| {
            h.update(std.mem.asBytes(&l.len));
            h.update(l);
        }
        if (prepared) |out| {
            h.update(std.mem.sliceAsBytes(out.skips));
            h.update(std.mem.asBytes(&out.defines.len));
            h.update(std.mem.sliceAsBytes(out.defines));
            for (out.includes) |inc| {
                h.update(std.mem.asBytes(&inc.line));
                h.update(inc.path);
                h.update("\x00");
            }
        }
        return h.final();
    }

    /// Parse the file with the preprocessor's output of `prepare`
    pub fn parsePrepared(self: *FortranFile, prepared: ?pp.Output, opts: Options) !*Ast {
        var p: Parser = .{
            .opts = opts,
            .file = self,
            .file_ast = try Ast.create(self.gpa, self),
            .scratch = std.heap.ArenaAllocator.init(self.gpa),
        };
        defer p.scratch.deinit();
        errdefer p.file_ast.destroy();
        if (prepared) |out| {
            p.pp_skips = out.skips;
            p.pp_defines = out.defines;
            // an `#include` links the file like an INCLUDE statement would
            for (out.includes) |inc| try p.file_ast.addInclude(inc.path, inc.line);
        }
        try p.run();
        return p.file_ast;
    }
};

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

test "comment markers: zfls reads comments, changes apply to the editor's text" {
    patterns.init();
    const gpa = std.testing.allocator;
    const f = try FortranFile.create(gpa, "/w/a.f90", null);
    defer f.destroy();
    f.comment_markers = &.{";*"};
    _ = try f.setText("program p\n  go to 110 ;* it's a comment\nend program p\n");
    try std.testing.expectEqualStrings("  go to 110 !* it's a comment", f.getLine(1, false).?);
    // deleting the `*` leaves a statement separator, not a comment
    _ = try f.applyChange(.{ .text = "", .range = .{ .sl = 1, .sc = 13, .el = 1, .ec = 14 } });
    try std.testing.expectEqualStrings("  go to 110 ; it's a comment", f.getLine(1, false).?);
    // and typing it again makes the comment again, across a multi-line edit
    _ = try f.applyChange(.{ .text = "*\n  x = 1 ;* two", .range = .{ .sl = 1, .sc = 13, .el = 1, .ec = 13 } });
    try std.testing.expectEqualStrings("  go to 110 !*", f.getLine(1, false).?);
    try std.testing.expectEqualStrings("  x = 1 !* two it's a comment", f.getLine(2, false).?);
    try std.testing.expectEqual(@as(usize, 5), f.nLines());
}
