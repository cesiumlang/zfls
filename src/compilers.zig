//! The compilers whose messages zfls publishes as diagnostics
//! (`compiler_diagnostics`): their command-line options and parsers of
//! their messages. A port of the VS Code extension's linter
//! (editors/vscode/src/lint/compilers.ts), whose tests the ones here follow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const Regex = regex.Regex;

pub const Id = enum {
    gfortran,
    ifx,
    ifort,
    nagfor,
    lfortran,
    nvfortran,
    flang,

    pub fn fromName(name: []const u8) ?Id {
        return std.meta.stringToEnum(Id, name);
    }
};

pub const Severity = enum {
    @"error",
    warning,
    info,
    hint,

    /// The LSP `DiagnosticSeverity`
    pub fn lsp(s: Severity) i64 {
        return @as(i64, @backingInt(s)) + 1;
    }
};

/// A further location of a message, such as flang's "Previous declaration
/// of 'y'"
pub const Related = struct {
    file: ?[]const u8,
    line: usize,
    column: ?usize,
    message: []const u8,
};

/// One message of a compiler. Lines and columns count from 1; a line of 0
/// means that the message has no location (such as a bad option).
pub const Message = struct {
    /// As the compiler printed it: relative to its working directory or
    /// absolute; null when the message names no file
    file: ?[]const u8,
    line: usize,
    column: ?usize,
    /// The last line and column of the span, inclusive (LFortran only)
    end_line: ?usize = null,
    end_column: ?usize = null,
    severity: Severity,
    message: []const u8,
    code: ?[]const u8 = null,
    related: std.ArrayList(Related) = .empty,
};

/// What changes a compiler's command line
pub const Options = struct {
    /// Intel's compilers take /options on Windows
    windows: bool,
    /// Where the compiler writes .mod (and any object) files
    mod_dir: []const u8,
};

/// The executable names tried, in order
pub fn executables(id: Id) []const []const u8 {
    return switch (id) {
        // LLVM 20 renamed flang-new to flang
        .flang => &.{ "flang", "flang-new" },
        inline else => |t| &.{@tagName(t)},
    };
}

/// Check the source only, writing .mod files but no object
pub fn syntaxOnly(a: Allocator, id: Id, o: Options) ![]const []const u8 {
    return switch (id) {
        // -fno-diagnostics-show-caret puts each message on one line (GCC
        // 4.9+; -fdiagnostics-plain-output needs GCC 11)
        .gfortran => &.{ "-fsyntax-only", "-fno-diagnostics-show-caret", "-fdiagnostics-color=never" },
        .ifx, .ifort => if (o.windows) &.{ "/nologo", "/syntax-only" } else &.{"-syntax-only"},
        // -M: produce .mod files only; -quiet: no banner and summary line
        .nagfor => &.{ "-M", "-quiet" },
        .lfortran => &.{ "--semantics-only", "--error-format=short", "--no-color" },
        // no syntax-only mode: compile, with the object file next to the
        // .mod files rather than in the source tree
        .nvfortran => try dupeArgs(a, &.{ "-c", "-o", try std.fs.path.join(a, &.{ o.mod_dir, "zfls-lint.o" }) }),
        .flang => &.{ "-fsyntax-only", "-fno-color-diagnostics" },
    };
}

fn dupeArgs(a: Allocator, args: []const []const u8) ![]const []const u8 {
    return a.dupe([]const u8, args);
}

/// Run the C-like preprocessor on the file
pub fn preprocess(id: Id, o: Options) []const []const u8 {
    return switch (id) {
        .gfortran, .flang => &.{"-cpp"},
        .ifx, .ifort => if (o.windows) &.{"/fpp"} else &.{"-fpp"},
        .nagfor => &.{"-fpp"},
        .lfortran => &.{"--cpp"},
        .nvfortran => &.{"-Mpreprocess"},
    };
}

pub fn freeForm(id: Id, o: Options) []const []const u8 {
    return switch (id) {
        .gfortran, .flang => &.{"-ffree-form"},
        .ifx, .ifort => if (o.windows) &.{"/free"} else &.{"-free"},
        .nagfor => &.{"-free"},
        .lfortran => &.{},
        .nvfortran => &.{"-Mfree"},
    };
}

