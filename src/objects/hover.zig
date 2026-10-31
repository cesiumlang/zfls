//! What hover, completion and signature help show of an object: its snippet,
//! hover text, documentation, signature and interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const C = @import("../constants.zig");
const KW = C.KW;

const objects = @import("../objects.zig");
const Obj = objects.Obj;

pub fn getSnippet(self: *const Obj, a: Allocator, name_replace: ?[]const u8, drop_arg: ?usize) Allocator.Error!Obj.Snippet {
    switch (self.kind) {
        .variable => {
            const name = name_replace orelse self.name;
            if (self.linkObj()) |l| return l.getSnippet(a, name, drop_arg);
            return .{};
        },
        .method => {
            if (self.linkObj()) |l| {
                const name = name_replace orelse self.name;
                return l.getSnippet(a, name, self.varDataConst().drop_arg);
            }
            return .{};
        },
        .subroutine, .function => {
            var arg_list: std.ArrayList([]const u8) = .empty;
            try arg_list.appendSlice(a, try str.split(a, self.procDataConst().args_snip, ","));
            if (drop_arg) |d| if (d < arg_list.items.len) {
                _ = arg_list.orderedRemove(d);
            };
            var arg_str: []const u8 = "()";
            var arg_snip: ?[]const u8 = null;
            if (arg_list.items.len > 0) {
                const ph = try helpers.getPlaceholders(a, arg_list.items);
                arg_str = ph[0];
                arg_snip = ph[1];
            }
            const name = name_replace orelse self.name;
            return .{
                .call = try std.mem.concat(a, u8, &.{ name, arg_str }),
                .snippet = if (arg_snip) |s| try std.mem.concat(a, u8, &.{ name, s }) else null,
            };
        },
        .intrinsic => {
            var arg_str: []const u8 = undefined;
            var arg_snip: ?[]const u8 = null;
            if (self.argList().len == 0) {
                if (self.intrinsicData().itype == C.keyword_itype or self.intrinsicData().itype == C.statement_itype) return .{};
                arg_str = "()";
            } else {
                const ph = try helpers.getPlaceholders(a, try str.split(a, self.argList(), ","));
                arg_str = ph[0];
                arg_snip = ph[1];
            }
            const name = name_replace orelse self.name;
            return .{
                .call = try std.mem.concat(a, u8, &.{ name, arg_str }),
                .snippet = if (arg_snip) |s| try std.mem.concat(a, u8, &.{ name, s }) else null,
            };
        },
        else => return .{},
    }
}

pub fn getHover(self: *const Obj, a: Allocator, long: bool, drop_arg: ?usize) Allocator.Error!Obj.Hover {
    switch (self.kind) {
        .module, .program, .submodule => return .{
            .msg = try std.mem.concat(a, u8, &.{ try self.getDesc(a), " ", self.name }),
            .docs = self.getDocumentation(),
        },
        .type => {
            var kws: std.ArrayList([]const u8) = .empty;
            try kws.append(a, "TYPE");
            if (self.typeDataConst().abstract) try kws.append(a, "ABSTRACT");
            if (self.scopeDataConst().inherit) |inh| if (inh.len > 0) try kws.append(a, try std.fmt.allocPrint(a, "EXTENDS({s})", .{inh}));
            const decl = try std.mem.join(a, ", ", kws.items);
            return .{ .msg = try std.fmt.allocPrint(a, "{s} :: {s}", .{ decl, self.name }), .docs = self.getDocumentation() };
        },
        .subroutine => {
            const sig = try self.getSnippet(a, null, drop_arg);
            var kw: std.ArrayList([]const u8) = .empty;
            try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
            try kw.append(a, "SUBROUTINE ");
            var hover_array: std.ArrayList([]const u8) = .empty;
            try hover_array.append(a, try std.mem.concat(a, u8, &.{ try std.mem.join(a, " ", kw.items), sig.call.? }));
            var docs: std.ArrayList([]const u8) = .empty;
            try self.getDocsFull(a, &hover_array, &docs, long, drop_arg);
            return .{
                .msg = try std.mem.join(a, "\n ", hover_array.items),
                .docs = try std.mem.join(a, "   \n", docs.items),
            };
        },
        .function => {
            const proc = self.procDataConst();
            var fun_sig = (try self.getSnippet(a, null, drop_arg)).call.?;
            if (long) fun_sig = try std.fmt.allocPrint(a, "{s} RESULT({s})", .{ fun_sig, proc.result_name orelse self.name });
            var kw: std.ArrayList([]const u8) = .empty;
            try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
            try kw.append(a, "FUNCTION");
            var hover_array: std.ArrayList([]const u8) = .empty;
            try hover_array.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ try std.mem.join(a, " ", kw.items), fun_sig }));
            var docs: std.ArrayList([]const u8) = .empty;
            try self.getDocsFull(a, &hover_array, &docs, long, drop_arg);
            if (proc.result_obj != null and long) {
                const ro = proc.result_obj.?;
                const h = try ro.getHover(a, false, null);
                if (h.docs) |d| {
                    try docs.append(a, try std.fmt.allocPrint(a, "\n**Return:**  \n`{s}`{s}", .{ ro.name, d }));
                }
                try hover_array.append(a, h.msg orelse "None");
            } else if (proc.result_type != null and proc.result_type.?.len > 0 and long) {
                hover_array.items[0] = try std.fmt.allocPrint(a, "{s} {s}", .{ proc.result_type.?, hover_array.items[0] });
            }
            return .{
                .msg = try std.mem.join(a, "\n ", hover_array.items),
                .docs = try std.mem.join(a, "  \n", docs.items),
            };
        },
        .variable => {
            const doc_str = self.getDocumentation();
            var parts: std.ArrayList([]const u8) = .empty;
            try parts.append(a, try self.getDesc(a));
            try parts.appendSlice(a, try self.getKeywordStrings(a));
            var hover = try std.mem.join(a, ", ", parts.items);
            if (!std.mem.startsWith(u8, hover, "#")) hover = try std.fmt.allocPrint(a, "{s} :: {s}", .{ hover, self.name });
            if (self.isParameter()) if (self.varDataConst().param_val) |pv| {
                hover = try std.fmt.allocPrint(a, "{s} = {s}", .{ hover, pv });
            };
            return .{ .msg = hover, .docs = doc_str };
        },
        .method => {
            var docs = self.getDocumentation();
            var hover_str: []const u8 = undefined;
            if (self.linkObj()) |l| {
                const lh = try l.getHover(a, true, self.varDataConst().drop_arg);
                const link_msg = lh.msg orelse "None";
                hover_str = try str.replaceFirst(a, link_msg, l.name, self.name);
                if (lh.docs) |link_docs| {
                    if (l.getDocumentation()) |top| {
                        docs = try str.replaceFirst(a, link_docs, top, docs orelse "None");
                    } else if (link_docs.len > 0) {
                        docs = try std.mem.concat(a, u8, &.{ docs orelse "", "  \n", link_docs });
                    }
                }
            } else {
                const sig = try self.getSnippet(a, null, null);
                hover_str = try std.fmt.allocPrint(a, "{s} {s}", .{ try self.getDesc(a), sig.call orelse "None" });
            }
            return .{ .msg = hover_str, .docs = docs };
        },
        .intrinsic => return .{ .msg = null, .docs = self.doc_str },
        else => return .{},
    }
}

