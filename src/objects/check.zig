//! Checks of the objects that give diagnostics, and the code action that
//! implements deferred procedures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const patterns = @import("../patterns.zig");
const C = @import("../constants.zig");
const KW = C.KW;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Env = objects.Env;
const Variable = objects.Variable;
const optEql = objects.optEql;
const Diagnostic = objects.Diagnostic;
const findInScope = objects.findInScope;
const findInWorkspace = objects.findInWorkspace;

pub fn getDiagnostics(self: *const Obj, a: Allocator) ![]Diagnostic {
    var errors: std.ArrayList(Diagnostic) = .empty;
    switch (self.kind) {
        .type => {
            for (self.scopeDataConst().in_children.items) |in_child| {
                if (!self.typeDataConst().abstract and in_child.hasKeyword(KW.deferred)) {
                    var d = Diagnostic.init(.deferred_not_implemented, self.eline -| 1, try std.fmt.allocPrint(a, "Deferred procedure \"{s}\" not implemented", .{in_child.name}), 1, null);
                    d.addRelated(in_child.file_ast.path, in_child.sline -| 1, "Inherited procedure declaration");
                    try errors.append(a, d);
                }
            }
        },
        .subroutine, .function => {
            for (self.procDataConst().missing_args.items) |m| {
                try errors.append(a, Diagnostic.init(
                    .intent_not_in_arguments,
                    m.sline -| 1,
                    try std.fmt.allocPrint(a, "Variable \"{s}\" with INTENT keyword not found in argument list", .{m.name}),
                    1,
                    m.name,
                ));
            }
            const implicit_flag = self.getImplicit();
            if (implicit_flag == null or implicit_flag.?) return errors.items;
            const arg_list = try str.split(a, try std.mem.replaceOwned(u8, a, self.argList(), " ", ""), ",");
            for (self.procDataConst().arg_objs.items, 0..) |arg_obj, i| {
                if (arg_obj == null) {
                    const arg_name = str.strip(if (i < arg_list.len) arg_list[i] else "");
                    try errors.append(a, Diagnostic.init(
                        .argument_not_declared,
                        self.sline -| 1,
                        try std.fmt.allocPrint(a, "No matching declaration found for argument \"{s}\"", .{arg_name}),
                        1,
                        arg_name,
                    ));
                }
            }
        },
        else => {},
    }
    return errors.items;
}

pub fn checkDefinition(self: *Obj, env: Env, known_types: *Obj.KnownTypes, interface: bool) !?Diagnostic {
    if (self.kind != .variable) return null;
    const a = env.tmp;
    const m = R().DEF_KIND.match(try self.getDescNoLink(a)) orelse return null;
    const var_type = try std.ascii.allocLowerString(a, str.strip(m.group(1).?));
    if (std.mem.eql(u8, var_type, "procedure")) return null;
    const desc_obj_name = try std.ascii.allocLowerString(a, str.strip(m.group(2).?));
    if (!known_types.contains(desc_obj_name)) {
        const type_def = try findInScope(env, self.parent, desc_obj_name, .{ .interface = interface });
        if (type_def) |td| {
            try known_types.put(a, desc_obj_name, .{ .kind = 0, .obj = td });
        } else {
            const type_defs = try findInWorkspace(env, desc_obj_name, true, true);
            try known_types.put(a, desc_obj_name, null);
            const filter_id = if (std.mem.eql(u8, var_type, "class") or std.mem.eql(u8, var_type, "type")) C.TypeId.class else C.TypeId.variable;
            for (type_defs) |td| {
                if (td.getType(false) == filter_id) {
                    try known_types.put(a, desc_obj_name, .{ .kind = 1, .obj = td });
                    break;
                }
            }
        }
    }
    const info = known_types.get(desc_obj_name).?;
    if (info) |ti| if (ti.kind == 1) {
        if (interface) {
            return Diagnostic.init(.not_imported, self.sline -| 1, try std.fmt.allocPrint(a, "Object \"{s}\" not imported in interface", .{desc_obj_name}), 1, desc_obj_name);
        }
        var d = Diagnostic.init(.object_not_found, self.sline -| 1, try std.fmt.allocPrint(a, "Object \"{s}\" not found in scope", .{desc_obj_name}), 1, desc_obj_name);
        d.subject = desc_obj_name;
        d.addRelated(ti.obj.file_ast.path, ti.obj.sline -| 1, "Possible object");
        return d;
    };
    return null;
}