pub fn fixedForm(id: Id, o: Options) []const []const u8 {
    return switch (id) {
        .gfortran, .flang => &.{"-ffixed-form"},
        .ifx, .ifort => if (o.windows) &.{"/fixed"} else &.{"-fixed"},
        .nagfor => &.{"-fixed"},
        .lfortran => &.{"--fixed-form"},
        .nvfortran => &.{"-Mfixed"},
    };
}

/// The arguments when `compiler_args` is not set
pub fn defaultArgs(id: Id, o: Options) []const []const u8 {
    return switch (id) {
        .gfortran => &.{"-Wall"},
        .ifx, .ifort => if (o.windows) &.{"/warn:all"} else &.{ "-warn", "all" },
        .nvfortran => &.{"-Minform=warn"},
        .nagfor, .lfortran, .flang => &.{},
    };
}

/// Write .mod files to, and read them from, `dir`
pub fn modOutput(a: Allocator, id: Id, dir: []const u8, o: Options) ![]const []const u8 {
    return switch (id) {
        .gfortran => dupeArgs(a, &.{try std.fmt.allocPrint(a, "-J{s}", .{dir})}),
        .ifx, .ifort => if (o.windows) dupeArgs(a, &.{try std.fmt.allocPrint(a, "/module:{s}", .{dir})}) else dupeArgs(a, &.{ "-module", dir }),
        // -mdir only writes there; -I also reads from there
        .nagfor => dupeArgs(a, &.{ "-mdir", dir, "-I", dir }),
        .lfortran => dupeArgs(a, &.{ "-J", dir, "-I", dir }),
        .nvfortran => dupeArgs(a, &.{ "-module", dir }),
        .flang => dupeArgs(a, &.{ "-module-dir", dir }),
    };
}

pub fn include(a: Allocator, id: Id, dir: []const u8, o: Options) ![]const []const u8 {
    return switch (id) {
        .nagfor => dupeArgs(a, &.{ "-I", dir }),
        .ifx, .ifort => dupeArgs(a, &.{try std.fmt.allocPrint(a, "{s}{s}", .{ if (o.windows) "/I" else "-I", dir })}),
        else => dupeArgs(a, &.{try std.fmt.allocPrint(a, "-I{s}", .{dir})}),
    };
}

/// A preprocessor definition, `-DNAME=VALUE` (or `-DNAME`)
pub fn define(a: Allocator, id: Id, name: []const u8, value: []const u8, o: Options) ![]const u8 {
    const flag = if ((id == .ifx or id == .ifort) and o.windows) "/D" else "-D";
    if (value.len == 0) return std.fmt.allocPrint(a, "{s}{s}", .{ flag, name });
    return std.fmt.allocPrint(a, "{s}{s}={s}", .{ flag, name, value });
}

/// The messages in a compiler's output
pub fn parse(a: Allocator, id: Id, output: []const u8) ![]Message {
    var p: Parser = .{ .a = a };
    defer p.deinit();
    switch (id) {
        .gfortran => try p.gfortran(output),
        .ifx, .ifort => try p.intel(output),
        .nagfor => try p.nag(output),
        .lfortran => try p.lfortran(output),
        .nvfortran => try p.nvfortran(output),
        .flang => try p.flang(output),
    }
    return dedupe(a, p.out.items);
}

/// The messages without repeats (a compiler can report the same problem
/// twice, for instance once per included copy)
pub fn dedupe(a: Allocator, msgs: []Message) ![]Message {
    var out: std.ArrayList(Message) = .empty;
    outer: for (msgs) |m| {
        for (out.items) |o| {
            if (o.line == m.line and o.column == m.column and o.severity == m.severity and
                std.mem.eql(u8, o.file orelse "", m.file orelse "") and std.mem.eql(u8, o.message, m.message)) continue :outer;
        }
        try out.append(a, m);
    }
    return out.items;
}

