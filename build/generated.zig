//! `generated ROOT [--check]`: writes the files of the repository at ROOT that
//! are generated from others, or with `--check` fails when one is out of
//! date (`zig build generated`, `zig build check-generated`):
//!
//! - editors/vscode/schemas/fortls.schema.json, the JSON schema of zfls
//!   configuration files (.fortlsrc, .fortls.json, .fortls), from the
//!   options `applyConfig` in src/settings.zig reads: the type of their
//!   command-line option (`opts`), its help text, and their default in
//!   `Settings`. The extension contributes it for those file names.
//! - editors/vscode/package.nls.json, the user-visible strings of the
//!   extension's package.json, which refers to them as `%key%`: a
//!   translation is a package.nls.<language>.json of the same keys. Strings
//!   already moved are left alone, so this runs again after new settings or
//!   commands are added.
//! - editors/vscode/l10n/bundle.l10n.json, the messages the extension shows
//!   while it runs (each `vscode.l10n.t("...")` of its sources), in the
//!   format of `@vscode/l10n-dev export`: each message is its own key.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const settings = @import("settings");
const constants = @import("constants");

const schema_path = "editors/vscode/schemas/fortls.schema.json";
const package_path = "editors/vscode/package.json";
const nls_path = "editors/vscode/package.nls.json";
const bundle_path = "editors/vscode/l10n/bundle.l10n.json";
const sources_path = "editors/vscode/src";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const check = argv.len == 3 and std.mem.eql(u8, argv[2], "--check");
    if (argv.len != 2 and !check) {
        std.debug.print("usage: generated ROOT [--check]\n", .{});
        return 2;
    }
    var root = try Io.Dir.cwd().openDir(io, argv[1], .{});
    defer root.close(io);

    var where: []const u8 = "";
    const files = generate(io, a, root, &where) catch |e| {
        std.debug.print("{s}: {s}\n", .{ where, @errorName(e) });
        return 1;
    };
    var stale = false;
    for (files) |f| {
        if (f.changed) |changed| if (!changed) continue;
        const old = root.readFileAlloc(io, f.path, a, .limited(16 << 20)) catch |e| switch (e) {
            error.FileNotFound => "",
            else => return e,
        };
        if (std.mem.eql(u8, old, f.text)) continue;
        if (check) {
            std.debug.print("{s} is out of date: run zig build generated\n", .{f.path});
            stale = true;
            continue;
        }
        if (std.fs.path.dirname(f.path)) |d| try root.createDirPath(io, d);
        try root.writeFile(io, .{ .sub_path = f.path, .data = f.text });
        std.debug.print("wrote {s}\n", .{f.path});
    }
    return if (stale) 1 else 0;
}

/// A generated file; `changed`, when set, says whether it differs from the
/// one there is, which is otherwise compared with it
const File = struct { path: []const u8, text: []const u8, changed: ?bool = null };

/// The generated files' contents; `where` names what an error is about
fn generate(io: Io, a: Allocator, root: Io.Dir, where: *[]const u8) ![]const File {
    var files: std.ArrayList(File) = .empty;

    where.* = "src/settings.zig";
    const settings_src = try root.readFileAlloc(io, "src/settings.zig", a, .limited(1 << 20));
    try files.append(a, .{ .path = schema_path, .text = try jsonText(a, try configSchema(a, settings_src, where), true) });

    where.* = package_path;
    var pkg = try parseFile(io, a, root, package_path);
    where.* = nls_path;
    var strings = try parseFile(io, a, root, nls_path);
    if (strings == .null) strings = .{ .object = .empty };
    where.* = package_path;
    // the files are rewritten only when strings are left to move
    const moved = try moveStrings(a, &pkg, &strings.object) > 0;
    try files.append(a, .{ .path = package_path, .text = try jsonText(a, pkg, false), .changed = moved });
    try files.append(a, .{ .path = nls_path, .text = try jsonText(a, strings, false), .changed = moved });

    where.* = sources_path;
    try files.append(a, .{ .path = bundle_path, .text = try jsonText(a, try l10nBundle(io, a, root, where), false) });
    return files.items;
}

/// `v` as Python's `json.dumps(v, indent=2)` writes it, with a final
/// newline (`ascii`: other characters escaped)
fn jsonText(a: Allocator, v: Value, ascii: bool) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2, .escape_unicode = ascii }, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

