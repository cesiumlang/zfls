//! Fortran regular expressions (port of `fortls.regex_patterns`)

const std = @import("std");
const regex = @import("regex.zig");
const Regex = regex.Regex;
const I = regex.I;

const Def = struct { []const u8, []const u8, bool };

/// (field name, pattern, ignore case)
const defs = [_]Def{
    .{ "USE", "[ ]*USE([, ]+(?:INTRINSIC|NON_INTRINSIC))?[ :]+(\\w*)([, ]+ONLY[ :]+)?", true },
    .{ "IMPORT", "[ ]*IMPORT" ++
        "(?:" ++
        "[ ]*,[ ]*(?P<spec>ALL|NONE)" ++
        "|" ++
        "[ ]*,[ ]*(?P<only>ONLY)[ ]*:[ ]*(?P<start1>[\\w_])" ++
        "|" ++
        "[ ]+(?:::[ ]*)?(?P<start2>[\\w_])" ++
        ")?", true },
    .{ "INCLUDE", "[ ]*INCLUDE[ :]*[\\'\\\"]([^\\'\\\"]*)", true },
    .{ "CONTAINS", "[ ]*(CONTAINS)[ ]*$", true },
    .{ "IMPLICIT", "[ ]*IMPLICIT[ ]+([a-z]*)", true },
    .{ "SUB_MOD", "[ ]*(?!<[,\\()][ ]*)\\b(PURE|IMPURE|ELEMENTAL|RECURSIVE)\\b(?![,\\)][ ]*)", true },
    .{ "SUB", "[ ]*SUBROUTINE[ ]+(\\w+)", true },
    .{ "END_SUB", "SUBROUTINE", true },
    .{ "FUN", "[ ]*FUNCTION[ ]+(\\w+)", true },
    .{ "RESULT", "RESULT[ ]*\\((\\w*)\\)", true },
    .{ "END_FUN", "FUNCTION", true },
    .{ "MOD", "[ ]*MODULE[ ]+(\\w+)", true },
    .{ "END_MOD", "MODULE", true },
    .{ "SUBMOD", "[ ]*SUBMODULE[ ]*\\(", true },
    .{ "END_SMOD", "SUBMODULE", true },
    .{ "END_PRO", "(MODULE)?[ ]*PROCEDURE", true },
    // the keyword is the whole statement: not the start of a longer name, nor
    // the name of a construct (#532, #292)
    .{ "BLOCK", "[ ]*([a-z_]\\w*[ ]*:[ ]*)?(?:BLOCK|CRITICAL)[ ]*(?:!.*)?$", true },
    .{ "END_BLOCK", "BLOCK|CRITICAL", true },
    // BLOCK DATA is a program unit of its own (#264, #470)
    .{ "BLOCK_DATA", "[ ]*BLOCK[ ]*DATA(?:[ ]+([a-z_]\\w*))?[ ]*(?:!.*)?$", true },
    .{ "END_BLOCK_DATA", "BLOCK[ ]*DATA", true },
    .{ "DO", "[ ]*(?:[a-z_]\\w*[ ]*:[ ]*)?DO([ ]+[0-9]*|$)", true },
    .{ "END_DO", "DO", true },
    .{ "WHERE", "[ ]*WHERE[ ]*\\(", true },
    .{ "END_WHERE", "WHERE", true },
    .{ "IF", "[ ]*(?:[a-z_]\\w*[ ]*:[ ]*)?IF[ ]*\\(", true },
    .{ "THEN", "\\)[ ]*THEN$", true },
    .{ "END_IF", "IF", true },
    .{ "ASSOCIATE", "[ ]*ASSOCIATE[ ]*\\(", true },
    .{ "END_ASSOCIATE", "ASSOCIATE", true },
    .{ "END_FIXED", "[ ]*([0-9]*)[ ]*CONTINUE", true },
    .{ "SELECT", "[ ]*(?:[a-z_]\\w*[ ]*:[ ]*)?SELECT[ ]*(CASE|TYPE)[ ]*\\(([\\w=> ]*)", true },
    .{ "SELECT_TYPE", "[ ]*(TYPE|CLASS)[ ]+IS[ ]*\\(([\\w ]*)", true },
    .{ "SELECT_DEFAULT", "[ ]*CLASS[ ]+DEFAULT", true },
    .{ "END_SELECT", "SELECT", true },
    .{ "PROG", "[ ]*PROGRAM[ ]+(\\w+)", true },
    .{ "END_PROG", "PROGRAM", true },
    .{ "INT", "[ ]*(ABSTRACT)?[ ]*INTERFACE[ ]*(\\w*)", true },
    .{ "END_INT", "INTERFACE", true },
    .{ "END_WORD", "[ ]*END[ ]*(DO|WHERE|IF|BLOCK[ ]*DATA|BLOCK|CRITICAL|ASSOCIATE|SELECT" ++
        "|TYPE|ENUM|MODULE|SUBMODULE|PROGRAM|INTERFACE" ++
        "|SUBROUTINE|FUNCTION|PROCEDURE|FORALL)?([ ]+(?!\\W)|$)", true },
    .{ "TYPE_DEF", "[ ]*(TYPE)[, :]+", true },
    .{ "EXTENDS", "EXTENDS[ ]*\\((\\w*)\\)", true },
    .{ "GENERIC_PRO", "[ ]*(GENERIC)[, ]*(PRIVATE|PUBLIC)?[ ]*::[ ]*[a-z]", true },
    .{ "GEN_ASSIGN", "(ASSIGNMENT|OPERATOR)\\(", true },
    .{ "END_TYPED", "TYPE", true },
    .{ "ENUM_DEF", "[ ]*ENUM[, ]+", true },
    .{ "END_ENUMD", "ENUM", true },
    .{ "VAR", "[ ]*(INTEGER|REAL|DOUBLE[ ]*PRECISION|COMPLEX" ++
        "|DOUBLE[ ]*COMPLEX|CHARACTER|LOGICAL|PROCEDURE" ++
        "|EXTERNAL|CLASS|TYPE)", true },
    .{ "KIND_SPEC", "[ ]*([*]?\\([ ]*[\\w*:]|\\*[ ]*[0-9:]*)", true },
    .{ "KEYWORD_LIST", "[ ]*,[ ]*(PUBLIC|PRIVATE|ALLOCATABLE|" ++
        "POINTER|TARGET|DIMENSION[ ]*\\(|" ++
        "OPTIONAL|INTENT[ ]*\\([ ]*(?:IN|OUT|IN[ ]*OUT)[ ]*\\)|DEFERRED|NOPASS|" ++
        "PASS[ ]*\\(\\w*\\)|SAVE|PARAMETER|EXTERNAL|" ++
        "CONTIGUOUS)", true },
    .{ "PARAMETER_VAL", "\\w*[\\s\\&]*=(([\\s\\&]*[\\w\\.\\-\\+\\*\\/\\'\\\"])*)", true },
    .{ "TATTR_LIST", "[ ]*,[ ]*(PUBLIC|PRIVATE|ABSTRACT|EXTENDS\\(\\w*\\))", true },
    .{ "VIS", "[ ]*\\b(PUBLIC|PRIVATE)\\b", true },
    .{ "WORD", "[a-z_][\\w\\$]*", true },
    .{ "NUMBER", "[\\+\\-]?(\\b\\d+\\.?\\d*|\\.\\d+)(_\\w+|d[\\+\\-]?\\d+|e[\\+\\-]?\\d+(_\\w+)?)?(?!\\w)", true },
    .{ "LOGICAL", ".true.|.false.", true },
    .{ "SUB_PAREN", "\\([\\w, ]*\\)", true },
    .{ "SQ_STRING", "\\'[^\\']*\\'", true },
    .{ "DQ_STRING", "\\\"[^\\\"]*\\\"", true },
    .{ "LINE_LABEL", "[ ]*([0-9]+)[ ]+", true },
    // a preprocessor `#include "file"` or `#include <file>`, and its file name
    .{ "INCLUDE_DIRECTIVE", "[ ]*#[ ]*include[ ]*[\"<]([^\">]+)[\">]", true },
    .{ "NON_DEF", "[ ]*(CALL[ ]+[a-z_]|[a-z_][\\w%]*[ ]*=)", true },
    .{ "FIXED_COMMENT", "([!cd*]|[ ]{1,4}!|[ ]{6,}!)", true },
    .{ "FIXED_CONT", "( {5}[\\S])", false },
    .{ "FIXED_DOC", "(?:[!cd\\*]|[ ]{1,4}!|[ ]{6,}!)([<>!])", true },
    .{ "FIXED_OPENMP", "[!c\\*]\\$OMP", true },
    .{ "FREE_COMMENT", "([ ]*!)", false },
    .{ "FREE_CONT", "([ ]*&)", false },
    .{ "FREE_DOC", "[ ]*!([<>!])", false },
    .{ "FREE_OPENMP", "[ ]*!\\$OMP", true },
    .{ "FREE_FORMAT_TEST", "[ ]{1,4}[a-z]", true },
    .{ "DEFINED", "defined[ ]*\\(?[ ]*([a-z_]\\w*)[ ]*\\)?", true },
    .{ "PP_REGEX", "[ ]*#[ ]*(if |ifdef|ifndef|else|elif|endif)", true },
    .{ "PP_DEF", "[ ]*#[ ]*(define|undef|undefined)[ ]*(\\w+)(\\([ ]*([ \\w,]*?)[ ]*\\))?", true },
    .{ "PP_DEF_TEST", "(![ ]*)?defined[ ]*\\([ ]*(\\w*)[ ]*\\)$", true },
    .{ "PP_INCLUDE", "[ ]*#[ ]*include[ ]*([\\\"\\w\\./\\\\]*)", true },
    .{ "PP_ANY", "^[ ]*#:?[ ]*(\\w+)", false },
    .{ "CALL", "[ ]*CALL[ ]+[\\w%]*$", true },
    .{ "INT_STMNT", "^[ ]*[a-z]*$", true },
    .{ "TYPE_STMNT", "[ ]*(TYPE|CLASS)[ ]*(IS)?[ ]*$", true },
    .{ "PROCEDURE_STMNT", "[ ]*(PROCEDURE)[ ]*$", true },
    .{ "PRO_LINK", "[ ]*(MODULE[ ]*PROCEDURE )", true },
    .{ "SCOPE_DEF", "[ ]*(MODULE|PROGRAM|SUBROUTINE|FUNCTION|INTERFACE)[ ]+", true },
    .{ "END", "[ ]*(END)(" ++
        " |MODULE|PROGRAM|SUBROUTINE|FUNCTION|PROCEDURE|TYPE|DO|IF|SELECT)?", true },
    .{ "CLASS_VAR", "(TYPE|CLASS)[ ]*\\(", true },
    .{ "DEF_KIND", "(\\w*)[ ]*\\((?:KIND|LEN)?[ =]*(\\w*)", true },
    .{ "OBJBREAK", "[\\/\\-(.,+*<>=: ]", true },
    // Patterns used inline elsewhere in fortls
    .{ "END_PROGRAM_NONE", "[ ]*END[ ]*PROGRAM", true },
    .{ "TYPE_DEF_CTX", "[ ]*(TYPE|CLASS)[ ]*\\([a-z0-9_ ]*$", true },
    .{ "IMP_DIM", "[ ]*\\w+[ ]*(\\()", true },
    .{ "IMP_CHAR", "(\\w+)[ ]*\\*[ ]*(\\d+|\\()", true },
    .{ "LEADING_COMMA", "^[, ]*", false },
    .{ "DOC_PARAM", "[@\\\\]param(?:[\\[\\(]\\s*[\\w,]+\\s*[\\]\\)])?\\s+(.*?)\\s+", false },
    .{ "SPLITLINES", "\\n|\\r\\n?", false },
    .{ "PAREN_CONTENT", "\\(.*\\)", false },
};

