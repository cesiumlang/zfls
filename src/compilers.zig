//! The compilers whose messages zfls publishes as diagnostics
//! (`compiler_diagnostics`): their command-line options and parsers of
//! their messages (gfortran's, LLVM Flang's and Intel's in compilers/). A
//! port of the VS Code extension's linter
//! (editors/vscode/src/lint/compilers.ts), whose tests the ones here
//! follow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const Regex = regex.Regex;
const flang = @import("compilers/flang.zig");
const intel = @import("compilers/intel.zig");
const gfortran = @import("compilers/gfortran.zig");

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
    /// For a message in an included file, the line that includes it (of
    /// the outermost include), such as flang's "included here"
    include_site: ?Related = null,
};

/// What changes a compiler's command line
pub const Options = struct {
    /// Intel's compilers take /options on Windows
    windows: bool,
    /// Where the compiler writes .mod (and any object) files
    mod_dir: []const u8,
    /// The compiler's major version, when known (LLVM Flang's)
    version: ?u32 = null,
    /// The compiler's intrinsic modules, where its driver does not look:
    /// LLVM Flang's (compilers/flang_modules.zig), conda-forge's ifx's
    /// (`intel.moduleDir`)
    intrinsic_modules: ?[]const u8 = null,
    /// zfls reads OpenMP's conditional lines (`!$ `) as code
    /// (`disable_openmp_conditional` off): the compiler should too
    openmp: bool = false,
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
        // --continue-compilation: every error, not only the first
        .lfortran => &.{ "--semantics-only", "--continue-compilation", "--error-format=short", "--no-color" },
        // no syntax-only mode: compile, with the object file next to the
        // .mod files rather than in the source tree
        .nvfortran => try dupeArgs(a, &.{ "-c", "-o", try std.Io.Dir.path.join(a, &.{ o.mod_dir, "zfls-lint.o" }) }),
        .flang => &.{ "-fsyntax-only", "-fno-color-diagnostics" },
    };
}