const Parser = struct {
    a: Allocator,
    out: std.ArrayList(Message) = .empty,
    res: std.ArrayList(*Regex) = .empty,

    fn deinit(p: *Parser) void {
        for (p.res.items) |r| r.deinit();
    }

    /// Compiled once per parse; each has its own allocation, so that the
    /// pointers stay valid
    fn re(p: *Parser, pattern: []const u8, flags: regex.Flags) !*const Regex {
        const r = try p.a.create(Regex);
        r.* = try Regex.compile(p.a, pattern, flags);
        try p.res.append(p.a, r);
        return r;
    }

    fn push(p: *Parser, file: ?[]const u8, line: usize, column: ?usize, sev: Severity, text: []const u8, code: ?[]const u8) !void {
        try p.out.append(p.a, .{ .file = file, .line = line, .column = column, .severity = sev, .message = std.mem.trim(u8, text, " \t"), .code = code });
    }

    /// A message without a location from the compiler driver, such as
    /// "gfortran: error: unrecognized command-line option '-Wfoo'"
    fn driver(p: *Parser, line: []const u8) !bool {
        const r = try p.re("^(?P<bin>[\\w.+-]+(?:\\.exe)?): (?P<sev>fatal error|error|warning): (?P<msg>.+)$", regex.I);
        const m = r.match(line) orelse return false;
        const sev: Severity = if (std.ascii.eqlIgnoreCase(m.named(r, "sev").?, "warning")) .warning else .@"error";
        try p.push(null, 0, null, sev, try std.fmt.allocPrint(p.a, "{s}: {s}", .{ m.named(r, "bin").?, m.named(r, "msg").? }), null);
        return true;
    }

    // --- gfortran ----------------------------------------------------------

    fn gnuSeverity(sev: []const u8) Severity {
        if (std.ascii.eqlIgnoreCase(sev, "warning")) return .warning;
        if (std.ascii.eqlIgnoreCase(sev, "note") or std.ascii.eqlIgnoreCase(sev, "remark")) return .info;
        return .@"error";
    }

    /// Splits gfortran's trailing `[-Wflag]` off into the code
    fn gnuMessage(p: *Parser, file: ?[]const u8, ln: usize, cn: ?usize, sev: []const u8, msg: []const u8) !void {
        const r = try p.re("\\s*\\[(-W[\\w=-]+)\\]$", .{});
        if (r.search(msg)) |m| {
            try p.push(file, ln, cn, gnuSeverity(sev), msg[0..m.start(0)], m.group(1));
        } else try p.push(file, ln, cn, gnuSeverity(sev), msg, null);
    }

    fn gfortran(p: *Parser, output: []const u8) !void {
        // `file:line:column: Severity: message`, as printed with
        // -fno-diagnostics-show-caret
        const one = try p.re("^(?P<file>.+?):(?P<ln>\\d+):(?:(?P<cn>\\d+):)? (?P<sev>Fatal Error|Error|Warning|Note|Remark): (?P<msg>.*)$", .{});
        // the caret format: a locus line `file:line:column:` (or with a
        // range, `file:line.column-end:`), the source excerpt, and later
        // `Severity: message`
        const locus_re = try p.re("^(?P<file>.+?):(?P<ln>\\d+)[:.](?P<cn>\\d+)(?:-\\d+)?:$", .{});
        const sev_re = try p.re("^(?P<sev>Fatal Error|Error|Warning|Note|Remark): (?P<msg>.*)$", .{});
        var locus: ?struct { file: []const u8, ln: usize, cn: usize } = null;
        var it = lines(output);
        while (it.next()) |raw| {
            const text = trimCr(raw);
            if (one.match(text)) |m| {
                try p.gnuMessage(m.named(one, "file"), num(m.named(one, "ln")), numOpt(m.named(one, "cn")), m.named(one, "sev").?, m.named(one, "msg").?);
                locus = null;
                continue;
            }
            if (locus_re.match(text)) |m| {
                // a second locus of the same message ("at (1) and (2)")
                // keeps the first
                if (locus == null) locus = .{ .file = m.named(locus_re, "file").?, .ln = num(m.named(locus_re, "ln")), .cn = num(m.named(locus_re, "cn")) };
                continue;
            }
            if (sev_re.match(text)) |m| {
                try p.gnuMessage(if (locus) |l| l.file else null, if (locus) |l| l.ln else 0, if (locus) |l| l.cn else null, m.named(sev_re, "sev").?, m.named(sev_re, "msg").?);
                locus = null;
                continue;
            }
            _ = try p.driver(text);
        }
    }

    // --- Intel ifx and ifort ------------------------------------------------

    fn intelSeverity(sev: []const u8) Severity {
        if (std.ascii.eqlIgnoreCase(sev, "warning")) return .warning;
        if (std.ascii.eqlIgnoreCase(sev, "remark") or std.ascii.eqlIgnoreCase(sev, "info")) return .info;
        return .@"error";
    }

    fn intel(p: *Parser, output: []const u8) !void {
        // `file(line): error #6404: message   [NAME]`, then the source line
        // and a caret line `-----^`; fpp prints `file(line): #error: message`
        const msg_re = try p.re("^(?P<file>.+?)\\((?P<ln>\\d+)\\): (?:#)?(?P<sev>catastrophic error|fatal error|error|warning|remark|info)(?: #(?P<code>\\d+))?: (?P<msg>.*)$", regex.I);
        const caret = try p.re("^(?P<dashes>[-.]*)\\^\\s*$", .{});
        const drv = try p.re("^(?:ifx|ifort|icx)(?:\\.exe)?: (?:command line )?(?P<sev>error|warning) #\\d+: (?P<msg>.+)$", regex.I);
        var all: std.ArrayList([]const u8) = .empty;
        var it = lines(output);
        while (it.next()) |raw| try all.append(p.a, trimCr(raw));
        for (all.items, 0..) |text, i| {
            const m = msg_re.match(text) orelse {
                if (drv.match(text)) |d| try p.push(null, 0, null, intelSeverity(d.named(drv, "sev").?), text, null);
                continue;
            };
            var column: ?usize = null;
            // the source line and the caret line follow the message
            var j = i + 1;
            while (j <= i + 2 and j < all.items.len) : (j += 1) {
                if (caret.match(all.items[j])) |c| {
                    column = c.named(caret, "dashes").?.len + 1;
                    break;
                }
                if (msg_re.match(all.items[j]) != null) break;
            }
            try p.push(m.named(msg_re, "file"), num(m.named(msg_re, "ln")), column, intelSeverity(m.named(msg_re, "sev").?), m.named(msg_re, "msg").?, m.named(msg_re, "code"));
        }
    }

    // --- NAG nagfor ----------------------------------------------------------

    fn nagSeverity(sev: []const u8) Severity {
        for ([_][]const u8{ "remark", "info", "note" }) |s| if (std.ascii.eqlIgnoreCase(sev, s)) return .info;
        for ([_][]const u8{ "warning", "questionable", "extension", "obsolescent", "deleted feature used" }) |s| if (std.ascii.eqlIgnoreCase(sev, s)) return .warning;
        return .@"error";
    }

    fn nag(p: *Parser, output: []const u8) !void {
        // `Severity: file, line N: message`; severities from section 7 of
        // the nagfor manual. A `detected at` line can follow (NAG 7).
        const msg_re = try p.re("^(?P<sev>Remark|Info|Note|Warning|Questionable|Extension|Obsolescent|Deleted feature used|(?:\\w+ )?Error|Fatal(?: Error)?|Panic)(?:\\([^)]*\\))?: (?P<file>.+?), lines? (?P<ln>\\d+)(?:-\\d+)?: (?P<msg>.*)$", .{});
        const detected = try p.re("^\\s+detected at (.+)$", .{});
        const bare = try p.re("^(?P<sev>Fatal Error|Fatal|Panic|Error): (?P<msg>.*)$", .{});
        var it = lines(output);
        while (it.next()) |raw| {
            const text = trimCr(raw);
            if (msg_re.match(text)) |m| {
                try p.push(m.named(msg_re, "file"), num(m.named(msg_re, "ln")), null, nagSeverity(m.named(msg_re, "sev").?), m.named(msg_re, "msg").?, null);
                continue;
            }
            if (detected.match(text)) |m| if (p.out.items.len > 0) {
                const last = &p.out.items[p.out.items.len - 1];
                last.message = try std.fmt.allocPrint(p.a, "{s} (detected at {s})", .{ last.message, m.group(1).? });
                continue;
            };
            if (bare.match(text)) |m| try p.push(null, 0, null, nagSeverity(m.named(bare, "sev").?), m.named(bare, "msg").?, null);
        }
    }

    // --- LFortran -------------------------------------------------------------

    fn lfortran(p: *Parser, output: []const u8) !void {
        // `--error-format=short`: `file:line-endline:col-endcol: severity
        // [code]: message`, or without a location `severity: message`
        const r = try p.re("^(?:(?P<file>.+?):(?P<ls>\\d+)-(?P<le>\\d+):(?P<cs>\\d+)-(?P<ce>\\d+): )?(?P<sev>(?:[\\w ]*error)|warning|note|help|style suggestion)(?: \\[(?P<code>[^\\]]+)\\])?: (?P<msg>.*)$", .{});
        var it = lines(output);
        while (it.next()) |raw| {
            const m = r.match(trimCr(raw)) orelse continue;
            const sev_text = m.named(r, "sev").?;
            const sev: Severity = if (std.mem.eql(u8, sev_text, "warning")) .warning else if (std.mem.eql(u8, sev_text, "note")) .info else if (std.mem.eql(u8, sev_text, "help") or std.mem.eql(u8, sev_text, "style suggestion")) .hint else .@"error";
            try p.push(m.named(r, "file"), if (m.named(r, "ls")) |s| num(s) else 0, numOpt(m.named(r, "cs")), sev, m.named(r, "msg").?, m.named(r, "code"));
            if (m.named(r, "le")) |le| {
                const last = &p.out.items[p.out.items.len - 1];
                last.end_line = num(le);
                last.end_column = numOpt(m.named(r, "ce"));
            }
        }
    }

    // --- NVIDIA nvfortran -----------------------------------------------------

    fn nvfortran(p: *Parser, output: []const u8) !void {
        // `NVFORTRAN-S-0034-Syntax error at or near end of line (file.f90:
        // 3)`; severities I(nformative), W(arning), S(evere), F(atal). Older
        // releases print PGF90- or PGFTN- instead of NVFORTRAN-.
        const r = try p.re("^(?:NVFORTRAN|PGF90|PGFTN)-(?P<sev>[IWSFV])-(?P<code>\\d+)-(?P<msg>.*?)(?: \\((?P<file>[^()]+?): ?(?P<ln>\\d+)(?:[:.] ?(?P<cn>\\d+))?\\))?\\s*$", .{});
        var it = lines(output);
        while (it.next()) |raw| {
            const m = r.match(trimCr(raw)) orelse continue;
            const s = m.named(r, "sev").?[0];
            const sev: Severity = if (s == 'W') .warning else if (s == 'I') .info else .@"error";
            try p.push(m.named(r, "file"), if (m.named(r, "ln")) |l| num(l) else 0, numOpt(m.named(r, "cn")), sev, m.named(r, "msg").?, m.named(r, "code"));
        }
    }

    // --- LLVM flang -----------------------------------------------------------

    fn flang(p: *Parser, output: []const u8) !void {
        // `file:line:column: severity: message`, as clang; flang adds
        // context lines without a severity (`file:line:column: Declaration
        // of 'x'`), which belong to the message before them
        const r = try p.re("^(?P<file>.+?):(?P<ln>\\d+):(?P<cn>\\d+): (?:(?P<sev>fatal error|error|warning|portability|note|remark|because): )?(?P<msg>.*)$", .{});
        const summary = try p.re("^error: (?:Semantic errors in|Could not scan) ", .{});
        var it = lines(output);
        while (it.next()) |raw| {
            const text = trimCr(raw);
            if (r.match(text)) |m| {
                const sev_text = m.named(r, "sev");
                const sev: ?Severity = if (sev_text) |s|
                    (if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "fatal error")) .@"error" else if (std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "portability")) .warning else if (std.mem.eql(u8, s, "remark")) .info else null)
                else
                    null;
                const ln = num(m.named(r, "ln"));
                const cn = num(m.named(r, "cn"));
                const msg = m.named(r, "msg").?;
                if (sev) |s| {
                    const text_msg = if (std.mem.eql(u8, sev_text.?, "portability")) try std.fmt.allocPrint(p.a, "portability: {s}", .{msg}) else msg;
                    try p.push(m.named(r, "file"), ln, cn, s, text_msg, null);
                } else if (p.out.items.len > 0) {
                    // a note, a "because" or a context line
                    try p.out.items[p.out.items.len - 1].related.append(p.a, .{ .file = m.named(r, "file"), .line = ln, .column = cn, .message = std.mem.trim(u8, msg, " \t") });
                }
                continue;
            }
            // "error: Semantic errors in x.f90" repeats the messages above it
            if (summary.match(text) != null) continue;
            if (try p.driver(text)) continue;
            if (std.mem.startsWith(u8, text, "error: ")) try p.push(null, 0, null, .@"error", text["error: ".len..], null);
        }
    }
};