pub fn checkDefinitions(self: *Obj, env: Env) ![]Diagnostic {
    const a = env.tmp;
    var fqsn_dict = std.array_hash_map.String(usize).empty;
    var errors: std.ArrayList(Diagnostic) = .empty;
    var known_types = Obj.KnownTypes.empty;

    for (self.childList()) |child| {
        if (child.getType(false) == C.TypeId.interface) continue;
        if (fqsn_dict.get(child.fqsn)) |v| {
            if (child.sline < v) try fqsn_dict.put(a, child.fqsn, child.sline -| 1);
        } else {
            try fqsn_dict.put(a, child.fqsn, child.sline -| 1);
        }
    }

    var contains_line: ?usize = null;
    const st = self.getType(false);
    if (st == C.TypeId.module or st == C.TypeId.submodule or st == C.TypeId.subroutine or st == C.TypeId.function) {
        contains_line = self.scopeData().contains_start orelse self.eline;
    }
    const is_interface = self.parent != null and self.parent.?.getType(false) == C.TypeId.interface and !self.isModScope();

    for (self.childList()) |child| {
        if (std.mem.startsWith(u8, child.name, "#")) continue;
        const line_number = child.sline -| 1;
        if (try child.checkDefinition(env, &known_types, is_interface)) |d| try errors.append(a, d);
        const ct = child.getType(true);
        if (contains_line != null and contains_line.? >= child.sline and (ct == C.TypeId.subroutine or ct == C.TypeId.function)) {
            try errors.append(a, Diagnostic.init(.procedure_before_contains, line_number, "Subroutine/Function definition before CONTAINS statement", 1, null));
        }
        if (st == C.TypeId.interface or child.getType(false) == C.TypeId.interface) continue;
        if (fqsn_dict.get(child.fqsn)) |first| if (line_number > first) {
            var d = Diagnostic.init(.declared_twice, line_number, try std.fmt.allocPrint(a, "Variable \"{s}\" declared twice in scope", .{child.name}), 1, child.name);
            d.addRelated(self.file_ast.path, first, "First declaration");
            try errors.append(a, d);
            continue;
        };
        // an interface body has no host association, so nothing in it masks
        // a variable of the scope around the interface (hansec #200)
        if (self.parent != null and !is_interface and (st == C.TypeId.subroutine or st == C.TypeId.function or st == C.TypeId.block)) {
            if (try findInScope(env, self.parent, child.name, .{})) |parent_var| {
                if (st == C.TypeId.function and std.mem.eql(u8, parent_var.fqsn, self.fqsn)) continue;
                var d = Diagnostic.init(.masks_parent, line_number, try std.fmt.allocPrint(a, "Variable \"{s}\" masks variable in parent scope", .{child.name}), 2, child.name);
                d.addRelated(parent_var.file_ast.path, parent_var.sline -| 1, "First declaration");
                try errors.append(a, d);
            }
        }
    }
    return errors.items;
}