/// Compile a module that the file checked uses, for its .mod files: as
/// `syntaxOnly`, except for LFortran, whose --semantics-only writes none
pub fn moduleOnly(a: Allocator, id: Id, o: Options) ![]const []const u8 {
    return switch (id) {
        // the symbol tables only, without the executable statements: enough
        // for the users of its type-bound procedures, defined operators and
        // pure functions. -c and -o: LFortran writes .mod files only when
        // it compiles, and the object goes next to them, not into the
        // source tree.
        .lfortran => try dupeArgs(a, &.{ "--symtab-only", "-c", "-o", try std.Io.Dir.path.join(a, &.{ o.mod_dir, "zfls-lint.o" }), "--error-format=short", "--no-color" }),
        else => syntaxOnly(a, id, o),
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

/// The line length of the file's form: for fixed form `fixed_columns`
/// (`fixed_line_length`; null: the compiler's default), for free form no
/// limit. Nothing when the compiler has no option for it, or that is its
/// default.
pub fn lineLength(a: Allocator, id: Id, fixed: bool, fixed_columns: ?usize, o: Options) ![]const []const u8 {
    if (!fixed) return switch (id) {
        // gfortran cuts free-form lines at 132 columns
        .gfortran => &.{"-ffree-line-length-none"},
        .ifx, .ifort, .nagfor, .lfortran, .nvfortran, .flang => &.{},
    };
    const n = fixed_columns orelse return &.{};
    return switch (id) {
        .gfortran => dupeArgs(a, &.{try a.print("-ffixed-line-length-{d}", .{n})}),
        .flang => dupeArgs(a, &.{try a.print("-ffixed-line-length={d}", .{n})}),
        .ifx, .ifort => switch (n) {
            72, 80, 132 => if (o.windows) dupeArgs(a, &.{try a.print("/extend-source:{d}", .{n})}) else dupeArgs(a, &.{ "-extend-source", try a.print("{d}", .{n}) }),
            else => &.{},
        },
        .nvfortran => if (n == 132) &.{"-Mextend"} else &.{},
        .nagfor => if (n == 132) &.{"-132"} else &.{},
        .lfortran => &.{},
    };
}

/// How a fixed-form file's debug lines (D or d in column 1) are read, as
/// zfls reads them (`d_lines`): as code or as comments. gfortran rejects
/// them without an option; LFortran has none.
pub fn dLines(id: Id, code: bool, o: Options) []const []const u8 {
    return switch (id) {
        .gfortran => if (code) &.{"-fd-lines-as-code"} else &.{"-fd-lines-as-comments"},
        .flang => flang.dLines(code, o.version),
        .ifx, .ifort => if (o.windows)
            (if (code) &.{"/d-lines"} else &.{"/nod-lines"})
        else
            (if (code) &.{"-d-lines"} else &.{"-nod-lines"}),
        .nvfortran => if (code) &.{"-Mdlines"} else &.{"-Mnodlines"},
        // comments by default
        .nagfor => if (code) &.{"-d_lines"} else &.{},
        .lfortran => &.{},
    };
}

/// The option for the file's language, right before it: the drivers of
/// gfortran, Flang and Intel's compilers check only the suffixes they know
/// (`gfortran.language`, `flang.language`, `intel.language`)
pub fn language(id: Id, o: Options) []const []const u8 {
    return switch (id) {
        .gfortran => gfortran.language,
        .flang => flang.language,
        .ifx, .ifort => intel.language(o),
        else => &.{},
    };
}

/// Whether `arg` sets the line length of the form (the user's then wins
/// over `lineLength`)
pub fn isLineLength(id: Id, fixed: bool, arg: []const u8) bool {
    const prefixes: []const []const u8 = switch (id) {
        .gfortran, .flang => if (fixed) &.{"-ffixed-line-length"} else &.{"-ffree-line-length"},
        .ifx, .ifort => if (fixed) &.{ "-extend-source", "-extend_source", "/extend-source", "/extend_source", "/4L" } else &.{},
        .nvfortran => if (fixed) &.{ "-Mextend", "-Mnoextend" } else &.{},
        .nagfor => if (fixed) &.{"-132"} else &.{},
        .lfortran => &.{},
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, arg, p)) return true;
    return false;
}

/// Whether `arg` of `compiler_args` says how debug lines are read, which
/// `dLines` then leaves to it
pub fn isDLinesArg(arg: []const u8) bool {
    const names = [_][]const u8{ "-fd-lines-as-code", "-fd-lines-as-comments", "-d-lines", "-nod-lines", "/d-lines", "/nod-lines", "-Mdlines", "-Mnodlines", "-d_lines" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(arg, n)) return true;
    return false;
}

/// The arguments when `compiler_args` is not set (and the file has no
/// command): the compiler's warnings, coarrays (one image: nothing else
/// matters for a check, and without it gfortran and Intel's stop at the
/// first coarray), and OpenMP when zfls reads its conditional lines
/// (`o.openmp`), so that the compiler reads them as code too. Flang reads
/// coarrays without an option (`-fcoarray` only adds a warning that they
/// are experimental, Flang 23).
pub fn defaultArgs(a: Allocator, id: Id, o: Options) ![]const []const u8 {
    const warnings: []const []const u8 = switch (id) {
        .gfortran => &.{"-Wall"},
        // what gfortran's -Wall warns about: not every implicitly typed
        // name (#6717) and every call without an explicit interface
        // (#8889), which `all` has (#514)
        .ifx, .ifort => if (o.windows) &.{"/warn:all,nodeclarations,noexternals"} else &.{ "-warn", "all,nodeclarations,noexternals" },
        .nvfortran => &.{"-Minform=warn"},
        .flang => flang.warnings(o.version),
        .nagfor, .lfortran => &.{},
    };
    const coarrays: []const []const u8 = switch (id) {
        .gfortran => &.{"-fcoarray=single"},
        .ifx, .ifort => if (o.windows) &.{"/Qcoarray:single"} else &.{"-coarray=single"},
        else => &.{},
    };
    const openmp: []const []const u8 = if (!o.openmp) &.{} else switch (id) {
        .gfortran, .flang => &.{"-fopenmp"},
        .ifx, .ifort => if (o.windows) &.{"/Qopenmp"} else &.{"-qopenmp"},
        else => &.{},
    };
    return std.mem.concat(a, []const u8, &.{ warnings, coarrays, openmp });
}

test "the default arguments: warnings, coarrays, and OpenMP as zfls reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const linux: Options = .{ .windows = false, .mod_dir = "m", .openmp = true };
    const win: Options = .{ .windows = true, .mod_dir = "m", .openmp = true };
    const no_omp: Options = .{ .windows = false, .mod_dir = "m" };
    try expectArgs(try defaultArgs(a, .gfortran, linux), &.{ "-Wall", "-fcoarray=single", "-fopenmp" });
    try expectArgs(try defaultArgs(a, .gfortran, no_omp), &.{ "-Wall", "-fcoarray=single" });
    try expectArgs(try defaultArgs(a, .ifx, win), &.{ "/warn:all,nodeclarations,noexternals", "/Qcoarray:single", "/Qopenmp" });
    try expectArgs(try defaultArgs(a, .ifort, linux), &.{ "-warn", "all,nodeclarations,noexternals", "-coarray=single", "-qopenmp" });
    try expectArgs(try defaultArgs(a, .flang, .{ .windows = false, .mod_dir = "m", .version = 23, .openmp = true }), &.{ "-Wunused-variable", "-Wused-undefined-variable", "-fopenmp" });
    try expectArgs(try defaultArgs(a, .flang, linux), &.{"-fopenmp"});
    try expectArgs(try defaultArgs(a, .nvfortran, linux), &.{"-Minform=warn"});
    try expectArgs(try defaultArgs(a, .lfortran, linux), &.{});
}

