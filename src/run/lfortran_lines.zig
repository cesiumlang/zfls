//! The lines of LFortran's PRINT and WRITE statements in its IR (#470):
//! LFortran 0.69 gives them no location of their own, so their
//! instructions carry the statement's before them, and a breakpoint on
//! one never binds. Each statement is one call of its runtime
//! (`_lfortran_printf`, `_lfortran_file_write`), the k-th of a procedure's
//! the k-th of its source; those calls, with the instructions that set
//! them up and the ones after them of the same location, get the
//! statement's line. A procedure whose calls and statements differ in
//! number is left as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir_text = @import("ir_text.zig");
const dbgOf = ir_text.dbgOf;
const metadataId = ir_text.metadataId;
const field = ir_text.field;
const number = ir_text.number;
const splitLines = ir_text.splitLines;
const word = ir_text.word;
const fixed_indent = @import("../fixed_indent.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const patterns = @import("../patterns.zig");

/// A statement's place, 1-based
pub const Stmt = struct { line: usize, col: usize };

/// A procedure or main program of the source, with its own output
/// statements (not those of the procedures it contains)
pub const Proc = struct { name: []const u8, sline: usize, program: bool, stmts: []const Stmt };

/// The PRINT and WRITE statements of a source's lines, also those of a
/// one-line IF
pub fn outputStatements(a: Allocator, lines: []const []const u8, fixed: bool) ![]const Stmt {
    var out: std.ArrayList(Stmt) = .empty;
    var quote: u8 = 0;
    var continues = false;
    for (lines, 0..) |raw, i| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var code = line;
        var offset: usize = 0;
        var first = !continues;
        if (fixed) {
            switch (fixed_indent.kindOf(line)) {
                .other => continue,
                .continuation => first = false,
                .statement => first = true,
            }
            code = fixed_indent.codeOf(line, 72);
            offset = 6;
        } else if (std.mem.trimStart(u8, line, " \t").len > 0 and std.mem.trimStart(u8, line, " \t")[0] == '#') continue;
        if (first) quote = 0;
        const scan = try statements(a, code, quote, first);
        for (scan.starts) |s| if (isOutput(code[s..])) try out.append(a, .{ .line = i + 1, .col = offset + s + 1 });
        quote = scan.quote;
        continues = !fixed and scan.amp;
        if (!fixed and !scan.amp) quote = 0;
    }
    return out.items;
}

const Scan = struct { starts: []const usize, quote: u8, amp: bool };

/// Where the statements of a line's code start (after `;`, and at its
/// beginning when `first`), the quote it ends in, and whether it ends in `&`
fn statements(a: Allocator, code: []const u8, start_quote: u8, first: bool) !Scan {
    var starts: std.ArrayList(usize) = .empty;
    var quote = start_quote;
    var want = first and quote == 0;
    var last: u8 = 0;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            last = c;
            continue;
        }
        if (c == ' ' or c == '\t') continue;
        if (c == '!') break;
        if (want and c != ';') {
            try starts.append(a, i);
            want = false;
        }
        switch (c) {
            '\'', '"' => quote = c,
            ';' => want = true,
            else => {},
        }
        last = c;
    }
    return .{ .starts = starts.items, .quote = quote, .amp = last == '&' };
}

/// Whether a statement (from its first character) is PRINT or WRITE, or
/// a one-line IF of one
fn isOutput(s_in: []const u8) bool {
    var s = s_in;
    // a label
    const digits = std.mem.findNone(u8, s, "0123456789") orelse return false;
    if (digits > 0) s = std.mem.trimStart(u8, s[digits..], " \t");
    const w = word(s);
    const rest = std.mem.trimStart(u8, s[w.len..], " \t");
    const next: u8 = if (rest.len > 0) rest[0] else 0;
    if (std.ascii.eqlIgnoreCase(w, "print")) return next != '=' and next != '%' and next != '(';
    if (std.ascii.eqlIgnoreCase(w, "write") or std.ascii.eqlIgnoreCase(w, "if")) {
        if (next != '(') return false;
        const close = closeParen(rest) orelse return false;
        const after = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(w, "write")) return after.len == 0 or (after[0] != '=' and after[0] != '%');
        return !std.ascii.eqlIgnoreCase(word(after), "then") and isOutput(after);
    }
    return false;
}