pub fn checkUse(self: *const Obj, env: Env) ![]Diagnostic {
    const a = env.tmp;
    var errors: std.ArrayList(Diagnostic) = .empty;
    // lines are 1-based, so 0 is before every USE statement
    var last_use_line: usize = 0;
    for (self.scopeDataConst().use.items) |u| {
        last_use_line = @max(last_use_line, u.line_number);
        if (u.is_import) {
            if (self.parent == null or self.parent.?.getType(false) != C.TypeId.interface) {
                try errors.append(a, Diagnostic.init(.import_outside_interface, u.line_number -| 1, "IMPORT statement outside of interface", 1, null));
            }
            continue;
        }
        if (!env.tree.contains(u.mod_name)) {
            var d = Diagnostic.init(
                .module_not_found,
                u.line_number -| 1,
                try std.fmt.allocPrint(a, "Module \"{s}\" not found in project", .{u.mod_name}),
                3,
                u.mod_name,
            );
            d.subject = u.mod_name;
            try errors.append(a, d);
        }
    }
    if (self.scopeDataConst().implicit_line) |il| if (last_use_line >= il) {
        try errors.append(a, Diagnostic.init(.use_after_implicit, il -| 1, "USE statements after IMPLICIT statement", 1, "IMPLICIT"));
    };
    return errors.items;
}

pub fn addSubroutine(self: *const Obj, a: Allocator, interface_string: []const u8, no_contains: bool) !struct { path: ?[]const u8, edits: []Obj.Edit } {
    var edits: std.ArrayList(Obj.Edit) = .empty;
    const line_number = self.eline -| 1;
    if (self.scopeDataConst().contains_start == null and !no_contains) {
        var first_sub_line = line_number;
        for (self.childList()) |child| {
            const ct = child.getType(false);
            if (ct == C.TypeId.subroutine or ct == C.TypeId.function) first_sub_line = @min(first_sub_line, child.sline -| 1);
        }
        try edits.append(a, .{ .sline = first_sub_line, .schar = 0, .eline = first_sub_line, .echar = 0, .new_text = "CONTAINS\n" });
    }
    try edits.append(a, .{ .sline = line_number, .schar = 0, .eline = line_number, .echar = 0, .new_text = try std.mem.concat(a, u8, &.{ interface_string, "\n" }) });
    return .{ .path = self.file_ast.path, .edits = edits.items };
}

pub fn getActions(self: *const Obj, a: Allocator, sline: usize, eline: usize) !?[]Obj.Action {
    if (self.kind != .type) return null;
    var actions: std.ArrayList(Obj.Action) = .empty;
    var edits: std.ArrayList(Obj.Edit) = .empty;
    const line_number = self.eline -| 1;
    if (line_number < sline or line_number > eline) return actions.items;
    if (self.scopeDataConst().contains_start == null) {
        try edits.append(a, .{ .sline = line_number, .schar = 0, .eline = line_number, .echar = 0, .new_text = "CONTAINS\n" });
    }
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var has_edits = false;
    for (self.scopeDataConst().in_children.items) |in_child| {
        if (!in_child.hasKeyword(KW.deferred)) continue;
        const in_parent_name = if (in_child.parent) |p| p.name else "None";
        const iface = (try in_child.getInterface(a, in_child.name, null, .{
            try std.fmt.allocPrint(a, "class({s})", .{in_parent_name}),
            try std.fmt.allocPrint(a, "CLASS({s})", .{self.name}),
        })) orelse continue;
        const parent = self.parent orelse continue;
        const res = try parent.addSubroutine(a, iface, has_edits);
        if (!optEql(res.path, self.file_ast.path)) continue;
        try edits.append(a, .{
            .sline = line_number,
            .schar = 0,
            .eline = line_number,
            .echar = 0,
            .new_text = try std.fmt.allocPrint(a, "  PROCEDURE :: {s} => {s}\n", .{ in_child.name, in_child.name }),
        });
        try edits.appendSlice(a, res.edits);
        var d = Diagnostic.init(.deferred_not_implemented, line_number, try std.fmt.allocPrint(a, "Deferred procedure \"{s}\" not implemented", .{in_child.name}), 1, null);
        d.addRelated(in_child.file_ast.path, in_child.sline -| 1, "Inherited procedure declaration");
        try diagnostics.append(a, d);
        has_edits = true;
    }
    if (has_edits) {
        try actions.append(a, .{
            .title = "Implement deferred procedures",
            .kind = "quickfix",
            .uri_path = self.file_ast.path orelse "",
            .edits = edits.items,
            .diagnostics = diagnostics.items,
        });
    }
    return actions.items;
}