fn expectArgs(got: []const []const u8, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

/// Accept implicit typing and implicit interfaces, as the standard does:
/// LFortran's own dialect (`--std=lf`, its default) rejects them, which
/// gives standard code without IMPLICIT NONE, and most fixed form, false
/// errors. Each is left out when `own` (`compiler_args`, or the project's
/// command) has an option about it, and both when `own` chooses a standard
/// (`--disable-implicit-typing` with `--implicit-typing` is an error).
/// Not `--std=f23`: it also casts arguments implicitly, which hides
/// arguments of the wrong type.
pub fn implicitRules(id: Id, own: []const []const u8) []const []const u8 {
    if (id != .lfortran) return &.{};
    var typing = true;
    var interface = true;
    for (own) |x| {
        if (std.mem.startsWith(u8, x, "--std")) return &.{};
        if (std.mem.eql(u8, x, "--implicit-typing") or std.mem.eql(u8, x, "--disable-implicit-typing")) typing = false;
        if (std.mem.eql(u8, x, "--implicit-interface") or std.mem.eql(u8, x, "--disable-implicit-interface")) interface = false;
    }
    const both: []const []const u8 = &.{ "--implicit-typing", "--implicit-interface" };
    if (typing and interface) return both;
    if (typing) return both[0..1];
    if (interface) return both[1..];
    return &.{};
}

/// Write .mod files to, and read them from, `dir`
pub fn modOutput(a: Allocator, id: Id, dir: []const u8, o: Options) ![]const []const u8 {
    return switch (id) {
        .gfortran => dupeArgs(a, &.{try a.print("-J{s}", .{dir})}),
        .ifx, .ifort => if (o.windows) dupeArgs(a, &.{try a.print("/module:{s}", .{dir})}) else dupeArgs(a, &.{ "-module", dir }),
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
        .ifx, .ifort => dupeArgs(a, &.{try a.print("{s}{s}", .{ if (o.windows) "/I" else "-I", dir })}),
        else => dupeArgs(a, &.{try a.print("-I{s}", .{dir})}),
    };
}

/// A preprocessor definition, `-DNAME=VALUE` (or `-DNAME`)
pub fn define(a: Allocator, id: Id, name: []const u8, value: []const u8, o: Options) ![]const u8 {
    const flag = if ((id == .ifx or id == .ifort) and o.windows) "/D" else "-D";
    if (value.len == 0) return a.print("{s}{s}", .{ flag, name });
    return a.print("{s}{s}={s}", .{ flag, name, value });
}

/// Whether the compiler writes files into its working directory even when
/// it only checks the source: Intel's write their preprocessor's output
/// (`file.i90`, `file.i`) there, so they run in a directory of zfls's
/// rather than beside the sources
pub fn writesToWorkDir(id: Id) bool {
    return id == .ifx or id == .ifort;
}

/// Whether the compiler runs in a directory of zfls's: those of
/// `writesToWorkDir`, and every one on Windows, where a program loads a DLL
/// from its working directory before the PATH's, so a workspace could put
/// its own beside the sources for MinGW's f951, which finds its DLLs on the
/// PATH (#528)
pub fn runsInWorkDir(id: Id, windows: bool) bool {
    return windows or writesToWorkDir(id);
}

/// `args` with the relative directories of its include and module options
/// made absolute against `base`, for a compiler run in another directory
/// (`runsInWorkDir`): `-Idir`, `-I dir`, `-Jdir`, `-J dir`, `-module dir`,
/// `-module-dir dir`, `-isystem dir` (and `-iquote`, `-idirafter`) and, on
/// Windows, `/Idir`, `/I dir`, `/module:dir`
pub fn absoluteDirs(a: Allocator, id: Id, args: []const []const u8, base: []const u8, o: Options) ![]const []const u8 {
    if (!runsInWorkDir(id, o.windows)) return args;
    const out = try a.dupe([]const u8, args);
    const joined = struct {
        fn f(al: Allocator, b: []const u8, prefix: []const u8, dir: []const u8) ![]const u8 {
            if (dir.len == 0 or std.Io.Dir.path.isAbsolute(dir)) return std.mem.concat(al, u8, &.{ prefix, dir });
            return std.mem.concat(al, u8, &.{ prefix, try std.Io.Dir.path.join(al, &.{ b, dir }) });
        }
    }.f;
    // the options whose value is the next argument, and those with it
    // attached
    const separate: []const []const u8 = if (o.windows)
        &.{ "-I", "/I", "-J", "-module", "/module", "-module-dir", "-isystem", "-iquote", "-idirafter" }
    else
        &.{ "-I", "-J", "-module", "-module-dir", "-isystem", "-iquote", "-idirafter" };
    const attached: []const []const u8 = if (o.windows) &.{ "/module:", "-I", "/I", "-J" } else &.{ "-I", "-J" };
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const x = out[i];
        if (for (separate) |s| {
            if (std.mem.eql(u8, x, s)) break true;
        } else false) {
            if (i + 1 < out.len) {
                out[i + 1] = try joined(a, base, "", out[i + 1]);
                i += 1;
            }
            continue;
        }
        for (attached) |p| if (std.mem.startsWith(u8, x, p)) {
            out[i] = try joined(a, base, p, x[p.len..]);
            break;
        };
    }
    return out;
}

