//! Fortran source file handling and parsing (port of
//! `fortls.parsers.internal.parser`)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const helpers = @import("helpers.zig");
const patterns = @import("patterns.zig");
const suffixes = @import("suffixes.zig");
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

// The line readers, the parser and the editor's changes, in parser/
const parser_definitions = @import("parser/definitions.zig");
const parser_parse = @import("parser/parse.zig");
const changes = @import("parser/changes.zig");
const openmp = @import("parser/openmp.zig");
const form_switch = @import("parser/form_switch.zig");
const fixed_columns = @import("parser/fixed_columns.zig");
const implicit = @import("implicit.zig");
const line_size = @import("parser/line_size.zig");
const default_kinds = @import("default_kinds.zig");
const tab_format = @import("parser/tab_format.zig");
const pp_intel = @import("preprocessor/intel.zig");

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
const Split = @import("parser/entities.zig").Split;

/// Receives parser/preprocessor trace lines (debug CLI)
pub const Trace = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, msg: []const u8) void,

    /// Write a trace line to `t`, if there is one
    pub fn print(t: ?Trace, comptime fmt: []const u8, args: anytype) void {
        const tr = t orelse return;
        var buf: [16384]u8 = undefined;
        const s = std.mem.print(&buf, fmt, args) catch buf[0..];
        tr.writeFn(tr.ctx, s);
    }
};

/// Parameters of parsing a file that do not depend on the file
pub const Options = struct {
    /// Order the keywords of a definition by id (`--sort_keywords`)
    sort_keywords: bool = false,
    /// Honor Intel's conditional compilation directives (`!DEC$ IF`,
    /// preprocessor/intel.zig)
    intel_directives: bool = true,
    /// Plain comments above or after a declaration are its documentation
    /// (`--hover_plain_comments`)
    plain_comments: bool = false,
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
    return std.Io.Dir.path.resolveAlloc(a, &.{path}) catch path;
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
    const amper = std.mem.findScalar(u8, line, '&') orelse return null;
    const comment = std.mem.findScalar(u8, line, '!') orelse return amper;
    return if (amper < comment) amper else null;
}