/// The JSON of a file, `null` when there is none; numbers are kept as
/// written
fn parseFile(io: Io, a: Allocator, root: Io.Dir, path: []const u8) !Value {
    const text = root.readFileAlloc(io, path, a, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .null,
        else => return e,
    };
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .parse_numbers = false });
}

fn parseLiteral(a: Allocator, comptime text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

// The configuration file schema

/// The JSON schema of each option kind of `opts`
fn kindSchema(a: Allocator, kind: []const u8) !Value {
    const text: []const u8 = if (std.mem.eql(u8, kind, "flag"))
        \\{"type": "boolean"}
    else if (std.mem.eql(u8, kind, "int"))
        \\{"type": "integer"}
    else if (std.mem.eql(u8, kind, "string"))
        \\{"type": "string"}
    else if (std.mem.eql(u8, kind, "list"))
        \\{"type": "array", "items": {"type": "string"}, "uniqueItems": true}
    else if (std.mem.eql(u8, kind, "json"))
        // pp_defs: {"NAME": value, ...}, or a list of names defined as empty
        \\{"type": ["object", "array"],
        \\ "additionalProperties": {"type": ["string", "number", "boolean", "null"]},
        \\ "items": {"type": "string"}}
    else
        return error.UnknownOptionKind;
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

/// The schema of the options whose JSON is not that of their option kind
fn specialSchema(a: Allocator, key: []const u8) !?Value {
    if (std.mem.eql(u8, key, "diagnostic_severity")) {
        var v = try parseLiteral(a,
            \\{"type": "object", "propertyNames": {"enum": []},
            \\ "additionalProperties": {"enum": ["off", "error", "warning", "information", "hint"]}}
        );
        // the names of `DiagCode`, with `-` for `_`
        const names = &v.object.getPtr("propertyNames").?.object.getPtr("enum").?.array;
        inline for (@typeInfo(constants.DiagCode).@"enum".field_names) |n| {
            const name = try a.dupe(u8, n);
            std.mem.replaceScalar(u8, name, '_', '-');
            try names.append(.{ .string = name });
        }
        return v;
    }
    if (std.mem.eql(u8, key, "compiler_diagnostics")) return try parseLiteral(a,
        \\{"type": "string",
        \\ "enum": ["gfortran", "ifx", "ifort", "flang", "nvfortran", "nagfor", "lfortran", "none", null]}
    );
    // a list keeps repeated arguments; a string is split at spaces
    if (std.mem.eql(u8, key, "compiler_args")) return try parseLiteral(a,
        \\{"type": ["array", "string"], "items": {"type": "string"}}
    );
    return null;
}

/// The default of `Settings.<name>` as JSON
fn settingDefault(a: Allocator, name: []const u8) !Value {
    const defaults: settings.Settings = .{};
    inline for (@typeInfo(settings.Settings).@"struct".field_names) |n| {
        if (std.mem.eql(u8, n, name)) return defaultJson(a, @FieldType(settings.Settings, n), @field(defaults, n));
    }
    return error.UnknownSetting;
}

fn defaultJson(a: Allocator, comptime T: type, v: T) !Value {
    if (T == bool) return .{ .bool = v };
    if (T == i64) return .{ .integer = v };
    if (T == []const u8) return .{ .string = v };
    if (T == settings.StrList) {
        var list: std.json.Array = .init(a);
        for (v.slice()) |s| try list.append(.{ .string = s });
        return .{ .array = list };
    }
    switch (@typeInfo(T)) {
        .optional => |o| return if (v) |x| defaultJson(a, o.child, x) else .null,
        // pp_defs, diagnostic_severity: JSON objects
        .@"struct" => if (@hasField(T, "items") and @hasDecl(T, "empty")) {
            if (v.items.len != 0) return error.UnknownDefault;
            return .{ .object = .empty };
        },
        else => {},
    }
    return error.UnknownDefault;
}

/// The configuration keys `applyConfig` reads, in its order
fn configKeys(a: Allocator, src: []const u8) ![]const []const u8 {
    const start = std.mem.indexOf(u8, src, "pub fn applyConfig(") orelse return error.NoApplyConfig;
    const end = std.mem.indexOfPos(u8, src, start, "\n}\n") orelse return error.NoApplyConfig;
    const body = src[start..end];
    const call = "json.get(cfg, \"";
    var keys: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, call)) |i| {
        const k = i + call.len;
        const q = std.mem.indexOfScalarPos(u8, body, k, '"') orelse break;
        pos = q;
        const key = body[k..q];
        for (keys.items) |seen| {
            if (std.mem.eql(u8, seen, key)) break;
        } else try keys.append(a, key);
    }
    return keys.items;
}

