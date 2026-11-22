//! The summary of a parsed file (#219): what requests on other files read
//! of it, without the insides of its procedures. A workspace file that is
//! not open is kept as one (server/summary.zig); most of a file's objects
//! are local variables and constructs of procedure bodies, which no other
//! file sees.
//!
//! Each procedure keeps its dummy arguments, its result, its named
//! constants (and the variables declared on the same lines as those), its
//! USE and IMPLICIT statements and the scopes declared in it (internal
//! procedures, interfaces, derived types); its other variables and its
//! constructs go,
//! but for a construct with a USE statement, an interface or a derived type
//! in it (which the module graph, the operator and BIND(C) searches and
//! the type hierarchy see). Modules, programs, derived types and
//! interfaces are kept whole. The diagnostics of parsing go too: a file's
//! own diagnostics are those of its full AST, which zfls parses again
//! before computing them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const serial = @import("serial.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;

/// The deepest nesting of scopes in `ast` (scopes count, from 1)
pub fn maxScopeDepth(ast: *const Ast) i64 {
    var max: i64 = 0;
    for (ast.scope_list.items) |s| {
        var d: i64 = 0;
        var p: ?*Obj = s;
        while (p) |o| : (p = o.parent) d += 1;
        max = @max(max, d);
    }
    return max;
}

/// Whether `ast`, just parsed, can be summarized: a file that neither
/// includes others nor is the text of an include (statements outside any
/// program unit), whose scopes are linked into the including file's
pub fn summarizable(ast: *const Ast) bool {
    return ast.summary == null and ast.include_statements.items.len == 0 and
        ast.none_scope == null and ast.inc_scope == null;
}

/// The summary of `full`, an AST just parsed (not linked), in an AST of its
/// own, and its bytes for the index cache (both owned by `gpa`); `full` is
/// left as it is but for what it drops. Null when it cannot be summarized.
pub fn summarize(gpa: Allocator, full: *Ast) Allocator.Error!?struct { ast: *Ast, bytes: []u8 } {
    if (!summarizable(full)) return null;
    const depth = maxScopeDepth(full);
    try prune(gpa, full);
    full.summary = .{ .depth = depth };
    defer full.summary = null;
    const bytes = serial.save(gpa, full) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Foreign, error.TooDeep => return null,
    };
    errdefer gpa.free(bytes);
    const ast = try Ast.create(gpa, full.file);
    errdefer ast.destroy();
    serial.load(gpa, ast, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // what was just saved is readable
        error.Format => unreachable,
    };
    return .{ .ast = ast, .bytes = bytes };
}

/// Takes out of `ast` the objects a summary leaves out, so that saving it
/// (objects/serial.zig, which saves what its lists reach) saves the rest
fn prune(gpa: Allocator, ast: *Ast) Allocator.Error!void {
    var dropped: std.AutoHashMapUnmanaged(*const Obj, void) = .empty;
    defer dropped.deinit(gpa);
    var lines: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer lines.deinit(gpa);
    for (ast.scope_list.items) |s| {
        if (!s.kind.isSubroutine()) continue;
        // the lines of the variables kept, whose other variables are kept
        // too (an interface body copies a declaration without those)
        lines.clearRetainingCapacity();
        for (s.childList()) |c| if (c.kind.isVariable() and keepsVariable(s, c)) try lines.put(gpa, c.sline, {});
        var k: usize = 0;
        while (k < s.childList().len) {
            const c = s.childList()[k];
            if (if (c.kind.isVariable()) !lines.contains(c.sline) else c.kind.isBlock() and localOnly(c)) {
                try addTree(gpa, &dropped, c);
                s.removeChild(k);
            } else k += 1;
        }
    }
    const lists = [_]*std.ArrayList(*Obj){ &ast.scope_list, &ast.variable_list, &ast.inherit_objs, &ast.linkable_objs, &ast.external_objs };
    for (lists) |list| {
        var n: usize = 0;
        for (list.items) |o| if (!dropped.contains(o)) {
            list.items[n] = o;
            n += 1;
        };
        list.shrinkRetainingCapacity(n);
    }
    // the diagnostics of parsing and its state, which only the file's own
    // diagnostics read
    ast.end_errors.clearRetainingCapacity();
    ast.scope_errors.clearRetainingCapacity();
    ast.parse_errors.clearRetainingCapacity();
    ast.main_errors.clearRetainingCapacity();
    ast.implicit_errors.clearRetainingCapacity();
    ast.public_list.clearRetainingCapacity();
    ast.private_list.clearRetainingCapacity();
    ast.scope_stack.clearRetainingCapacity();
    ast.current_scope = null;
    ast.last_obj = null;
    ast.pending_doc = null;
}

fn addTree(gpa: Allocator, set: *std.AutoHashMapUnmanaged(*const Obj, void), o: *const Obj) Allocator.Error!void {
    try set.put(gpa, o, {});
    for (o.childList()) |c| try addTree(gpa, set, c);
}

