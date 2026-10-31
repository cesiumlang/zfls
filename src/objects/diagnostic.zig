//! Diagnostics of objects, before and after they are placed in a file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const C = @import("../constants.zig");
const parser = @import("../parser.zig");
const FortranFile = parser.FortranFile;

const objects = @import("../objects.zig");

/// A diagnostic pending conversion into an LSP diagnostic
pub const Diagnostic = struct {
    code: C.DiagCode,
    sline: usize,
    message: []const u8,
    severity: i32 = 1,
    find_word: ?[]const u8 = null,
    related: ?Related = null,
    /// What the diagnostic is about, when settings may single it out (the
    /// module of `module-not-found`)
    subject: ?[]const u8 = null,

    pub const Related = struct { path: ?[]const u8, line: usize, message: []const u8 };

    pub fn init(code: C.DiagCode, sline: usize, message: []const u8, severity: i32, find_word: ?[]const u8) Diagnostic {
        return .{ .code = code, .sline = sline, .message = message, .severity = severity, .find_word = find_word };
    }

    pub fn addRelated(self: *Diagnostic, path: ?[]const u8, line: usize, message: []const u8) void {
        self.related = .{ .path = path, .line = line, .message = message };
    }

    pub fn build(self: Diagnostic, a: Allocator, file: *FortranFile) !BuiltDiag {
        var sline = self.sline;
        var schar: usize = 0;
        var echar: usize = 0;
        if (self.find_word) |w| {
            const res = try file.findWordInCodeLine(a, sline, w, true, false, false);
            sline = res.line;
            if (res.range.start >= 0) {
                schar = @intCast(res.range.start);
                echar = @intCast(res.range.end);
            }
        }
        return .{
            .sln = sline,
            .sch = schar,
            .eln = sline,
            .ech = echar,
            .message = self.message,
            .severity = self.severity,
            .related = self.related,
            .code = self.code,
            .subject = self.subject,
        };
    }
};

/// LSP-ready diagnostic with byte-based columns (range_json semantics:
/// a zero end line/char falls back to the start value)
pub const BuiltDiag = struct {
    sln: usize,
    sch: usize,
    eln: ?usize,
    ech: ?usize,
    message: []const u8,
    severity: i32,
    related: ?Diagnostic.Related = null,
    /// Columns are code point counts rather than byte offsets
    cols_are_codepoints: bool = false,
    code: C.DiagCode,
    subject: ?[]const u8 = null,
};

/// An END statement that does not match the scope that is open
pub const EndError = struct {
    /// Line of the END statement; null when it is the unnamed END of no scope at all
    end_line: ?usize,
    /// Line the diagnostic is reported at: the first line of the open scope,
    /// or the END statement itself when no scope is open
    scope_line: usize,
};