/// The messages in a compiler's output
pub fn parse(a: Allocator, id: Id, output: []const u8) ![]Message {
    var p: Parser = .{ .a = a };
    defer p.deinit();
    switch (id) {
        .gfortran => try gfortran.parse(&p, output),
        .ifx, .ifort => try intel.parse(&p, output),
        .nagfor => try p.nag(output),
        .lfortran => try p.lfortran(output),
        .nvfortran => try p.nvfortran(output),
        .flang => try flang.parse(&p, output),
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

pub const Parser = struct {
    a: Allocator,
    out: std.ArrayList(Message) = .empty,
    res: std.ArrayList(*Regex) = .empty,

    fn deinit(p: *Parser) void {
        for (p.res.items) |r| r.deinit();
    }

    /// Compiled once per parse; each has its own allocation, so that the
    /// pointers stay valid
    pub fn re(p: *Parser, pattern: []const u8, flags: regex.Flags) !*const Regex {
        const r = try p.a.create(Regex);
        r.* = try Regex.compile(p.a, pattern, flags);
        try p.res.append(p.a, r);
        return r;
    }

    pub fn push(p: *Parser, file: ?[]const u8, line: usize, column: ?usize, sev: Severity, text: []const u8, code: ?[]const u8) !void {
        try p.out.append(p.a, .{ .file = file, .line = line, .column = column, .severity = sev, .message = std.mem.trim(u8, text, " \t"), .code = code });
    }

    /// A message without a location from the compiler driver, such as
    /// "gfortran: error: unrecognized command-line option '-Wfoo'"; a
    /// trailing `[-Wname]` is its code ("f951.exe: Warning: Nonexistent
    /// include directory 'x' [-Wmissing-include-dirs]")
    pub fn driver(p: *Parser, line: []const u8) !bool {
        const r = try p.re("^(?P<bin>[\\w.+-]+(?:\\.exe)?): (?P<sev>fatal error|error|warning): (?P<msg>.+)$", regex.I);
        const m = r.match(line) orelse return false;
        const sev: Severity = if (std.ascii.eqlIgnoreCase(m.named(r, "sev").?, "warning")) .warning else .@"error";
        var msg = m.named(r, "msg").?;
        var code: ?[]const u8 = null;
        const code_re = try p.re("\\s*\\[(-W[\\w=-]+)\\]$", .{});
        if (code_re.search(msg)) |c| {
            code = c.group(1);
            msg = msg[0..c.start(0)];
        }
        try p.push(null, 0, null, sev, try p.a.print("{s}: {s}", .{ m.named(r, "bin").?, msg }), code);
        return true;
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
                last.message = try p.a.print("{s} (detected at {s})", .{ last.message, m.group(1).? });
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
        // the other lines are messages too, without a location: about the
        // command line ("The following argument was not expected: --x",
        // "Cannot use --disable-implicit-typing and --implicit-typing at
        // the same time"), a file that cannot be opened, an internal
        // error. The lines of one (a traceback) go together, up to an
        // empty line or a message of the format above.
        var free: std.ArrayList(u8) = .empty;
        var it = lines(output);
        while (it.next()) |raw| {
            const text = std.mem.trimEnd(u8, trimCr(raw), " \t");
            const m = r.match(text) orelse {
                if (text.len == 0) {
                    try p.unlocated(&free);
                } else if (!lfortranNoise(text)) {
                    if (free.items.len > 0) try free.append(p.a, '\n');
                    try free.appendSlice(p.a, text);
                }
                continue;
            };
            try p.unlocated(&free);
            const sev_text = m.named(r, "sev").?;
            const sev: Severity = if (std.mem.eql(u8, sev_text, "warning")) .warning else if (std.mem.eql(u8, sev_text, "note")) .info else if (std.mem.eql(u8, sev_text, "help") or std.mem.eql(u8, sev_text, "style suggestion")) .hint else .@"error";
            try p.push(m.named(r, "file"), if (m.named(r, "ls")) |s| num(s) else 0, numOpt(m.named(r, "cs")), sev, m.named(r, "msg").?, m.named(r, "code"));
            if (m.named(r, "le")) |le| {
                const last = &p.out.items[p.out.items.len - 1];
                last.end_line = num(le);
                last.end_column = numOpt(m.named(r, "ce"));
            }
        }
        try p.unlocated(&free);
    }

    /// The lines gathered in `free`, as one error without a location
    fn unlocated(p: *Parser, free: *std.ArrayList(u8)) !void {
        if (free.items.len == 0) return;
        try p.push(null, 0, null, .@"error", try free.toOwnedSlice(p.a), null);
    }

    /// LFortran's lines that are no message: the advice after a
    /// command-line error, and the request for reports after the messages
    /// of its human format
    fn lfortranNoise(text: []const u8) bool {
        return std.mem.eql(u8, text, "Run with --help for more information.") or
            std.mem.startsWith(u8, text, "Note: Please report unclear") or
            std.mem.startsWith(u8, text, "https://github.com/lfortran/lfortran/issues");
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
};

pub fn lines(output: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, output, '\n');
}

pub fn trimCr(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r");
}

pub fn num(s: ?[]const u8) usize {
    return std.fmt.parseInt(usize, s orelse return 0, 10) catch 0;
}

pub fn numOpt(s: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, s orelse return null, 10) catch null;
}

// --- tests: the samples of editors/vscode/test/unit/lint.test.ts ------------

/// One line per message, for the tests
pub fn brief(a: Allocator, ms: []const Message) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (ms) |m| {
        const col = if (m.column) |c| try a.print("{d}", .{c}) else "-";
        const code = if (m.code) |c| try a.print(" [{s}]", .{c}) else "";
        try out.append(a, try a.print("{s}:{d}:{s} {s}: {s}{s}", .{ m.file orelse "-", m.line, col, @tagName(m.severity), m.message, code }));
    }
    return out.items;
}