fn makeStruct() type {
    var names: [defs.len][]const u8 = undefined;
    var types: [defs.len]type = undefined;
    var attrs: [defs.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (defs, 0..) |d, i| {
        names[i] = d[0];
        types[i] = Regex;
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub const Patterns = makeStruct();

var storage: Patterns = undefined;
var initialized = std.atomic.Value(bool).init(false);

/// Compiled pattern table. Thread-safe after the first call to `init`.
pub fn get() *const Patterns {
    std.debug.assert(initialized.load(.acquire));
    return &storage;
}

/// Compile all patterns. Idempotent.
pub fn init() void {
    if (initialized.load(.acquire)) return;
    const a = std.heap.page_allocator;
    inline for (defs) |d| {
        @field(storage, d[0]) = Regex.compile(a, d[1], .{ .ignore_case = d[2] }) catch |e| {
            std.debug.panic("failed to compile pattern {s}: {s}", .{ d[0], @errorName(e) });
        };
    }
    initialized.store(true, .release);
}

/// Port of `create_src_file_exts_regex`: build a regex matching the default
/// Fortran file extensions plus `input_exts` (already escaped regex snippets).
pub fn createSrcFileExtsRegex(a: std.mem.Allocator, input_exts: []const []const u8) !Regex {
    const default = "\\.[fF](77|90|95|03|05|08|18|[oO][rR]|[pP]{2})?";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "((");
    try buf.appendSlice(a, default);
    for (input_exts) |ext| {
        try buf.appendSlice(a, "$)|(");
        try buf.appendSlice(a, ext);
    }
    try buf.appendSlice(a, "$))");
    return Regex.compile(a, buf.items, .{}) catch {
        return Regex.compile(a, "(" ++ default ++ "$)", .{});
    };
}

/// Port of `create_src_file_exts_str`: like `createSrcFileExtsRegex` but the
/// extensions are escaped first.
pub fn createSrcFileExtsStr(a: std.mem.Allocator, input_exts: []const []const u8) !Regex {
    var escaped: std.ArrayList([]const u8) = .empty;
    defer {
        for (escaped.items) |e| a.free(e);
        escaped.deinit(a);
    }
    for (input_exts) |ext| try escaped.append(a, try regex.escape(a, ext));
    return createSrcFileExtsRegex(a, escaped.items);
}

test "patterns compile" {
    init();
    const R = get();
    try std.testing.expect(R.USE.match("use foo, only: bar") != null);
    try std.testing.expect(R.END_WORD.match("end subroutine foo") != null);
}

test "src file exts regex" {
    const a = std.testing.allocator;
    const exts = [_][]const u8{ "\\.fypp", "\\.inc" };
    var re = try createSrcFileExtsRegex(a, &exts);
    defer re.deinit();
    try std.testing.expect(re.search("test.fypp") != null);
    try std.testing.expect(re.search("test.inc") != null);
    try std.testing.expect(re.search("test.F90") != null);
    try std.testing.expect(re.search("test.c") == null);

    const bad = [_][]const u8{"*.inc"};
    var re2 = try createSrcFileExtsRegex(a, &bad);
    defer re2.deinit();
    try std.testing.expect(re2.search("test.inc") == null);
}