/// A fixed-form continuation line with blanks for its marks, the statement
/// going on at `start` (`helpers.fixedContStart`)
fn contLine(a: Allocator, line: []const u8, start: usize) ![]const u8 {
    return std.mem.concat(a, u8, &.{ try str.spaces(a, start), str.from(line, start) });
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

/// The source form of a file
pub const SourceForm = enum { fixed, free };

/// The form that an editor's language for a document (`languageId`) names:
/// the VS Code extension's `FortranFixedForm` and `FortranFreeForm`. Other
/// editors' (`fortran`, `fortran90`) name none.
pub fn formOfLanguage(language_id: ?[]const u8) ?SourceForm {
    const id = language_id orelse return null;
    if (std.ascii.eqlIgnoreCase(id, "FortranFixedForm")) return .fixed;
    if (std.ascii.eqlIgnoreCase(id, "FortranFreeForm")) return .free;
    return null;
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
    /// What `prepare` gave the last parse (in `pp_arena`) and the `hash` of
    /// the text then, from which the summary of a file is parsed again
    /// (server/summary.zig)
    prepared: ?struct { out: ?pp.Output, hash: ?u64 } = null,
    /// The form zfls reads `lines` in: free in a file whose `!dir$ fixed`
    /// or `!dir$ free` switch forms (`form_switched`), whose fixed-form
    /// lines `lines` has as free-form ones (parser/form_switch.zig)
    fixed: bool = false,
    /// The file's own form (of its first lines), which compilers are told
    declared_fixed: bool = false,
    form_switched: bool = false,
    /// The form the editor gives the document while it is open (its
    /// language: `formOfLanguage`), which comes before the form that its
    /// name and text suggest
    forced_form: ?SourceForm = null,
    /// The form of the file's command (`-ffixed-form`), after the editor's
    command_form: ?SourceForm = null,
    /// `-fimplicit-none`: IMPLICIT NONE where no IMPLICIT statement is
    implicit_none: bool = false,
    /// the kinds of the types without one, of its options (#512)
    default_kinds: default_kinds.Kinds = .{},
    preproc: bool = false,
    ast: ?*Ast = null,
    hash: ?u64 = null,
    /// Read only because a file of the workspace includes it (INCLUDE,
    /// `#include`), being none of its sources (`.inc`): for the
    /// declarations it holds, which the including scopes see
    included: bool = false,
    /// Further markers that start a comment as `!` does (`comment_markers`,
    /// such as `;*`): outside strings, the first byte of one is `!` in
    /// `lines`, the text zfls reads, so that it is a comment there
    comment_markers: []const []const u8 = &.{},
    /// Read OpenMP conditional compilation lines (`!$ x = 1`) as code: their
    /// sentinel is two blanks in `lines` (parser/openmp.zig)
    openmp_conditional: bool = true,
    /// When `lines` differ from the editor's text (comment markers, OpenMP
    /// conditional lines): the lines as the editor has them, slices of
    /// `raw_text` (owned by `gpa`), to which changes apply; else empty
    raw_lines: std.ArrayList([]const u8) = .empty,
    raw_text: []u8 = &.{},
    /// `d_lines` is `code`: the D or d in column 1 of a fixed-form line (a
    /// debug line) is a blank in `lines`, not the start of a comment
    d_lines_code: bool = false,
    /// `fixed_line_length`: the columns of a fixed-form code line past it
    /// are blanks in `lines` (parser/fixed_columns.zig); null: no limit
    fixed_columns: ?usize = null,
    /// ifx's `!DEC$ FIXEDFORMLINESIZE:n` lines (parser/line_size.zig), owned
    /// by `gpa`
    line_sizes: []line_size.Directive = &.{},

    pub fn create(gpa: Allocator, path: []const u8, pp_suffixes: ?[]const []const u8) !*FortranFile {
        const self = try gpa.create(FortranFile);
        self.* = .{
            .gpa = gpa,
            .path = try gpa.dupe(u8, path),
            .pp_arena = std.heap.ArenaAllocator.init(gpa),
        };
        const ext = std.Io.Dir.path.extension(std.Io.Dir.path.basename(path));
        if (pp_suffixes) |sfx| {
            self.preproc = false;
            for (sfx) |s| if (std.mem.eql(u8, s, ext)) {
                self.preproc = true;
            };
        } else {
            // an upper-case suffix (`.F90`, `.F`), and `.fpp`, which the
            // compilers preprocess too (gfortran, Flang, ifx)
            var upper_buf: [64]u8 = undefined;
            if (ext.len <= upper_buf.len) {
                const up = std.ascii.upperString(upper_buf[0..ext.len], ext);
                self.preproc = std.mem.eql(u8, up, ext) or std.mem.eql(u8, up, ".FPP");
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
        self.gpa.free(self.line_sizes);
        self.pp_arena.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    pub fn nLines(self: *const FortranFile) usize {
        return self.lines.items.len;
    }

    /// Sets the form the editor gives the document (null: none, as for a
    /// document that is closed). Returns whether the file's form changed,
    /// after which it has to be parsed again.
    pub fn forceForm(self: *FortranFile, form: ?SourceForm) bool {
        self.forced_form = form;
        const was = self.declared_fixed;
        const lines = self.editLines();
        self.setForm(lines, true);
        // debug lines are read as code in fixed form only (`d_lines`), the
        // fixed-form lines of a file that switches forms as free ones, a
        // TAB-format continuation line as one: the editor's lines read again
        // in the new form
        if (was != self.declared_fixed and (self.d_lines_code or self.form_switched or self.raw_lines.items.len > 0)) self.setContents(lines, false) catch {};
        return was != self.declared_fixed;
    }

    /// The forms of the file: its own (by `detectFixed` of the lines before
    /// a `!dir$ fixed` or `!dir$ free`, or as it was), and whether these
    /// switch it
    fn setForm(self: *FortranFile, lines: []const []const u8, detect: bool) void {
        if (detect) self.declared_fixed = self.detectFixed(lines[0 .. form_switch.first(lines) orelse lines.len]);
        self.form_switched = form_switch.switches(self.declared_fixed, lines);
        self.fixed = self.declared_fixed and !self.form_switched;
    }

    /// Whether the file is in fixed form: as the editor says, if it does
    /// (`forced_form`). A file named as free-form source
    /// (`.f90`, `.F08`, ...) is not, as compilers decide: its text cannot
    /// tell when no line is indented 1 to 4 columns nor ends with `&` (the
    /// Fortran stdlib's, indented 5). Others by their text, as fortls
    /// decides (`detect_fixed_format`).
    fn detectFixed(self: *const FortranFile, lines: []const []const u8) bool {
        if (self.forced_form orelse self.command_form) |form| return form == .fixed;
        if (suffixes.formOf(self.path) == .free) return false;
        return helpers.detectFixedFormat(lines);
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
            tab_format.blankSpaces(buf[at .. at + l.len]);
            fresh.appendAssumeCapacity(buf[at .. at + l.len]);
            at += l.len;
        }
        // the form first, which the lines zfls reads depend on
        self.setForm(fresh.items, detect_format);
        self.replaceText(buf, fresh);
    }

    /// Take `buf` (owned by `gpa`) and the lines in it as the contents.
    /// When zfls reads them otherwise than they are written (`rewrites`),
    /// they are the raw lines, and `lines` a copy: comment markers made
    /// comments, the D of debug lines and the sentinel of OpenMP
    /// conditional lines blanks.
    fn replaceText(self: *FortranFile, buf: []u8, new_lines: std.ArrayList([]const u8)) void {
        self.gpa.free(self.raw_text);
        self.raw_lines.deinit(self.gpa);
        self.raw_text = &.{};
        self.raw_lines = .empty;
        self.gpa.free(self.text);
        self.lines.deinit(self.gpa);
        self.text = buf;
        self.lines = new_lines;
        self.resetPp();
        self.gpa.free(self.line_sizes);
        self.line_sizes = line_size.directives(self.gpa, new_lines.items) catch &.{};
        if (!self.rewrites()) return;
        // without memory for the copy, the text is read as it is
        const code = self.codeCopy(buf, new_lines.items) catch return;
        self.raw_text = buf;
        self.raw_lines = new_lines;
        self.text = code.text;
        self.lines = code.lines;
    }

    /// Whether a line of the text is read otherwise than it is written:
    /// comment markers, debug lines read as code, OpenMP conditional lines,
    /// fixed-form lines of a file that switches forms or past
    /// `fixed_columns`, TAB-format lines
    fn rewrites(self: *const FortranFile) bool {
        if (self.form_switched or self.comment_markers.len > 0 or (self.d_lines_code and self.fixed)) return true;
        if (self.fixed) for (self.lines.items, 0..) |l, i| if (self.fixedLimitAt(i, self.fixed_columns)) |n| if (fixed_columns.isLong(l, n)) return true;
        if (tab_format.any(self.lines.items)) return true;
        if (!self.openmp_conditional) return false;
        for (self.lines.items) |l| if (openmp.isConditional(self.fixed, l)) return true;
        return false;
    }

    /// A copy of `buf` and its lines as zfls reads them: the comment
    /// markers made `!`, the D or d in column 1 a blank with
    /// `d_lines_code`, the sentinels of OpenMP conditional lines blanks,
    /// the columns past `fixed_columns` blanks
    fn codeCopy(self: *FortranFile, buf: []const u8, raw: []const []const u8) !struct { text: []u8, lines: std.ArrayList([]const u8) } {
        if (self.form_switched) {
            const limits: line_size.Limits = .{ .default = self.fixed_columns, .directives = self.line_sizes };
            const out = try form_switch.asFree(self.gpa, self.declared_fixed, self.d_lines_code, limits, raw);
            for (out.lines.items, 0..) |l, i| self.rewriteLine(@constCast(l), i);
            return .{ .text = out.text, .lines = out.lines };
        }
        const text = try self.gpa.dupe(u8, buf);
        errdefer self.gpa.free(text);
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer lines.deinit(self.gpa);
        try lines.ensureTotalCapacity(self.gpa, raw.len);
        for (raw, 0..) |l, i| {
            const at = @intFromPtr(l.ptr) - @intFromPtr(buf.ptr);
            const line = text[at .. at + l.len];
            self.rewriteLine(line, i);
            lines.appendAssumeCapacity(line);
        }
        return .{ .text = text, .lines = lines };
    }

    /// The line length of fixed-form line `i` (0-based): `default`
    /// (`fixed_line_length`) or that of a FIXEDFORMLINESIZE before it
    pub fn fixedLimitAt(self: *const FortranFile, i: usize, default: ?usize) ?usize {
        return (line_size.Limits{ .default = default, .directives = self.line_sizes }).at(i);
    }

    fn rewriteLine(self: *const FortranFile, line: []u8, i: usize) void {
        tab_format.blankLine(self.fixed, line);
        if (self.d_lines_code and self.fixed and line.len > 0 and (line[0] == 'd' or line[0] == 'D')) line[0] = ' ';
        if (self.openmp_conditional) _ = openmp.blankSentinel(self.fixed, line);
        if (self.fixed) if (self.fixedLimitAt(i, self.fixed_columns)) |n| fixed_columns.blank(line, n);
        if (self.comment_markers.len > 0) helpers.markComments(line, self.comment_markers);
    }

    /// The lines that changes apply to: the editor's
    pub fn editLines(self: *const FortranFile) []const []const u8 {
        return if (self.raw_lines.items.len > 0 and self.raw_lines.items.len == self.lines.items.len) self.raw_lines.items else self.lines.items;
    }

    /// The `hash` of a file's text, whose tabs and form feeds become
    /// spaces
    pub fn textHash(text: []u8) u64 {
        tab_format.blankSpaces(text);
        return std.hash.Wyhash.hash(0, text);
    }

    /// Set contents from text; returns false if unchanged (same hash)
    pub fn setText(self: *FortranFile, text_in: []const u8) !bool {
        return self.setTextOwned(try self.gpa.dupe(u8, text_in));
    }

    /// `setText` taking ownership of `text` (allocated by `gpa`): the lines
    /// are slices of it, without a copy
    pub fn setTextOwned(self: *FortranFile, text: []u8) !bool {
        errdefer self.gpa.free(text);
        const h = textHash(text);
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
        self.setForm(fresh.items, true);
        self.replaceText(text, fresh);
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

    /// Whether line `i` (0-based), `line`, holds no part of a statement: a
    /// blank or comment line, a preprocessor directive, or a line of an
    /// inactive conditional branch (hansec #203). Such lines may come
    /// between the lines of a continued statement without ending it.
    fn isNonCode(self: *const FortranFile, line: []const u8, i: usize) bool {
        return std.mem.trim(u8, line, " \t\r").len == 0 or helpers.isComment(self.fixed, line) or
            helpers.isPpDirective(line) or self.ppSkipped(i);
    }

    /// The statement that line `line_no` (0-based) is part of: the line,
    /// and the lines of the statement before it (`backward`) and after it
    /// (`forward`). `pre` and `post` hold a line for each line of the
    /// file, from the statement's first to its last: an empty one for a
    /// line that is no code (`isNonCode`).
    pub fn getCodeLine(self: *const FortranFile, a: Allocator, line_no: usize, forward: bool, backward: bool, pp_content: bool, strip_comment: bool) !CodeLine {
        var curr_line = self.getLine(line_no, pp_content) orelse return .{ .pre = &.{}, .curr = null, .post = &.{} };
        var pre_lines: std.ArrayList([]const u8) = .empty;
        // the lines that are no code since the last line of the statement
        var skipped: usize = 0;
        if (backward) {
            // a fixed-form line continues a statement by its column 6, a
            // free-form one when the code line before it ends with `&`
            const cont = if (self.fixed) helpers.fixedContStart(curr_line) else null;
            const continued = !self.fixed or cont != null;
            if (self.fixed) {
                if (cont) |c| curr_line = try contLine(a, curr_line, c);
            } else if (helpers.freeContEnd(curr_line)) |e| {
                curr_line = try std.mem.concat(a, u8, &.{ try str.spaces(a, e), curr_line[e..] });
            }
            var i = line_no;
            while (continued and i > 0) {
                i -= 1;
                const raw = self.getLine(i, pp_content) orelse "";
                if (self.isNonCode(raw, i)) {
                    skipped += 1;
                    continue;
                }
                var part: []const u8 = undefined;
                var first = false;
                if (self.fixed) {
                    const c = helpers.fixedContStart(raw);
                    first = c == null;
                    part = try fixedNoComment(a, raw);
                    if (c) |start| part = try contLine(a, part, start);
                } else {
                    const no_comm = str.beforeFirst(try helpers.stripStrings(a, raw, true), "!");
                    const cont_ind = std.mem.findScalarLast(u8, no_comm, '&') orelse break;
                    part = no_comm[0..cont_ind];
                    if (helpers.freeContEnd(no_comm)) |e| {
                        if (cont_ind == e - 1) break;
                        part = try std.mem.concat(a, u8, &.{ try str.spaces(a, e), part[e..] });
                    }
                }
                try pre_lines.appendNTimes(a, "", skipped);
                skipped = 0;
                try pre_lines.append(a, part);
                if (first) break;
            }
        }
        var post_lines: std.ArrayList([]const u8) = .empty;
        if (forward) {
            // the statement's last line so far: null for `curr_line`, else
            // an index of `post_lines`
            var last: ?usize = null;
            var i = line_no + 1;
            skipped = 0;
            while (true) {
                const line = if (last) |l| post_lines.items[l] else curr_line;
                var cut = line;
                if (!self.fixed) {
                    // a preprocessor directive's `&&` continues nothing
                    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#")) break;
                    const amper = continuationAmpersand(try helpers.stripStrings(a, line, true)) orelse break;
                    cut = str.upto(line, amper);
                    if (last) |l| post_lines.items[l] = cut else curr_line = cut;
                }
                const next = while (self.getLine(i, pp_content)) |l| : (i += 1) {
                    if (!self.isNonCode(l, i)) break l;
                    skipped += 1;
                } else break;
                i += 1;
                var part = next;
                if (self.fixed) {
                    const c = helpers.fixedContStart(next) orelse break;
                    // a comment ends its line only: one before a continuation
                    // must not cut off the rest of the statement (hansec #202)
                    cut = try fixedNoComment(a, line);
                    if (last) |l| post_lines.items[l] = cut else curr_line = cut;
                    part = try contLine(a, next, c);
                } else if (helpers.freeContEnd(next)) |e| part = next[e..];
                try post_lines.appendNTimes(a, "", skipped);
                skipped = 0;
                try post_lines.append(a, part);
                last = post_lines.items.len - 1;
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

    /// Whether a statement continues into line `line_no` (0-based): the
    /// code line before it ends with `&` (free form), or the next one is a
    /// continuation line (fixed form). An INCLUDE or `#include` there is a
    /// part of the statement's text (json-fortran's `subroutine s(me, &`
    /// then an `#include` of the rest of the argument list), not a file of
    /// declarations.
    pub fn continuesInto(self: *const FortranFile, line_no: usize) bool {
        if (self.fixed) {
            var i = line_no + 1;
            while (self.getLine(i, false)) |l| : (i += 1) {
                if (std.mem.trim(u8, l, " \t\r").len == 0 or helpers.isFixedComment(l) or l[0] == '#') continue;
                return helpers.fixedContMark(l) != null;
            }
            return false;
        }
        var i = line_no;
        while (i > 0) {
            i -= 1;
            const l = self.getLine(i, false) orelse return false;
            const code = std.mem.trim(u8, self.stripComment(l), " \t\r");
            if (code.len == 0 or code[0] == '#') continue;
            return code[code.len - 1] == '&';
        }
        return false;
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

    pub const applyChange = changes.applyChange;

    /// Run the preprocessor over the file contents
    pub fn preprocess(self: *FortranFile, io: Io, defs: ?*const pp.Defs, include_dirs: []const []const u8, trace: ?Trace) !pp.Output {
        _ = self.pp_arena.reset(.free_all);
        self.prepared = null;
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
            const msg_line = try a.print("Line length exceeds \"max_line_length\" ({d})", .{max_line_length});
            const msg_comment = try a.print("Comment line length exceeds \"max_comment_line_length\" ({d})", .{max_comment_line_length});
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
                    // a `!` in column 6 of a fixed-form line marks a
                    // continuation, not a comment
                    const from: usize = if (self.fixed) helpers.fixedContStart(line) orelse 0 else 0;
                    const has_comment = std.mem.findScalarPos(u8, stripped, from, '!');
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
        self.prepared = null;
        const out = try self.preparePass(io, defs, include_dirs, opts);
        self.prepared = .{ .out = out, .hash = self.hash };
        return out;
    }

    fn preparePass(self: *FortranFile, io: Io, defs: ?*const pp.Defs, include_dirs: []const []const u8, opts: Options) !?pp.Output {
        if (self.preproc) {
            Trace.print(opts.trace, "=== PreProc Pass ===\n", .{});
            var out = try self.preprocess(io, defs, include_dirs, opts.trace);
            Trace.print(opts.trace, "\n=== Parsing Pass ===\n", .{});
            if (opts.intel_directives) try self.addIntelSkips(&out, defs);
            return out;
        }
        Trace.print(opts.trace, "=== No PreProc ===\n", .{});
        self.pp_lines = null;
        self.pp_skips = &.{};
        if (!opts.intel_directives) return null;
        // the Intel conditionals alone: no macros, no includes
        _ = self.pp_arena.reset(.free_all);
        self.pp_defs = .empty;
        var out: pp.Output = .{ .lines = self.lines.items, .skips = &.{}, .defines = &.{}, .includes = &.{}, .missing = &.{}, .defs = .empty };
        try self.addIntelSkips(&out, defs);
        return if (out.skips.len > 0) out else null;
    }

    /// Adds to `out` (and `pp_skips`) the branches that Intel's conditional
    /// compilation directives (`!DEC$ IF DEFINED (X)`) leave out, after the
    /// C preprocessor's
    fn addIntelSkips(self: *FortranFile, out: *pp.Output, defs: ?*const pp.Defs) !void {
        const a = self.pp_arena.allocator();
        const extra = (try pp_intel.branchSkips(a, self.lines.items, self.fixed, defs, out.skips)) orelse return;
        if (extra.len == 0) return;
        out.skips = try std.mem.concat(a, pp.Skip, &.{ out.skips, extra });
        self.pp_skips = out.skips;
    }

    /// A hash of all that parsing reads, `prepared` and `opts` included,
    /// with `salt`: two parses of the same key build the same AST (the
    /// index cache keeps ASTs under it)
    pub fn parseKey(self: *const FortranFile, prepared: ?pp.Output, opts: Options, salt: u64) u64 {
        var h = std.hash.Wyhash.init(salt);
        const flags = [_]u8{ @intFromBool(self.fixed), @intFromBool(self.preproc), @intFromBool(opts.sort_keywords), @intFromBool(self.d_lines_code), @intFromBool(opts.plain_comments), @intFromBool(self.implicit_none) };
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
            for (out.missing) |mi| {
                h.update(std.mem.asBytes(&mi.line));
                h.update(mi.name);
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
            // one whose file is not found, like an INCLUDE that zfls cannot read
            for (out.missing) |mi| try p.file_ast.addMissingInclude(mi.name, mi.line, mi.start, mi.end);
        }
        try p.run();
        if (self.implicit_none) implicit.noneByDefault(p.file_ast);
        return p.file_ast;
    }
};

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

test "getCodeLine: lines that are no code do not end a statement, and keep their place" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try FortranFile.create(std.testing.allocator, "/w/a.f90", null);
    defer f.destroy();
    _ = try f.setText("call foo(a, & ! one\n  ! two\n\n#if 1\n  b, &\n#endif\n  c)\nx = 1\n");
    const back = try f.getCodeLine(a, 6, false, true, false, false);
    try std.testing.expectEqual(@as(usize, 6), back.pre.len);
    try std.testing.expectEqualStrings("call foo(a, ", back.pre[0]);
    try std.testing.expectEqualStrings("  b, ", back.pre[4]);
    const fwd = try f.getCodeLine(a, 0, true, false, false, false);
    try std.testing.expectEqualStrings("call foo(a, ", fwd.curr.?);
    try std.testing.expectEqual(@as(usize, 6), fwd.post.len);
    try std.testing.expectEqualStrings("  c)", fwd.post[5]);
    // fixed form; line 0 is part of the statement too
    _ = try f.setText("      x = f(a,\nc two\n     & b)\nc three\n      y = 1\n");
    f.fixed = true;
    const fb = try f.getCodeLine(a, 2, false, true, false, false);
    try std.testing.expectEqual(@as(usize, 2), fb.pre.len);
    try std.testing.expectEqualStrings("      x = f(a,", fb.pre[0]);
    const ff = try f.getCodeLine(a, 0, true, false, false, false);
    try std.testing.expectEqual(@as(usize, 2), ff.post.len);
}

test "d_lines code: zfls reads the D of a debug line as a blank, changes apply to the editor's text" {
    const f = try FortranFile.create(std.testing.allocator, "/w/a.f", null);
    defer f.destroy();
    f.d_lines_code = true;
    _ = try f.setText("      I = 1\nD     I = 2\n      END\n");
    try std.testing.expect(f.fixed);
    try std.testing.expectEqualStrings("      I = 2", f.getLine(1, false).?);
    _ = try f.applyChange(.{ .text = "3", .range = .{ .sl = 1, .sc = 10, .el = 1, .ec = 11 } });
    try std.testing.expectEqualStrings("D     I = 3", f.editLines()[1]);
    try std.testing.expectEqualStrings("      I = 3", f.getLine(1, false).?);
}