fn configSchema(a: Allocator, settings_src: []const u8, where: *[]const u8) !Value {
    var properties: std.json.ObjectMap = .empty;
    for (try configKeys(a, settings_src)) |key| {
        where.* = try std.fmt.allocPrint(a, "src/settings.zig, applyConfig's key {s}", .{key});
        const opt = for (settings.opts) |o| {
            if (std.mem.eql(u8, o.long, key)) break o;
        } else return error.NotInOpts;
        var prop: std.json.ObjectMap = .empty;
        try prop.put(a, "description", .{ .string = std.mem.trim(u8, opt.help, " \t\r\n") });
        const typed = (try specialSchema(a, key)) orelse try kindSchema(a, @tagName(opt.kind));
        for (typed.object.keys(), typed.object.values()) |k, v| try prop.put(a, k, v);
        const default = try settingDefault(a, key);
        if (default == .null) {
            // the type, or each type, and null
            const t = prop.getPtr("type").?;
            var types: std.json.Array = .init(a);
            switch (t.*) {
                .array => |old| try types.appendSlice(old.items),
                else => try types.append(t.*),
            }
            try types.append(.{ .string = "null" });
            t.* = .{ .array = types };
        } else try prop.put(a, "default", default);
        try properties.put(a, key, .{ .object = prop });
    }
    var schema = try parseLiteral(a,
        \\{"$schema": "http://json-schema.org/draft-07/schema#",
        \\ "$comment": "Generated from src/settings.zig by zig build generated (build/generated.zig); do not edit",
        \\ "title": "zfls configuration",
        \\ "description": "Options of the zfls (and fortls) Fortran language server; they override the command-line options",
        \\ "type": "object"}
    );
    try schema.object.put(a, "properties", .{ .object = properties });
    return schema;
}

// package.nls.json

fn isRef(s: []const u8) bool {
    return s.len > 2 and s[0] == '%' and s[s.len - 1] == '%';
}

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

const Mover = struct {
    a: Allocator,
    strings: *std.json.ObjectMap,
    moved: usize = 0,

    /// `obj[name]`, a string, to `key`
    fn move(m: *Mover, obj: ?*Value, name: []const u8, key: []const u8) !void {
        const o = obj orelse return;
        if (o.* != .object) return;
        const v = o.object.getPtr(name) orelse return;
        if (v.* != .string or isRef(v.string) or isBlank(v.string)) return;
        try m.strings.put(m.a, key, v.*);
        v.* = .{ .string = try std.fmt.allocPrint(m.a, "%{s}%", .{key}) };
        m.moved += 1;
    }

    /// Each string of the list `obj[name]`, to `key.<index>`
    fn moveList(m: *Mover, obj: *Value, name: []const u8, key: []const u8) !void {
        const v = obj.object.getPtr(name) orelse return;
        if (v.* != .array) return;
        for (v.array.items, 0..) |*s, i| {
            if (s.* != .string or isRef(s.string) or isBlank(s.string)) continue;
            const k = try std.fmt.allocPrint(m.a, "{s}.{d}", .{ key, i });
            try m.strings.put(m.a, k, s.*);
            s.* = .{ .string = try std.fmt.allocPrint(m.a, "%{s}%", .{k}) };
            m.moved += 1;
        }
    }

    /// The descriptions of JSON schema properties, and of theirs
    fn schema(m: *Mover, props: ?*Value, prefix: []const u8) !void {
        const p = props orelse return;
        if (p.* != .object) return;
        for (p.object.keys(), p.object.values()) |name, *prop| {
            if (prop.* != .object) continue;
            const key = try std.fmt.allocPrint(m.a, "{s}.{s}", .{ prefix, name });
            for ([_][]const u8{ "description", "markdownDescription", "deprecationMessage", "markdownDeprecationMessage" }) |f|
                try m.move(prop, f, try std.fmt.allocPrint(m.a, "{s}.{s}", .{ key, f }));
            for ([_][]const u8{ "enumDescriptions", "markdownEnumDescriptions" }) |f|
                try m.moveList(prop, f, try std.fmt.allocPrint(m.a, "{s}.{s}", .{ key, f }));
            try m.schema(prop.object.getPtr("properties"), key);
        }
    }

    fn print(m: *Mover, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(m.a, fmt, args);
    }
};