pub fn getHoverMd(self: *const Obj, a: Allocator, long: bool, drop_arg: ?usize) ![]const u8 {
    const h = try self.getHover(a, long, drop_arg);
    return helpers.fortranMd(a, h.msg, h.docs);
}

pub fn getKeywordStrings(self: *const Obj, a: Allocator) ![][]const u8 {
    if (self.linkObj()) |l| {
        if (self.varDataConst().slice_rank >= 0 and l.kind == .variable) {
            // a name bound to a section has the rank of the section, not
            // of the array it is cut from (upstream #108)
            var ids: std.ArrayList(C.Kw) = .empty;
            for (l.keywords.items) |id| if (id != KW.dimension) try ids.append(a, id);
            var info = l.keyword_info;
            info.dimension = null;
            if (self.varDataConst().slice_rank > 0) {
                try ids.append(a, KW.dimension);
                var dims: std.ArrayList(u8) = .empty;
                for (0..@as(usize, @intCast(self.varDataConst().slice_rank))) |i| {
                    if (i > 0) try dims.append(a, ',');
                    try dims.append(a, ':');
                }
                info.dimension = dims.items;
            }
            return helpers.getKeywords(a, ids.items, info);
        }
        return helpers.getKeywords(a, l.keywords.items, l.keyword_info);
    }
    return helpers.getKeywords(a, self.keywords.items, self.keyword_info);
}

pub fn getDocsFull(self: *const Obj, a: Allocator, hover_array: *std.ArrayList([]const u8), doc_strs: *std.ArrayList([]const u8), long: bool, drop_arg: ?usize) !void {
    if (self.getDocumentation()) |d| try doc_strs.append(a, d);
    if (!long) return;
    var has_args = true;
    var in_list = false;
    for (self.procDataConst().arg_objs.items, 0..) |arg_obj_opt, i| {
        const arg_obj = arg_obj_opt orelse continue;
        if (i == drop_arg) continue;
        const h = try arg_obj.getHover(a, false, null);
        try hover_array.append(a, h.msg orelse "None");
        if (h.docs) |d| if (d.len > 0) {
            if (has_args) {
                try doc_strs.append(a, "\n**Parameters:**  ");
                has_args = false;
            }
            // a list in the previous parameter's text would swallow this one
            const entry = str.strip(try std.fmt.allocPrint(a, "`{s}` {s}", .{ arg_obj.name, d }));
            try doc_strs.append(a, if (in_list) try std.fmt.allocPrint(a, "\n{s}", .{entry}) else entry);
            in_list = endsInListItem(entry);
        };
    }
}

/// Whether the last line of a Markdown text is a list item (`- x`, `* x`, `+ x`, `1. x`)
pub fn endsInListItem(text: []const u8) bool {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n');
    const line = std.mem.trimStart(u8, if (nl) |n| text[n + 1 ..] else text, " \t");
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') return true;
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and line[i + 1] == ' ';
}