fn lines(output: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, output, '\n');
}

fn trimCr(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r");
}

fn num(s: ?[]const u8) usize {
    return std.fmt.parseInt(usize, s orelse return 0, 10) catch 0;
}

fn numOpt(s: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, s orelse return null, 10) catch null;
}

// --- tests: the samples of editors/vscode/test/unit/lint.test.ts ------------

fn brief(a: Allocator, ms: []const Message) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (ms) |m| {
        const col = if (m.column) |c| try std.fmt.allocPrint(a, "{d}", .{c}) else "-";
        const code = if (m.code) |c| try std.fmt.allocPrint(a, " [{s}]", .{c}) else "";
        try out.append(a, try std.fmt.allocPrint(a, "{s}:{d}:{s} {s}: {s}{s}", .{ m.file orelse "-", m.line, col, @tagName(m.severity), m.message, code }));
    }
    return out.items;
}

fn expectBrief(id: Id, output: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try brief(a, try parse(a, id, output));
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "gfortran one-line messages" {
    try expectBrief(.gfortran,
        \\main.f90:5:7: Error: Symbol 'j' at (1) has no IMPLICIT type
        \\inc.h:2:21: Error: Symbol 'undefined_thing' at (1) has no IMPLICIT type
        \\warn.f90:6:16: Warning: Unused variable 'unused' declared at (1) [-Wunused-variable]
        \\usem.f90:2:7: Fatal Error: Cannot open module file 'nonexistent_mod.mod' for reading at (1): No such file or directory
        \\compilation terminated.
    , &.{
        "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
        "inc.h:2:21 error: Symbol 'undefined_thing' at (1) has no IMPLICIT type",
        "warn.f90:6:16 warning: Unused variable 'unused' declared at (1) [-Wunused-variable]",
        "usem.f90:2:7 error: Cannot open module file 'nonexistent_mod.mod' for reading at (1): No such file or directory",
    });
}

test "gfortran caret format" {
    try expectBrief(.gfortran, "main.f90:5:7:\r\n\r\n    5 |   i = j + 1\r\n      |       1\r\nError: Symbol 'j' at (1) has no IMPLICIT type\r\n" ++
        "C:\\src\\fixed.f:4:11:\r\n\r\n    4 |       i = q\r\n      |           1\r\nError: Symbol 'q' at (1) has no IMPLICIT type\r\n" ++
        "two.f90:8.13-15:\r\ntwo.f90:12:3:\r\nWarning: Type mismatch at (1) and (2)\r\n", &.{
        "main.f90:5:7 error: Symbol 'j' at (1) has no IMPLICIT type",
        "C:\\src\\fixed.f:4:11 error: Symbol 'q' at (1) has no IMPLICIT type",
        "two.f90:8:13 warning: Type mismatch at (1) and (2)",
    });
}

test "gfortran driver messages" {
    try expectBrief(.gfortran,
        \\gfortran: error: unrecognized command-line option '-Wbogus'
        \\f951.exe: Warning: Nonexistent include directory 'nope' [-Wmissing-include-dirs]
    , &.{
        "-:0:- error: gfortran: unrecognized command-line option '-Wbogus'",
        "-:0:- warning: f951.exe: Nonexistent include directory 'nope' [-Wmissing-include-dirs]",
    });
}

test "ifx and ifort messages" {
    try expectBrief(.ifx,
        \\test.f90(3): error #6404: This name does not have a type, and must have an explicit type.   [X]
        \\  x = 1
        \\--^
        \\C:\work\test.f90(7): warning #6717: This name has not been given an explicit type.   [Y]
        \\      y = 2
        \\------^
        \\test.f90(9): remark #7712: This variable has not been used.   [Z]
        \\test.f90(2): #error: unsupported configuration
        \\test.f90(12): catastrophic error: Too many errors, exiting
        \\compilation aborted for test.f90 (code 1)
    , &.{
        "test.f90:3:3 error: This name does not have a type, and must have an explicit type.   [X] [6404]",
        "C:\\work\\test.f90:7:7 warning: This name has not been given an explicit type.   [Y] [6717]",
        "test.f90:9:- info: This variable has not been used.   [Z] [7712]",
        "test.f90:2:- error: unsupported configuration",
        "test.f90:12:- error: Too many errors, exiting",
    });
}

test "nagfor messages" {
    try expectBrief(.nagfor,
        \\Error: test.f90, line 4: Implicit type for Y in MAIN
        \\       detected at Y@=
        \\Warning: test.f90, line 6: Unused local variable X
        \\Extension(F2008): test.f90, line 8: Unlimited format item
        \\Questionable: sub.f90, line 10: Variable K set but never referenced
        \\Deleted feature used: old.f, line 12: Assigned GOTO statement
        \\Fatal Error: test.f90, line 2: Cannot find module FOO
        \\[NAG Fortran Compiler error termination, 2 errors, 1 warning]
    , &.{
        "test.f90:4:- error: Implicit type for Y in MAIN (detected at Y@=)",
        "test.f90:6:- warning: Unused local variable X",
        "test.f90:8:- warning: Unlimited format item",
        "sub.f90:10:- warning: Variable K set but never referenced",
        "old.f:12:- warning: Assigned GOTO statement",
        "test.f90:2:- error: Cannot find module FOO",
    });
}

test "lfortran messages" {
    try expectBrief(.lfortran,
        \\test.f90:3-3:5-7: semantic error: Variable 'abc' is not declared
        \\test.f90:5-6:1-10: syntax error: Token 'end' is unexpected here
        \\test.f90:8-8:3-3: warning: The variable 'x' is used before it is set
        \\test.f90:9-9:3-9: style suggestion: Use '**' instead
        \\C preprocessor error: cannot open 'x.h'
    , &.{
        "test.f90:3:5 error: Variable 'abc' is not declared",
        "test.f90:5:1 error: Token 'end' is unexpected here",
        "test.f90:8:3 warning: The variable 'x' is used before it is set",
        "test.f90:9:3 hint: Use '**' instead",
        "-:0:- error: cannot open 'x.h'",
    });
}

test "nvfortran messages" {
    try expectBrief(.nvfortran,
        \\NVFORTRAN-S-0034-Syntax error at or near end of line (test.f90: 3)
        \\NVFORTRAN-W-0155-Unused variable x (test.f90: 7)
        \\NVFORTRAN-F-0004-Unable to open MODULE file foo.mod (use.f90: 2)
        \\NVFORTRAN-I-0035-Predefined intrinsic sum loses intrinsic property (test.f90: 9:12)
        \\PGF90-S-0038-Symbol, y, has not been explicitly declared (old.f90: 4)
        \\  0 inform,   1 warnings,   1 severes, 0 fatal for main
    , &.{
        "test.f90:3:- error: Syntax error at or near end of line [0034]",
        "test.f90:7:- warning: Unused variable x [0155]",
        "use.f90:2:- error: Unable to open MODULE file foo.mod [0004]",
        "test.f90:9:12 info: Predefined intrinsic sum loses intrinsic property [0035]",
        "old.f90:4:- error: Symbol, y, has not been explicitly declared [0038]",
    });
}

test "flang messages and their context lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out =
        \\error: Semantic errors in test.f90
        \\./test.f90:3:3: error: No explicit type declared for 'x'
        \\    x = 1
        \\    ^
        \\./test.f90:5:7: error: 'y' is already declared in this scoping unit
        \\    real :: y
        \\            ^
        \\./test.f90:4:14: Previous declaration of 'y'
        \\./test.f90:8:1: portability: nonstandard usage: tab character
        \\./test.f90:9:3: warning: Variable 'z' is used but never defined [-Wused-undefined-variable]
        \\flang: error: unknown argument: '-Wbogus'
    ;
    const ms = try parse(a, .flang, out);
    const want = [_][]const u8{
        "./test.f90:3:3 error: No explicit type declared for 'x'",
        "./test.f90:5:7 error: 'y' is already declared in this scoping unit",
        "./test.f90:8:1 warning: portability: nonstandard usage: tab character",
        "./test.f90:9:3 warning: Variable 'z' is used but never defined [-Wused-undefined-variable]",
        "-:0:- error: flang: unknown argument: '-Wbogus'",
    };
    const got = try brief(a, ms);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expectEqual(@as(usize, 1), ms[1].related.items.len);
    try std.testing.expectEqualStrings("Previous declaration of 'y'", ms[1].related.items[0].message);
    try std.testing.expectEqual(@as(usize, 4), ms[1].related.items[0].line);
}

test "repeated messages are dropped" {
    try expectBrief(.gfortran, "a.f90:1:2: Error: x\na.f90:1:2: Error: x\na.f90:1:3: Error: x\n", &.{ "a.f90:1:2 error: x", "a.f90:1:3 error: x" });
}
