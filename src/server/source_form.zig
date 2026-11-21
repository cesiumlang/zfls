//! The form of an opened file whose suffix does not name one (`.fpp`,
//! `.FPP`: `suffixes.formOf` is `.detect`), which the compilers read as
//! fixed form unless their options say otherwise (#632). An editor names a
//! form by the document's language (VS Code: `FortranFreeForm` for every
//! `.fpp`); for such a file zfls detects the form from the text instead,
//! and tells the editor the form it found (`zfls/sourceForm`), which the VS
//! Code extension sets as the document's language. A language the editor
//! reopens the document in right after closing it (within `change_window`:
//! VS Code's Change Language Mode closes and opens it) other than the one
//! zfls told is the user's choice, which wins for that file while zfls
//! runs; the language zfls told, opened again, sends nothing.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parser = @import("../parser.zig");
const suffixes = @import("../suffixes.zig");
const json = @import("../json.zig");

const Server = @import("../server.zig").Server;
const SourceForm = parser.SourceForm;

/// What zfls told of a file, and what the user chose
pub const State = struct {
    told: SourceForm,
    chosen: ?SourceForm = null,
    /// when the editor last closed the document (the awake clock's
    /// nanoseconds)
    closed_at: ?i96 = null,
    /// to be told again, opened afresh in another language
    again: bool = false,
};

/// A close and an open closer than this are a change of the language
const change_window: i96 = std.time.ns_per_s;

/// The form to read `path` in, opened in a language of form `language`:
/// null to detect it
pub fn opened(self: *Server, path: []const u8, language: ?SourceForm) ?SourceForm {
    const lang = language orelse return null;
    if (suffixes.formOf(path) != .detect) return lang;
    const st = self.source_forms.getPtr(path) orelse return null;
    if (lang == st.told) {
        st.chosen = null;
        return lang;
    }
    const now = Io.Clock.awake.now(self.io).nanoseconds;
    const changed = if (st.closed_at) |t| now - t < change_window else false;
    if (changed or st.chosen == lang) {
        st.chosen = lang;
        return lang;
    }
    st.again = true;
    return null;
}

/// The editor closed `path`'s document
pub fn closed(self: *Server, path: []const u8) void {
    const st = self.source_forms.getPtr(path) orelse return;
    st.closed_at = Io.Clock.awake.now(self.io).nanoseconds;
}

/// After `path` was opened in a language of form `language` and read: the
/// form zfls detected, sent to the editor when it is not the language's,
/// the first time, or again when `opened` asks
pub fn tell(self: *Server, a: Allocator, uri: []const u8, path: []const u8, language: ?SourceForm) !void {
    const lang = language orelse return;
    if (suffixes.formOf(path) != .detect) return;
    const file = self.workspace.get(path) orelse return;
    const detected: SourceForm = if (file.declared_fixed) .fixed else .free;
    if (self.source_forms.getPtr(path)) |st| {
        if (!st.again) return;
        st.again = false;
        st.told = detected;
    } else {
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.source_forms.put(self.gpa, key, .{ .told = detected });
    }
    if (detected == lang) return;
    const params: struct { uri: []const u8, form: []const u8, languageId: []const u8 } = .{
        .uri = uri,
        .form = @tagName(detected),
        .languageId = if (detected == .fixed) "FortranFixedForm" else "FortranFreeForm",
    };
    self.sendNotification(a, "zfls/sourceForm", try json.from(a, params)) catch |e| self.logSendFailure(e);
}

/// Frees `source_forms`
pub fn deinit(self: *Server) void {
    var it = self.source_forms.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.source_forms.deinit(self.gpa);
}