pub fn getSignature(self: *const Obj, a: Allocator, drop_arg: ?usize) Allocator.Error!Obj.Signature {
    switch (self.kind) {
        .subroutine, .function => {
            var arg_sigs: std.ArrayList(Obj.ArgSig) = .empty;
            const arg_list = try str.split(a, self.argList(), ",");
            for (self.procDataConst().arg_objs.items, 0..) |arg_obj_opt, i| {
                if (i == drop_arg) continue;
                if (arg_obj_opt) |arg_obj| {
                    const lname = try std.ascii.allocLowerString(a, arg_obj.name);
                    const label = if (arg_obj.isOptional()) try std.fmt.allocPrint(a, "{s}={s}", .{ lname, lname }) else lname;
                    try arg_sigs.append(a, .{ .label = label, .doc_md = try arg_obj.getHoverMd(a, false, null) });
                } else {
                    try arg_sigs.append(a, .{ .label = if (i < arg_list.len) arg_list[i] else "" });
                }
            }
            const sig = try self.getSnippet(a, null, null);
            return .{ .label = sig.call, .doc = self.getDocumentation(), .params = arg_sigs.items };
        },
        .method => {
            if (self.linkObj()) |l| {
                const sig = try self.getSnippet(a, null, null);
                const ls = try l.getSignature(a, self.varDataConst().drop_arg);
                return .{ .label = sig.call, .doc = self.getDocumentation(), .params = ls.params };
            }
            return .{};
        },
        .intrinsic => {
            var arg_sigs: std.ArrayList(Obj.ArgSig) = .empty;
            for (try str.split(a, self.argList(), ",")) |arg| try arg_sigs.append(a, .{ .label = arg });
            const sig = try self.getSnippet(a, null, null);
            return .{ .label = sig.call, .doc = self.doc_str, .params = arg_sigs.items };
        },
        else => return .{},
    }
}

pub fn getInterfaceArray(self: *const Obj, a: Allocator, keywords: []const []const u8, signature: []const u8, drop_arg: ?usize, change_strings: ?[2][]const u8) !?std.ArrayList([]const u8) {
    var arr: std.ArrayList([]const u8) = .empty;
    try arr.append(a, try std.mem.concat(a, u8, &.{ try std.mem.join(a, " ", keywords), signature }));
    for (self.procDataConst().arg_objs.items, 0..) |arg_obj_opt, i| {
        const arg_obj = arg_obj_opt orelse return null;
        const h = try arg_obj.getHover(a, false, null);
        var arg_doc = h.msg orelse "None";
        if (i == drop_arg) {
            if (change_strings) |cs| {
                if (std.ascii.findIgnoreCase(arg_doc, cs[0])) |i_0| {
                    arg_doc = try std.mem.concat(a, u8, &.{ arg_doc[0..i_0], cs[1], arg_doc[i_0 + cs[0].len ..] });
                }
            }
        }
        try arr.append(a, try std.fmt.allocPrint(a, "{s} :: {s}", .{ arg_doc, arg_obj.name }));
    }
    return arr;
}

pub fn getInterface(self: *const Obj, a: Allocator, name_replace: ?[]const u8, drop_arg: ?usize, change_strings: ?[2][]const u8) Allocator.Error!?[]const u8 {
    switch (self.kind) {
        .subroutine => {
            const sig = (try self.getSnippet(a, name_replace, null)).call.?;
            var kw: std.ArrayList([]const u8) = .empty;
            try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
            try kw.append(a, "SUBROUTINE ");
            var arr = (try self.getInterfaceArray(a, kw.items, sig, drop_arg, change_strings)) orelse return null;
            const name = name_replace orelse self.name;
            try arr.append(a, try std.fmt.allocPrint(a, "END SUBROUTINE {s}", .{name}));
            return try std.mem.join(a, "\n", arr.items);
        },
        .function => {
            var sig = (try self.getSnippet(a, name_replace, null)).call.?;
            sig = try std.fmt.allocPrint(a, "{s} RESULT({s})", .{ sig, self.procDataConst().result_name orelse self.name });
            var kw: std.ArrayList([]const u8) = .empty;
            if (self.procDataConst().result_type) |rt| if (rt.len > 0) try kw.append(a, rt);
            try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
            try kw.append(a, "FUNCTION ");
            var arr = (try self.getInterfaceArray(a, kw.items, sig, drop_arg, change_strings)) orelse return null;
            if (self.procDataConst().result_obj) |ro| {
                const h = try ro.getHover(a, false, null);
                try arr.append(a, try std.fmt.allocPrint(a, "{s} :: {s}", .{ h.msg orelse "None", ro.name }));
            }
            const name = name_replace orelse self.name;
            try arr.append(a, try std.fmt.allocPrint(a, "END FUNCTION {s}", .{name}));
            return try std.mem.join(a, "\n", arr.items);
        },
        .method => {
            if (self.linkObj()) |l| return l.getInterface(a, name_replace, self.varDataConst().drop_arg, change_strings);
            return null;
        },
        else => return null,
    }
}