/// Whether the summary keeps `c`, a variable of procedure `proc`: a dummy
/// argument, the result, or a named constant (which an interface body
/// copies with the declarations that use it: procinterface.zig)
fn keepsVariable(proc: *const Obj, c: *const Obj) bool {
    if (c.isParameter()) return true;
    const p = proc.procDataConst();
    var it = std.mem.splitScalar(u8, p.args, ',');
    while (it.next()) |arg| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, arg, " \t"), c.name)) return true;
    // and those of its ENTRY statements
    var entry_it = std.mem.splitScalar(u8, p.entry_names, ',');
    while (entry_it.next()) |n| if (std.ascii.eqlIgnoreCase(n, c.name)) return true;
    if (proc.kind == .function) return std.ascii.eqlIgnoreCase(p.result_name orelse proc.name, c.name);
    return false;
}

/// Whether a construct holds only variables and constructs, without USE
/// statements
fn localOnly(o: *const Obj) bool {
    if (o.kind.isVariable()) return true;
    if (!o.kind.isBlock()) return false;
    if (o.data == .scope and o.scopeDataConst().use.items.len > 0) return false;
    for (o.childList()) |c| if (!localOnly(c)) return false;
    return true;
}

const FortranFile = @import("../parser.zig").FortranFile;

test "a summary keeps what other files see of a file" {
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    const src =
        \\module m
        \\  implicit none
        \\  integer, parameter :: n = 3
        \\  type :: t
        \\    real :: a
        \\  end type
        \\contains
        \\  !> doc of f
        \\  function f(x, y) result(r)
        \\    real, intent(in) :: x
        \\    real, optional :: y
        \\    real :: r
        \\    integer :: i, j
        \\    interface
        \\      subroutine cb(z)
        \\        real :: z
        \\      end subroutine
        \\    end interface
        \\    do i = 1, n
        \\      block
        \\        real :: tmp
        \\        tmp = x
        \\      end block
        \\    end do
        \\    block
        \\      use iso_fortran_env, only: real64
        \\      r = 1
        \\    end block
        \\    r = x
        \\  contains
        \\    subroutine inner(q)
        \\      integer :: q, w
        \\      if (q > 0) w = q
        \\    end subroutine
        \\  end function
        \\  integer function g()
        \\    integer :: k
        \\    g = 1
        \\  end function
        \\end module
        \\
    ;
    const f = try FortranFile.create(gpa, "/w/m.f90", null);
    defer f.destroy();
    _ = try f.setTextOwned(try gpa.dupe(u8, src));
    const full = try f.parse(std.testing.io, null, &.{}, .{});
    defer full.destroy();
    const depth = maxScopeDepth(full);
    const n_scopes = full.scope_list.items.len;
    const s = (try summarize(gpa, full)).?;
    defer s.ast.destroy();
    defer gpa.free(s.bytes);
    const sum = s.ast;
    try std.testing.expectEqual(depth, sum.summary.?.depth);
    try std.testing.expect(sum.scope_list.items.len < n_scopes);
    try std.testing.expect(!summarizable(sum));
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (sum.scope_list.items) |sc| {
        try names.print(gpa, "{s}:", .{sc.fqsn});
        for (sc.childList()) |c| try names.print(gpa, " {s}", .{c.name});
        try names.append(gpa, '\n');
    }
    // the DO construct and the BLOCK in it go, the BLOCK with a USE stays;
    // i, j, k go, w stays beside q
    try std.testing.expectEqualStrings(
        \\m: n t f g
        \\m::t: a
        \\m::f: x y r #GEN_INT1 #BLOCK2 inner
        \\m::f::#gen_int1: cb
        \\m::f::#gen_int1::cb: z
        \\m::f::#block2:
        \\m::f::inner: q w
        \\m::g: g
        \\
    , names.items);
    const fun = sum.global_dict.get("m").?.childList()[2];
    try std.testing.expectEqualStrings("doc of f", fun.doc_str.?);
    try std.testing.expect(fun.file_ast == sum);
    // no object of the summary is in the dropped ones' lists
    for (sum.variable_list.items) |v| try std.testing.expect(v.file_ast == sum and v.parent != null);
    // the bytes load as the summary again
    const back = try Ast.create(gpa, f);
    defer back.destroy();
    try serial.load(gpa, back, s.bytes);
    try std.testing.expectEqual(sum.scope_list.items.len, back.scope_list.items.len);
    try std.testing.expect(back.summary != null);
}

test "an include's text or a file that includes is not summarized" {
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    for ([_][]const u8{ "  integer :: n\n  n = 1\n", "subroutine s\n  include 'x.inc'\nend subroutine\n" }) |text| {
        const f = try FortranFile.create(gpa, "/w/i.f90", null);
        defer f.destroy();
        _ = try f.setTextOwned(try gpa.dupe(u8, text));
        const full = try f.parse(std.testing.io, null, &.{}, .{});
        defer full.destroy();
        try std.testing.expect(try summarize(gpa, full) == null);
    }
}