/// Fails unless `output` parses to the messages `want` (as `brief`)
pub fn expectBrief(id: Id, output: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try brief(a, try parse(a, id, output));
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "the arguments for debug lines: as zfls reads them, unless the user's say" {
    const o: Options = .{ .windows = false, .mod_dir = "m" };
    try std.testing.expectEqualStrings("-fd-lines-as-code", dLines(.gfortran, true, o)[0]);
    try std.testing.expectEqualStrings("-fd-lines-as-comments", dLines(.gfortran, false, o)[0]);
    try std.testing.expectEqualStrings("-d-lines", dLines(.ifx, true, o)[0]);
    try std.testing.expectEqualStrings("/nod-lines", dLines(.ifort, false, .{ .windows = true, .mod_dir = "m" })[0]);
    try std.testing.expectEqual(@as(usize, 0), dLines(.lfortran, true, o).len);
    try std.testing.expect(isDLinesArg("-fd-lines-as-code") and isDLinesArg("/D-Lines") and !isDLinesArg("-Wall"));
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
        \\pp.F90:2-2:11-19: C preprocessor error: Include file 'nothere.h' not found.
        \\C:\w\a b.f90:3-3:3-13: semantic error: Function 'ext' not found (not user defined nor intrinsic)
        \\semantic error: no main program found; cannot build an executable.
    , &.{
        "test.f90:3:5 error: Variable 'abc' is not declared",
        "test.f90:5:1 error: Token 'end' is unexpected here",
        "test.f90:8:3 warning: The variable 'x' is used before it is set",
        "test.f90:9:3 hint: Use '**' instead",
        "-:0:- error: cannot open 'x.h'",
        "pp.F90:2:11 error: Include file 'nothere.h' not found.",
        "C:\\w\\a b.f90:3:3 error: Function 'ext' not found (not user defined nor intrinsic)",
        "-:0:- error: no main program found; cannot build an executable.",
    });
}

