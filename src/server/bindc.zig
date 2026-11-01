//! Fortran and C (`BIND(C)`, hansec #115): the C name of a procedure, the
//! Fortran procedures of a C name (go to definition from a C file, in
//! VS Code by `zfls/bindCTargets`, in other editors in a C document opened
//! in zfls), and, for the editors that have no C language server to ask,
//! a light search of the workspace's C files for the declarations of a
//! procedure's C name, which go to definition adds. zfls parses no C: a
//! declaration is a line where the name follows a type and an opening
//! parenthesis follows it.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const regex = @import("../regex.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const glob = @import("../glob.zig");
const definition = @import("definition.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;

/// The C search is done again when it is older than this
const index_ttl_s = 60;
/// Files of these extensions are C's (and C++'s, and CUDA's)
const c_extensions = [_][]const u8{ ".h", ".hh", ".hpp", ".hxx", ".c", ".cc", ".cpp", ".cxx", ".cu", ".cuh" };

/// Whether `path` is a C (or C++) file
pub fn isCFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (c_extensions) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// The C name of a subroutine or function with `BIND(C)`: its `NAME=`,
/// else its name in lowercase; null without `BIND(C)` or with an empty
/// `NAME=` (no binding label)
pub fn cNameOf(a: Allocator, proc: *const Obj) !?[]const u8 {
    if (proc.kind != .subroutine and proc.kind != .function) return null;
    const file = proc.file_ast.file orelse return null;
    if (proc.sline == 0) return null;
    const cl = try file.getCodeLine(a, proc.sline - 1, true, false, false, true);
    var text: std.ArrayList(u8) = .empty;
    for (cl.pre) |l| try text.appendSlice(a, l);
    if (cl.curr) |c| try text.appendSlice(a, c);
    for (cl.post) |l| try text.appendSlice(a, l);
    return cNameIn(a, text.items, proc.name);
}

/// The C name that a procedure statement gives `name` (see `cNameOf`)
pub fn cNameIn(a: Allocator, statement: []const u8, name: []const u8) !?[]const u8 {
    const joined = try std.mem.replaceOwned(u8, a, statement, "&", " ");
    var re = try regex.Regex.compile(a, "\\bbind\\s*\\(\\s*c\\s*(?:,\\s*name\\s*=\\s*([\"'])(.*?)\\1\\s*)?\\)", regex.I);
    defer re.deinit();
    const m = re.search(joined) orelse return null;
    if (m.group(2)) |label| {
        const t = std.mem.trim(u8, label, " ");
        return if (t.len == 0) null else t;
    }
    return try std.ascii.allocLowerString(a, name);
}

/// The workspace's procedures whose C name is `cname`, definitions before
/// interface bodies
pub fn fortranTargets(self: *Server, a: Allocator, cname: []const u8) ![]const lsp.Location {
    var defs: std.ArrayList(lsp.Location) = .empty;
    var ifaces: std.ArrayList(lsp.Location) = .empty;
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.scope_list.items) |sc| {
            const n = (try cNameOf(a, sc)) orelse continue;
            if (!std.mem.eql(u8, n, cname)) continue;
            const loc = try json.decode(lsp.Location, a, try definition.createRefLink(self, a, sc));
            const in_interface = if (sc.parent) |p| p.kind == .interface else false;
            try (if (in_interface) &ifaces else &defs).append(a, loc);
        }
    }
    try defs.appendSlice(a, ifaces.items);
    return defs.items;
}

/// `zfls/bindC`: the procedure at a position and its C name, null when it
/// is none with `BIND(C)`
pub fn serveBindC(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const d = (try definition.definitionAt(self, a, params, false)) orelse return .null;
    const cname = (try cNameOf(a, d.obj)) orelse return .null;
    return json.from(a, .{ .name = d.obj.name, .cName = cname });
}

/// `zfls/bindCTargets`: the Fortran procedures of a C name (`{name}`)
pub fn serveBindCTargets(self: *Server, a: Allocator, params: Value) !Value {
    const name = json.str(json.get(params, "name")) orelse return error.InvalidParams;
    return json.from(a, try fortranTargets(self, a, name));
}

/// Go to definition in a C document opened in zfls: the Fortran procedures
/// of the name at the position
pub fn cDefinition(self: *Server, a: Allocator, doc: *const FortranFile, params: lsp.PositionParams) !Value {
    const text = doc.getLine(params.position.line, false) orelse return .null;
    const col = @min(Server.toByteCol(doc, params.position.line, params.position.character), text.len);
    var s = col;
    while (s > 0 and isIdent(text[s - 1])) s -= 1;
    var e = col;
    while (e < text.len and isIdent(text[e])) e += 1;
    if (s == e or std.ascii.isDigit(text[s])) return .null;
    const targets = try fortranTargets(self, a, text[s..e]);
    if (targets.len == 0) return .null;
    return json.from(a, targets);
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// --------------------------------------------------------------------------
// The C search

/// The declarations found of each C name the workspace binds, and when
pub const CIndex = struct {
    arena: std.heap.ArenaAllocator,
    built_ns: i96,
    names: std.StringHashMapUnmanaged(void) = .empty,
    found: std.StringHashMapUnmanaged(std.ArrayList(lsp.Location)) = .empty,
};

pub fn deinitIndex(self: *Server) void {
    if (self.c_index) |ix| {
        ix.arena.deinit();
        self.gpa.destroy(ix);
        self.c_index = null;
    }
}

/// The declarations of `cname` in the workspace's C files
pub fn cDeclarations(self: *Server, a: Allocator, cname: []const u8) ![]const lsp.Location {
    if (self.s.disable_bind_c_search) return &.{};
    const now = Io.Clock.awake.now(self.io).nanoseconds;
    if (self.c_index) |ix| {
        const fresh = now - ix.built_ns < @as(i96, index_ttl_s) * std.time.ns_per_s;
        if (fresh and ix.names.contains(cname)) {
            return if (ix.found.get(cname)) |l| l.items else &.{};
        }
    }
    deinitIndex(self);
    const ix = try self.gpa.create(CIndex);
    ix.* = .{ .arena = .init(self.gpa), .built_ns = now };
    self.c_index = ix;
    const ia = ix.arena.allocator();
    // the C names the workspace binds, and this one
    try ix.names.put(ia, try ia.dupe(u8, cname), {});
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.scope_list.items) |sc| {
            const n = (try cNameOf(a, sc)) orelse continue;
            if (!ix.names.contains(n)) try ix.names.put(ia, try ia.dupe(u8, n), {});
        }
    }
    for (try cFiles(self, a)) |path| try scanFile(self, a, ix, path);
    return if (ix.found.get(cname)) |l| l.items else &.{};
}