/// The `)` that closes the `(` at `s[0]`, outside character literals
fn closeParen(s: []const u8) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    for (s, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The source file at `path` (its `text`), parsed
pub fn parse(a: Allocator, io: std.Io, path: []const u8, text: []const u8) !struct { file: *parser.FortranFile, ast: *objects.Ast } {
    patterns.init();
    const file = try parser.FortranFile.create(a, path, null);
    _ = try file.setText(text);
    return .{ .file = file, .ast = try file.parse(io, null, &.{}, .{}) };
}

/// The procedures of the source file at `path` (its `text`), with their
/// output statements
pub fn ofSource(a: Allocator, io: std.Io, path: []const u8, text: []const u8) ![]const Proc {
    const p = try parse(a, io, path, text);
    return ofParsed(a, p.file, p.ast);
}

pub fn ofParsed(a: Allocator, file: *const parser.FortranFile, ast: *const objects.Ast) ![]const Proc {
    return procedures(a, ast, try outputStatements(a, file.editLines(), file.fixed));
}

/// The procedures and main programs of `ast`, each with the statements
/// of `stmts` in it and in none it contains
pub fn procedures(a: Allocator, ast: *const objects.Ast, stmts: []const Stmt) ![]const Proc {
    var units: std.ArrayList(*objects.Obj) = .empty;
    for (ast.scope_list.items) |sc| switch (sc.kind) {
        .program, .subroutine, .function => if (sc.sline > 0 and sc.eline >= sc.sline) try units.append(a, sc),
        else => {},
    };
    var out: std.ArrayList(Proc) = .empty;
    for (units.items) |u| {
        var own: std.ArrayList(Stmt) = .empty;
        for (stmts) |st| {
            if (st.line < u.sline or st.line > u.eline) continue;
            // the innermost unit holding it
            const inner = for (units.items) |v| {
                if (v != u and v.sline >= u.sline and v.eline <= u.eline and st.line >= v.sline and st.line <= v.eline) break true;
            } else false;
            if (!inner) try own.append(a, st);
        }
        try out.append(a, .{ .name = u.name, .sline = u.sline, .program = u.kind == .program, .stmts = own.items });
    }
    return out.items;
}

const anchors = [_][]const u8{ "_lfortran_printf", "_lfortran_file_write" };
const setups = [_][]const u8{ "_lcompilers_string_format_fortran", "_lfortran_get_decimal_mode", "_lfortran_get_sign_mode", "_lfortran_get_round_mode" };

pub const Subprogram = struct { name: []const u8, line: usize };

/// `ir` with the lines of the output statements of `procs`; as it was
/// where it is not LFortran's as zfls knows it
pub fn patch(a: Allocator, ir: []const u8, procs: []const Proc) ![]const u8 {
    const lines = try splitLines(a, ir);
    var subprograms: std.AutoHashMapUnmanaged(u64, Subprogram) = .empty;
    var locations: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    var max_id: u64 = 0;
    for (lines) |l| {
        const id = metadataId(l) orelse continue;
        max_id = @max(max_id, id);
        if (std.mem.find(u8, l, "= distinct !DISubprogram(") != null) {
            try subprograms.put(a, id, .{ .name = field(l, "name: \"", '"') orelse "", .line = number(field(l, "line: ", ',')) orelse 0 });
        } else if (std.mem.find(u8, l, "= !DILocation(") != null) {
            try locations.put(a, id, number(field(l, "line: ", ',')) orelse 0);
        }
    }
    const assigned = try a.alloc(?u64, lines.len);
    @memset(assigned, null);
    var added: std.ArrayList(u8) = .empty;
    var next_id = max_id + 1;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        if (!std.mem.startsWith(u8, lines[i], "define ")) continue;
        const start = i;
        while (i < lines.len and !std.mem.eql(u8, lines[i], "}")) i += 1;
        const sp_id = dbgOf(lines[start]) orelse continue;
        const sp = subprograms.get(sp_id) orelse continue;
        const proc = matching(procs, sp) orelse continue;
        var calls: std.ArrayList(usize) = .empty;
        for (start + 1..i) |j| if (callee(lines[j])) |c| if (isOne(&anchors, c)) try calls.append(a, j);
        if (calls.items.len != proc.stmts.len or calls.items.len == 0) continue;
        // each statement's location after the one it carries
        const fits = for (calls.items, proc.stmts) |j, st| {
            const carried = locations.get(dbgOf(lines[j]) orelse break false) orelse break false;
            if (carried > st.line) break false;
        } else true;
        if (!fits) continue;
        for (calls.items, proc.stmts) |j, st| {
            const orig = dbgOf(lines[j]).?;
            const id = next_id;
            next_id += 1;
            try added.print(a, "!{d} = !DILocation(line: {d}, column: {d}, scope: !{d})\n", .{ id, st.line, st.col, sp_id });
            var k = groupStart(lines, start, j);
            while (k <= j) : (k += 1) if (dbgOf(lines[k]) != null) {
                assigned[k] = id;
            };
            // after the call: its location's instructions, to the next
            k = j + 1;
            while (k < i) : (k += 1) {
                if (!isInstruction(lines[k])) continue;
                const d = dbgOf(lines[k]) orelse continue;
                if (d != orig) break;
                assigned[k] = id;
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (lines, assigned) |l, n| {
        if (n) |id| {
            const at = std.mem.findLast(u8, l, ", !dbg !").? + ", !dbg !".len;
            var e = at;
            while (e < l.len and std.ascii.isDigit(l[e])) e += 1;
            try out.print(a, "{s}{d}{s}\n", .{ l[0..at], id, l[e..] });
        } else {
            try out.appendSlice(a, l);
            try out.append(a, '\n');
        }
    }
    try out.appendSlice(a, added.items);
    return out.items;
}

/// The first instruction of the statement of the call at `j`: the
/// earliest of the calls that set it up, before the call before it, and
/// the values they take
fn groupStart(lines: []const []const u8, fn_start: usize, j: usize) usize {
    var s = j;
    var k = j;
    while (k > fn_start + 1) {
        k -= 1;
        const l = lines[k];
        if (!isInstruction(l)) {
            if (isRecord(l)) continue;
            break;
        }
        const c = callee(l) orelse continue;
        if (isOne(&anchors, c)) break;
        if (isOne(&setups, c)) {
            s = k;
        } else if (!std.mem.startsWith(u8, c, "_l")) break;
    }
    k = s;
    while (k > fn_start + 1) {
        k -= 1;
        const l = lines[k];
        if (isRecord(l)) continue;
        if (!isInstruction(l) or !isValue(l)) break;
        s = k;
    }
    return s;
}

/// A value computed without effects: `%x = load ...`, not a call
fn isValue(l: []const u8) bool {
    const t = std.mem.trimStart(u8, l, " ");
    if (t.len == 0 or t[0] != '%') return false;
    const eq = std.mem.find(u8, t, " = ") orelse return false;
    const op = word(t[eq + 3 ..]);
    return !std.mem.eql(u8, op, "call") and !std.mem.eql(u8, op, "alloca") and !std.mem.eql(u8, op, "invoke");
}

fn isInstruction(l: []const u8) bool {
    return l.len > 2 and l[0] == ' ' and !isRecord(l) and std.mem.trimStart(u8, l, " ").len > 0 and std.mem.trimStart(u8, l, " ")[0] != ';';
}

/// `#dbg_declare(...)` and the like
fn isRecord(l: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, l, " "), "#dbg_");
}

pub fn matching(procs: []const Proc, sp: Subprogram) ?Proc {
    for (procs) |p| {
        if (p.sline != sp.line) continue;
        if (std.ascii.eqlIgnoreCase(p.name, sp.name) or (p.program and std.mem.eql(u8, sp.name, "main"))) return p;
        // a copy LFortran made for its arguments' types: `work_real____0_...`
        if (sp.name.len > p.name.len and sp.name[p.name.len] == '_' and std.ascii.eqlIgnoreCase(sp.name[0..p.name.len], p.name)) return p;
    }
    return null;
}

fn isOne(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The function an instruction calls: `call void @f(...)`
fn callee(l: []const u8) ?[]const u8 {
    if (!isInstruction(l)) return null;
    const c = std.mem.find(u8, l, "call ") orelse return null;
    const at = std.mem.findScalarPos(u8, l, c, '@') orelse return null;
    const open = std.mem.findScalarPos(u8, l, at, '(') orelse return null;
    return l[at + 1 .. open];
}

const testing = std.testing;

test "the output statements of a source: PRINT, WRITE, a one-line IF's, not names (#470)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const free = [_][]const u8{ "print *, 'a; b'", "  x = 1; print '(a)', &", "    'c'", "  if (x > 0) write (*, *) x", "  if (x > 0) then", "  write = 1", "  write(2) = 3", "  10 print *, 1", "  ! print *, 2", "  print = 4" };
    const got = try outputStatements(a, &free, false);
    try testing.expectEqualSlices(Stmt, &.{ .{ .line = 1, .col = 1 }, .{ .line = 2, .col = 10 }, .{ .line = 4, .col = 3 }, .{ .line = 8, .col = 3 } }, got);
    const fixed = [_][]const u8{ "      print *, 'a'", "c     print *, 'b'", "     &print *, 'c'", "      write (6, *) 1" };
    try testing.expectEqualSlices(Stmt, &.{ .{ .line = 1, .col = 7 }, .{ .line = 4, .col = 7 } }, try outputStatements(a, &fixed, true));
}

test "LFortran's PRINT and WRITE get their lines, a procedure's in order (#470)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "program p\n  integer :: n\n  n = 2\n  print *, 'a'\n  print *, n\n  call show(n)\ncontains\n  subroutine show(k)\n    integer :: k\n    write (*, *) k\n  end subroutine\nend program\n";
    // as LFortran 0.69.0 writes them (`-g --show-llvm`), shortened
    const ir =
        \\define i32 @main(i32 %0, ptr %1) !dbg !2 {
        \\.entry:
        \\  store i32 2, ptr %n, align 4, !dbg !5
        \\  %2 = load ptr, ptr @s, align 8, !dbg !5
        \\  call void @_lfortran_printf(ptr @3, ptr %2, i32 1), !dbg !5
        \\  %3 = call ptr (ptr, ...) @_lcompilers_string_format_fortran(ptr null, ptr %n), !dbg !5
        \\  store ptr %3, ptr %d, align 8, !dbg !5
        \\  call void @_lfortran_printf(ptr @3, ptr %3, i32 1), !dbg !5
        \\  br label %free_done, !dbg !5
        \\
        \\free_done:
        \\  call void @p.show(ptr %n), !dbg !6
        \\  ret i32 0, !dbg !7
        \\}
        \\
        \\define internal void @p.show(ptr %k) !dbg !8 {
        \\.entry:
        \\  %0 = call i32 @_lfortran_get_decimal_mode(i32 6), !dbg !9
        \\  call void (i32, ...) @_lfortran_file_write(i32 6, ptr %0), !dbg !9
        \\  ret void, !dbg !9
        \\}
        \\
        \\!0 = distinct !DICompileUnit(language: DW_LANG_C, file: !1)
        \\!1 = !DIFile(filename: "p.f90", directory: ".")
        \\!2 = distinct !DISubprogram(name: "p", scope: !1, file: !1, line: 1, unit: !0)
        \\!5 = !DILocation(line: 3, column: 3, scope: !2)
        \\!6 = !DILocation(line: 6, column: 3, scope: !2)
        \\!7 = !DILocation(line: 1, column: 1, scope: !2)
        \\!8 = distinct !DISubprogram(name: "show", scope: !1, file: !1, line: 8, unit: !0)
        \\!9 = !DILocation(line: 8, column: 3, scope: !8)
        \\
    ;
    const out = try patch(a, ir, try ofSource(a, testing.io, "/w/p.f90", source));
    for ([_][]const u8{
        "  store i32 2, ptr %n, align 4, !dbg !5\n  %2 = load ptr, ptr @s, align 8, !dbg !10\n  call void @_lfortran_printf(ptr @3, ptr %2, i32 1), !dbg !10\n",
        "@_lcompilers_string_format_fortran(ptr null, ptr %n), !dbg !11\n  store ptr %3, ptr %d, align 8, !dbg !11\n  call void @_lfortran_printf(ptr @3, ptr %3, i32 1), !dbg !11\n  br label %free_done, !dbg !11\n",
        "  call void @p.show(ptr %n), !dbg !6\n",
        "@_lfortran_get_decimal_mode(i32 6), !dbg !12\n",
        "!10 = !DILocation(line: 4, column: 3, scope: !2)\n!11 = !DILocation(line: 5, column: 3, scope: !2)\n!12 = !DILocation(line: 10, column: 5, scope: !8)\n",
    }) |want| try testing.expect(std.mem.find(u8, out, want) != null);
    // a procedure whose calls and statements differ: as it was
    const fewer = try patch(a, ir, try ofSource(a, testing.io, "/w/p.f90", "program p\n  integer :: n\n  n = 2\n  print *, 'a'\n  call show(n)\ncontains\n  subroutine show(k)\n    integer :: k\n  end subroutine\nend program\n"));
    try testing.expect(std.mem.find(u8, fewer, "!dbg !10") == null);
}