fn field(v: *Value, name: []const u8) ?*Value {
    return if (v.* == .object) v.object.getPtr(name) else null;
}

fn items(v: ?*Value) []Value {
    const x = v orelse return &.{};
    return if (x.* == .array) x.array.items else &.{};
}

fn string(v: *Value, name: []const u8) []const u8 {
    const x = field(v, name) orelse return "";
    return if (x.* == .string) x.string else "";
}

/// Moves the user-visible strings of package.json `pkg` to `strings`;
/// returns how many
fn moveStrings(a: Allocator, pkg: *Value, strings: *std.json.ObjectMap) !usize {
    var m: Mover = .{ .a = a, .strings = strings };
    try m.move(pkg, "displayName", "displayName");
    try m.move(pkg, "description", "description");
    const c = field(pkg, "contributes") orelse return m.moved;
    if (field(c, "configuration")) |configs| {
        const list: []Value = if (configs.* == .array) configs.array.items else @as(*[1]Value, configs);
        for (list) |*conf| {
            try m.move(conf, "title", "configuration.title");
            try m.schema(field(conf, "properties"), "config");
        }
    }
    for (items(field(c, "commands"))) |*cmd| {
        try m.move(cmd, "title", try m.print("command.{s}.title", .{string(cmd, "command")}));
        try m.move(cmd, "category", "command.category");
    }
    for (items(field(c, "taskDefinitions"))) |*task|
        try m.schema(field(task, "properties"), try m.print("taskDefinition.{s}", .{string(task, "type")}));
    for (items(field(c, "debuggers"))) |*dbg| {
        const t = string(dbg, "type");
        try m.move(dbg, "label", try m.print("debugger.{s}.label", .{t}));
        if (field(dbg, "configurationAttributes")) |attrs| if (attrs.* == .object) {
            for (attrs.object.keys(), attrs.object.values()) |request, *r|
                try m.schema(field(r, "properties"), try m.print("debugger.{s}.{s}", .{ t, request }));
        };
        for (items(field(dbg, "configurationSnippets")), 0..) |*snip, i| {
            try m.move(snip, "label", try m.print("debugger.{s}.snippet.{d}.label", .{ t, i }));
            try m.move(snip, "description", try m.print("debugger.{s}.snippet.{d}.description", .{ t, i }));
        }
    }
    if (field(c, "views")) |views| if (views.* == .object) {
        for (views.object.values()) |*list| for (items(list)) |*v|
            try m.move(v, "name", try m.print("view.{s}.name", .{string(v, "id")}));
    };
    for (items(field(c, "walkthroughs"))) |*w| {
        const wid = string(w, "id");
        try m.move(w, "title", try m.print("walkthrough.{s}.title", .{wid}));
        try m.move(w, "description", try m.print("walkthrough.{s}.description", .{wid}));
        for (items(field(w, "steps"))) |*step| {
            const sid = string(step, "id");
            try m.move(step, "title", try m.print("walkthrough.{s}.{s}.title", .{ wid, sid }));
            try m.move(step, "description", try m.print("walkthrough.{s}.{s}.description", .{ wid, sid }));
        }
    }
    for (items(field(c, "problemMatchers"))) |*p|
        try m.move(p, "label", try m.print("problemMatcher.{s}.label", .{string(p, "name")}));
    return m.moved;
}

// l10n/bundle.l10n.json