/// The C files of the source directories
fn cFiles(self: *Server, a: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (self.s.source_dirs.slice()) |dir| {
        const entries = glob.listEntries(self.io, a, dir) catch continue;
        for (entries) |e| {
            if (!e.is_file or !isCFile(e.name)) continue;
            const p = try paths.join(a, &.{ dir, e.name });
            if (!self.s.excl_paths.contains(p)) try out.append(a, p);
        }
    }
    return out.items;
}

fn scanFile(self: *Server, a: Allocator, ix: *CIndex, path: []const u8) !void {
    const text = Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(16 * 1024 * 1024)) catch return;
    var uri: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    while (it.next()) |raw| : (ln += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const d = declarationIn(line) orelse continue;
        const name = line[d.start..d.end];
        if (!ix.names.contains(name)) continue;
        const ia = ix.arena.allocator();
        if (uri == null) uri = try paths.pathToUri(ia, path);
        const gop = try ix.found.getOrPut(ia, ix.names.getKey(name).?);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(ia, .{ .uri = uri.?, .range = .{ .start = .{ .line = ln, .character = d.start }, .end = .{ .line = ln, .character = d.end } } });
    }
}

const statement_words = [_][]const u8{ "return", "if", "while", "for", "switch", "else", "do", "case", "sizeof", "goto" };

/// The function a line declares or defines: an identifier followed by `(`,
/// after a type on the same line (`void foo(int)`, `int *bar(void);`) or
/// at the start of the line (`foo(int x)` after a type on the line before)
fn declarationIn(line: []const u8) ?struct { start: usize, end: usize } {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0 or t[0] == '#' or std.mem.startsWith(u8, t, "//") or t[0] == '*') return null;
    const paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    var e = paren;
    while (e > 0 and (line[e - 1] == ' ' or line[e - 1] == '\t')) e -= 1;
    var s = e;
    while (s > 0 and isIdent(line[s - 1])) s -= 1;
    if (s == e or std.ascii.isDigit(line[s])) return null;
    const name = line[s..e];
    for (statement_words) |w| if (std.mem.eql(u8, name, w)) return null;
    // what comes before: a type (words, `*`, `&`), nothing else
    const before = std.mem.trim(u8, line[0..s], " \t");
    if (before.len == 0) return if (s == 0) .{ .start = s, .end = e } else null;
    var words = std.mem.tokenizeAny(u8, before, " \t*&");
    var n: usize = 0;
    while (words.next()) |w| {
        for (w) |c| if (!(isIdent(c) or c == ':' or c == '<' or c == '>' or c == ',')) return null;
        for (statement_words) |sw| if (std.mem.eql(u8, w, sw)) return null;
        n += 1;
    }
    return if (n > 0) .{ .start = s, .end = e } else null;
}

test "the C names of procedure statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("c_add", (try cNameIn(a, "integer(c_int) function c_add(a, b) bind(C, name=\"c_add\")", "c_add")).?);
    try std.testing.expectEqualStrings("MyFunc", (try cNameIn(a, "subroutine f(x) BIND ( C , NAME = 'MyFunc' )", "f")).?);
    try std.testing.expectEqualStrings("solve", (try cNameIn(a, "subroutine Solve(n) bind(c)", "Solve")).?);
    try std.testing.expectEqualStrings("g", (try cNameIn(a, "function g(x) result(r) &      bind(c, &   name=\"g\")", "g")).?);
    try std.testing.expect((try cNameIn(a, "subroutine h() bind(c, name=\"\")", "h")) == null);
    try std.testing.expect((try cNameIn(a, "subroutine k()", "k")) == null);
}

test "C declarations, not calls" {
    const yes = [_][]const u8{ "void c_add(int a, int b);", "int *make_grid (int n)", "extern double solve(void);", "c_add(int a)", "static inline float sq(float x) {" };
    for (yes) |l| try std.testing.expect(declarationIn(l) != null);
    const no = [_][]const u8{ "  c_add(1, 2);", "  x = c_add(1, 2);", "  return c_add(a, b);", "  if (c_add(a, b) > 0)", "#define c_add(a, b) ((a) + (b))", "// void c_add(int);", " * c_add(int) in a comment" };
    for (no) |l| try std.testing.expect(declarationIn(l) == null);
    const d = declarationIn("int *make_grid (int n)").?;
    try std.testing.expectEqual(@as(usize, 5), d.start);
    try std.testing.expectEqual(@as(usize, 14), d.end);
}
