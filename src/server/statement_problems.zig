//! The label (labels.zig), CASE value (cases.zig) and EXIT or CYCLE
//! (loops.zig) diagnostics of a file, for the server.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const labels = @import("../labels.zig");
const cases = @import("../cases.zig");
const loops = @import("../loops.zig");
const parser = @import("../parser.zig");
const C = @import("../constants.zig");
const diagnostics = @import("diagnostics.zig");

const Ast = objects.Ast;
const FortranFile = parser.FortranFile;

/// The labels `file` defines twice, the labels it names without defining
/// them and the CASE values that overlap; none in a fypp file
pub fn check(a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    if (diagnostics.usesFypp(file)) return out.items;
    for (try labels.check(a, file, ast)) |p| try out.append(a, .{
        .sln = p.line,
        .sch = p.start,
        .eln = p.line,
        .ech = p.end,
        .message = p.message,
        .severity = C.Severity.err,
        .code = switch (p.kind) {
            .twice => .label_defined_twice,
            .missing => .label_not_found,
        },
    });
    for (try cases.check(a, file)) |p| try out.append(a, .{
        .sln = p.line,
        .sch = p.start,
        .eln = p.line,
        .ech = p.end,
        .message = p.message,
        .severity = C.Severity.err,
        .code = .case_value_overlap,
    });
    for (try loops.check(a, file, ast)) |p| try out.append(a, .{
        .sln = p.line,
        .sch = p.start,
        .eln = p.line,
        .ech = p.end,
        .message = p.message,
        .severity = C.Severity.err,
        .code = if (p.is_exit) .exit_outside_loop else .cycle_outside_loop,
    });
    return out.items;
}