fn l10nBundle(io: Io, a: Allocator, root: Io.Dir, where: *[]const u8) !Value {
    var dir = try root.openDir(io, sources_path, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".ts")) try paths.append(a, try a.dupe(u8, e.path));
    }
    var found: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (paths.items) |p| {
        where.* = try std.fmt.allocPrint(a, "{s}/{s}", .{ sources_path, p });
        const src = try dir.readFileAlloc(io, p, a, .limited(16 << 20));
        var line: usize = 0;
        for (try messages(a, src, &line)) |msg| try found.put(a, msg, {});
        if (line != 0) {
            where.* = try std.fmt.allocPrint(a, "{s}:{d}: l10n.t needs a string literal (not a template or a variable)", .{ where.*, line });
            return error.NotALiteral;
        }
    }
    const keys = found.keys();
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    var out: std.json.ObjectMap = .empty;
    for (keys) |k| try out.put(a, k, .{ .string = k });
    return .{ .object = out };
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn isSpace(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

/// The messages of the `l10n.t` calls of a TypeScript source: each a string
/// literal, or literals joined with `+`. A call without one sets `bad_line`
/// to its line.
fn messages(a: Allocator, src: []const u8, bad_line: *usize) ![]const []const u8 {
    const call = "l10n.t(";
    var out: std.ArrayList([]const u8) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, call)) |start| {
        from = start + call.len;
        if (start > 0 and isWord(src[start - 1])) continue;
        var pos = from;
        while (pos < src.len and isSpace(src[pos])) pos += 1;
        var msg: std.ArrayList(u8) = .empty;
        var parts: usize = 0;
        while (try literal(a, src, pos)) |lit| {
            try msg.appendSlice(a, lit.text);
            parts += 1;
            pos = lit.end;
            var next = pos;
            while (next < src.len and isSpace(src[next])) next += 1;
            if (next >= src.len or src[next] != '+') break;
            next += 1;
            while (next < src.len and isSpace(src[next])) next += 1;
            if ((try literal(a, src, next)) == null) break;
            pos = next;
        }
        if (parts == 0) {
            bad_line.* = std.mem.countScalar(u8, src[0..start], '\n') + 1;
            return out.items;
        }
        try out.append(a, msg.items);
    }
    return out.items;
}

const Literal = struct { text: []const u8, end: usize };

/// The JavaScript string literal at `pos` ('...' or "...", on one line),
/// unescaped as JSON
fn literal(a: Allocator, src: []const u8, pos: usize) !?Literal {
    if (pos >= src.len or (src[pos] != '"' and src[pos] != '\'')) return null;
    const quote = src[pos];
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\n' => return null,
            '\\' => {
                if (i + 1 >= src.len or src[i + 1] == '\n') return null;
                i += 1;
            },
            else => if (src[i] == quote) break,
        }
    } else return null;
    const body = src[pos + 1 .. i];
    // a single-quoted literal as a JSON string
    var as_json: std.ArrayList(u8) = .empty;
    try as_json.append(a, '"');
    var j: usize = 0;
    while (j < body.len) : (j += 1) {
        const c = body[j];
        if (quote == '\'' and c == '\\' and body[j + 1] == '\'') {
            try as_json.append(a, '\'');
            j += 1;
        } else if (quote == '\'' and c == '"') {
            try as_json.appendSlice(a, "\\\"");
        } else if (c == '\\') {
            try as_json.appendSlice(a, body[j .. j + 2]);
            j += 1;
        } else try as_json.append(a, c);
    }
    try as_json.append(a, '"');
    const text = try std.json.parseFromSliceLeaky([]const u8, a, as_json.items, .{});
    return .{ .text = text, .end = i + 1 };
}

test "messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: usize = 0;
    const msgs = try messages(a,
        \\vscode.l10n.t("one {0}", x);
        \\l10n.t( 'it\'s "two"' );
        \\l10n.t("three, " +
        \\  'and more\n');
        \\notl10n.t("skipped");
        \\l10n.t("a" + b);
    , &bad);
    try std.testing.expectEqual(0, bad);
    try std.testing.expectEqual(4, msgs.len);
    try std.testing.expectEqualStrings("one {0}", msgs[0]);
    try std.testing.expectEqualStrings("it's \"two\"", msgs[1]);
    try std.testing.expectEqualStrings("three, and more\n", msgs[2]);
    try std.testing.expectEqualStrings("a", msgs[3]);

    _ = try messages(a, "x;\nl10n.t(`template ${y}`);", &bad);
    try std.testing.expectEqual(2, bad);
}

test "configKeys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const keys = try configKeys(arena.allocator(),
        \\pub fn applyConfig(a: Allocator, s: *Settings, cfg: json.Value) !void {
        \\    if (json.get(cfg, "b")) |v| s.b = v;
        \\    s.a = jsonBool(json.get(cfg, "a"), s.a);
        \\    if (json.get(cfg, "b")) |v| s.c = v;
        \\}
        \\fn other() void { json.get(cfg, "z"); }
        \\
    );
    try std.testing.expectEqual(2, keys.len);
    try std.testing.expectEqualStrings("b", keys[0]);
    try std.testing.expectEqualStrings("a", keys[1]);
}
