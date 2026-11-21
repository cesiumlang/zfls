//! The symbols of an ifx listing (`/list /show:map`, Linux `-list -show
//! map`), for ifx_oracle.zig: the SYMBOL CROSS REFERENCE of each program
//! unit (name, object, declared line, type, rank, attributes), the
//! SUBPROGRAMS/COMMON BLOCKS the file declares, and the TYPE
//! COMPONENTS/COMMON VARIABLES (`TYPE.COMPONENT`). ifx 2026.2.0: a name
//! that a unit has from its host or a module shows the line of its first
//! use there, and a host's variable may show only in a contained unit.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// lowercase; a component's `type.component`
    name: []const u8,
    /// `Local`, `Dummy`, `Param`, `Result`, `Type`, `Func`, `Subr`,
    /// `Module`, `Prog`, `Label`, ...; empty for a component
    object: []const u8,
    /// `R(4)`, `I(8)`, `L(4)`, `C(16)` (bytes), `CHAR`, `RECORD`, a type's
    /// name, `TBProc`; may be empty
    type: []const u8,
    /// the rank, null for a scalar or none given
    rank: ?usize,
    /// `ARG,IN`, `ALC`, `PTR`, `TGT`, `PRIV`, ...
    attrs: []const u8,
};

pub const Listing = struct {
    symbols: []const Entry,
    /// the program units and COMMON blocks the file declares
    subprograms: []const Entry,
    components: []const Entry,
};

const Mode = enum { none, symbols, subprograms, components };

/// The columns of a section, from its header line
const Columns = struct {
    object: ?usize = null,
    type: usize = 0,
    bytes: usize = 0,
    dimen: usize = 0,
    elements: usize = 0,
    attrs: usize = 0,
    refs: usize = 0,

    fn of(header: []const u8) ?Columns {
        const t = std.mem.find(u8, header, " Type ") orelse return null;
        return .{
            .object = std.mem.find(u8, header, " Object "),
            .type = t + 1,
            .bytes = (std.mem.find(u8, header, " Bytes") orelse return null) + 1,
            .dimen = (std.mem.find(u8, header, " Dimen") orelse return null) + 1,
            .elements = (std.mem.find(u8, header, " Elements") orelse return null) + 1,
            .attrs = (std.mem.find(u8, header, " Attributes") orelse return null) + 1,
            .refs = (std.mem.find(u8, header, " References") orelse return null) + 1,
        };
    }
};

fn field(line: []const u8, start: usize, end: usize) []const u8 {
    if (start >= line.len) return "";
    return std.mem.trim(u8, line[start..@min(end, line.len)], " \t");
}

pub fn parse(a: Allocator, text: []const u8) !Listing {
    var symbols: std.ArrayList(Entry) = .empty;
    var subprograms: std.ArrayList(Entry) = .empty;
    var components: std.ArrayList(Entry) = .empty;
    var mode: Mode = .none;
    var cols: ?Columns = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (std.mem.startsWith(u8, line, "SYMBOL CROSS REFERENCE")) {
            mode = .symbols;
        } else if (std.mem.startsWith(u8, line, "SUBPROGRAMS/COMMON BLOCKS")) {
            mode = .subprograms;
        } else if (std.mem.startsWith(u8, line, "TYPE COMPONENTS/COMMON VARIABLES")) {
            mode = .components;
        } else if (line.len > 0 and line[0] != ' ' and !std.mem.startsWith(u8, line, "Page ") and !std.ascii.isDigit(line[0])) {
            // ENTRY POINTS, COMPILER OPTIONS BEING USED, ...
            mode = .none;
            cols = null;
        } else if (mode != .none and std.mem.startsWith(u8, line, " Name ")) {
            cols = Columns.of(line);
        } else if (mode != .none and line.len > 1 and line[0] == ' ' and line[1] != ' ') {
            const c = cols orelse continue;
            const name_end = std.mem.findScalarPos(u8, line, 1, ' ') orelse line.len;
            const name = try std.ascii.allocLowerString(a, line[1..name_end]);
            const first = c.object orelse c.type;
            var object: []const u8 = "";
            var rest_from = first;
            if (c.object) |o| {
                // `Object Declared`: the object, then the line
                var words = std.mem.tokenizeScalar(u8, field(line, o, c.type), ' ');
                object = words.next() orelse "";
                rest_from = c.type;
            }
            const dimen = field(line, c.dimen, c.elements);
            const e: Entry = .{
                .name = name,
                .object = object,
                .type = field(line, rest_from, c.bytes),
                .rank = if (dimen.len == 0) null else std.fmt.parseInt(usize, dimen, 10) catch null,
                .attrs = field(line, c.attrs, c.refs),
            };
            try (switch (mode) {
                .symbols => &symbols,
                .subprograms => &subprograms,
                .components => &components,
                .none => unreachable,
            }).append(a, e);
        }
    }
    return .{ .symbols = symbols.items, .subprograms = subprograms.items, .components = components.items };
}

test "an ifx listing's symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ifx 2026.2.0, an excerpt
    const l = try parse(arena.allocator(),
        \\ENTRY POINTS
        \\ Address      Type  Name
        \\       CONSTRUCTS_mp_RUN
        \\SYMBOL CROSS REFERENCE
        \\ Name                       Object Declared Type            Bytes Dimen Elements Attributes       References
        \\ BUFFER                     Local  16       R(4)            4     1     0                         20,24,26,40
        \\ ITEMS                      Dummy  14       RECORD          4     1     0        ARG,IN           22,30
        \\ RUN                        Subr   12
        \\Page 3           Source Listing                  BLOCK@7
        \\2026-11-21 05:19 Symbol Table                    constructs.f90
        \\TYPE COMPONENTS/COMMON VARIABLES
        \\ Name                       Type            Bytes Offset   Dimen Elements Attributes       References
        \\ BASE_T.ID                  I(4)            4     0              scalar                    26,30
        \\SUBPROGRAMS/COMMON BLOCKS
        \\ Name                       Object Declared Type            Bytes Dimen Elements Attributes       References
        \\ CONSTRUCTS                 Module 3
        \\COMPILER OPTIONS BEING USED
        \\  /noOa                                 /Qansi-alias
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), l.symbols.len);
    try std.testing.expectEqualStrings("buffer", l.symbols[0].name);
    try std.testing.expectEqualStrings("Local", l.symbols[0].object);
    try std.testing.expectEqualStrings("R(4)", l.symbols[0].type);
    try std.testing.expectEqual(@as(?usize, 1), l.symbols[0].rank);
    try std.testing.expectEqualStrings("ARG,IN", l.symbols[1].attrs);
    try std.testing.expectEqualStrings("Subr", l.symbols[2].object);
    try std.testing.expectEqual(@as(usize, 1), l.components.len);
    try std.testing.expectEqualStrings("base_t.id", l.components[0].name);
    try std.testing.expectEqualStrings("I(4)", l.components[0].type);
    try std.testing.expect(l.components[0].rank == null);
    try std.testing.expectEqualStrings("Module", l.subprograms[0].object);
}