test "lfortran messages without a location" {
    // as LFortran 0.69 prints them
    try expectBrief(.lfortran, "The following argument was not expected: --bogus\r\nRun with --help for more information.\r\n", &.{
        "-:0:- error: The following argument was not expected: --bogus",
    });
    try expectBrief(.lfortran,
        \\The option `--std=f77` is not supported
        \\error: no such file or directory: 'nofile.f90'
        \\File 'incdir' cannot be opened.
        \\Cannot use --disable-implicit-typing and --implicit-typing at the same time
        \\
        \\Internal Compiler Error: Unhandled exception
        \\Traceback (most recent call last):
        \\  File "lfortran.cpp", line 10
        \\a.f90:1-1:1-1: semantic error: x
        \\
    , &.{
        "-:0:- error: The option `--std=f77` is not supported",
        "-:0:- error: no such file or directory: 'nofile.f90'",
        "-:0:- error: File 'incdir' cannot be opened.\nCannot use --disable-implicit-typing and --implicit-typing at the same time",
        "-:0:- error: Internal Compiler Error: Unhandled exception\nTraceback (most recent call last):\n  File \"lfortran.cpp\", line 10",
        "a.f90:1:1 error: x",
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

test "the modules a file uses: LFortran compiles their symbol tables, which writes .mod files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o: Options = .{ .windows = false, .mod_dir = "m" };
    const lf = try moduleOnly(a, .lfortran, o);
    try std.testing.expectEqualStrings("--symtab-only", lf[0]);
    try std.testing.expectEqualStrings("-c", lf[1]);
    try std.testing.expectEqualStrings(try std.Io.Dir.path.join(a, &.{ "m", "zfls-lint.o" }), lf[3]);
    // the file itself: semantics only, and every error
    const check = try syntaxOnly(a, .lfortran, o);
    try std.testing.expectEqualStrings("--semantics-only", check[0]);
    try std.testing.expectEqualStrings("--continue-compilation", check[1]);
    try std.testing.expectEqualStrings("-fsyntax-only", (try moduleOnly(a, .gfortran, o))[0]);
}

fn expectImplicitRules(own: []const []const u8, want: []const []const u8) !void {
    const got = implicitRules(.lfortran, own);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "LFortran: implicit typing and interfaces, unless the user's options say" {
    try expectImplicitRules(&.{}, &.{ "--implicit-typing", "--implicit-interface" });
    try expectImplicitRules(&.{"--disable-implicit-typing"}, &.{"--implicit-interface"});
    try expectImplicitRules(&.{"--implicit-interface"}, &.{"--implicit-typing"});
    try expectImplicitRules(&.{ "--implicit-typing", "--implicit-interface" }, &.{});
    try expectImplicitRules(&.{"--std=f23"}, &.{});
    try expectImplicitRules(&.{ "--std", "lf" }, &.{});
    try std.testing.expectEqual(@as(usize, 0), implicitRules(.gfortran, &.{}).len);
}

fn expectLineLength(id: Id, fixed: bool, columns: ?usize, windows: bool, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try lineLength(arena.allocator(), id, fixed, columns, .{ .windows = windows, .mod_dir = "m" });
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "line lengths: fixed form as fixed_line_length, free form without a limit" {
    try expectLineLength(.gfortran, true, 132, false, &.{"-ffixed-line-length-132"});
    try expectLineLength(.gfortran, true, null, false, &.{});
    try expectLineLength(.gfortran, false, null, false, &.{"-ffree-line-length-none"});
    try expectLineLength(.gfortran, false, 72, false, &.{"-ffree-line-length-none"});
    try expectLineLength(.flang, true, 80, false, &.{"-ffixed-line-length=80"});
    try expectLineLength(.flang, false, null, false, &.{});
    try expectLineLength(.ifx, true, 132, false, &.{ "-extend-source", "132" });
    try expectLineLength(.ifort, true, 80, true, &.{"/extend-source:80"});
    try expectLineLength(.ifx, true, 100, false, &.{});
    try expectLineLength(.ifx, false, null, true, &.{});
    try expectLineLength(.nvfortran, true, 132, false, &.{"-Mextend"});
    try expectLineLength(.nvfortran, true, 80, false, &.{});
    try expectLineLength(.nagfor, true, 132, false, &.{"-132"});
    try expectLineLength(.nagfor, true, 72, false, &.{});
    try expectLineLength(.lfortran, true, 132, false, &.{});
}

test "line lengths: the user's options of the same form" {
    try std.testing.expect(isLineLength(.gfortran, true, "-ffixed-line-length-none"));
    try std.testing.expect(!isLineLength(.gfortran, false, "-ffixed-line-length-none"));
    try std.testing.expect(isLineLength(.gfortran, false, "-ffree-line-length-200"));
    try std.testing.expect(isLineLength(.flang, true, "-ffixed-line-length=132"));
    try std.testing.expect(isLineLength(.ifx, true, "/extend-source:132"));
    try std.testing.expect(isLineLength(.ifort, true, "-extend-source"));
    try std.testing.expect(isLineLength(.ifort, true, "/4L132"));
    try std.testing.expect(isLineLength(.nvfortran, true, "-Mextend"));
    try std.testing.expect(isLineLength(.nagfor, true, "-132"));
    try std.testing.expect(!isLineLength(.gfortran, true, "-Wall"));
}

test "repeated messages are dropped" {
    try expectBrief(.gfortran, "a.f90:1:2: Error: x\na.f90:1:2: Error: x\na.f90:1:3: Error: x\n", &.{ "a.f90:1:2 error: x", "a.f90:1:3 error: x" });
}

fn expectAbsoluteDirs(id: Id, windows: bool, args: []const []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = if (windows) "C:\\src" else "/src";
    const got = try absoluteDirs(arena.allocator(), id, args, base, .{ .windows = windows, .mod_dir = "m" });
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "Intel's relative include and module directories, made absolute for a run elsewhere" {
    if (@import("builtin").target.os.tag == .windows) {
        try expectAbsoluteDirs(.ifx, true, &.{ "/warn:all", "/Iinc", "/I", "more", "-Iother", "/module:mods", "/IC:\\abs" }, &.{ "/warn:all", "/IC:\\src\\inc", "/I", "C:\\src\\more", "-IC:\\src\\other", "/module:C:\\src\\mods", "/IC:\\abs" });
    } else {
        try expectAbsoluteDirs(.ifort, false, &.{ "-warn", "all", "-Iinc", "-I", "more", "-module", "mods", "-I/abs" }, &.{ "-warn", "all", "-I/src/inc", "-I", "/src/more", "-module", "/src/mods", "-I/abs" });
    }
    // the other compilers run beside the file: unchanged
    try expectAbsoluteDirs(.gfortran, false, &.{"-Iinc"}, &.{"-Iinc"});
}

test "on Windows every compiler runs in zfls's directory, with its directories absolute" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    try expectAbsoluteDirs(.gfortran, true, &.{ "-Iinc", "-J", "mods", "-Jm2", "-isystem", "sys", "-Wall" }, &.{ "-IC:\\src\\inc", "-J", "C:\\src\\mods", "-JC:\\src\\m2", "-isystem", "C:\\src\\sys", "-Wall" });
    try expectAbsoluteDirs(.flang, true, &.{ "-module-dir", "mods", "-I", "C:\\abs" }, &.{ "-module-dir", "C:\\src\\mods", "-I", "C:\\abs" });
}
