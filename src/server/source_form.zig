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
//!
//! A lasting choice is a file association (`file_associations`, VS Code's
//! `files.associations`) that gives the file a form's language (#686): zfls
//! reads it in that form, open or not, and detects nothing. When the
//! associations change, an open document whose association changed is
//! read anew, and the editor told its association's form, or the detected
//! one when it has none any more.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parser = @import("../parser.zig");
const suffixes = @import("../suffixes.zig");
const json = @import("../json.zig");
const paths = @import("../paths.zig");
const vscode_glob = @import("../vscode_glob.zig");

const Server = @import("../server.zig").Server;
const SourceForm = parser.SourceForm;
const workspace = @import("workspace.zig");
const linking = @import("linking.zig");
const summary = @import("summary.zig");

/// What zfls told of a file opened in a form's language, and what the user
/// chose
pub const State = struct {
    /// the form of the language the editor last opened the document in
    language: SourceForm,
    /// the form its file association named then
    association: ?SourceForm = null,
    /// the form zfls detected and told; null: none yet (or an association)
    told: ?SourceForm = null,
    chosen: ?SourceForm = null,
    /// when the editor last closed the document (the awake clock's
    /// nanoseconds)
    closed_at: ?i96 = null,
    /// to be told again, opened afresh in another language
    again: bool = false,
};

/// A close and an open closer than this are a change of the language
const change_window: i96 = std.time.ns_per_s;

/// The form `file_associations` gives `path`: that of the language of the
/// longest pattern that matches it (the later of equal ones), as VS Code
/// picks; null for a file whose suffix names a form, or for a language of
/// no form
pub fn association(self: *const Server, a: Allocator, path: []const u8) Allocator.Error!?SourceForm {
    if (suffixes.formOf(path) != .detect or paths.isVirtualUri(path)) return null;
    var best: ?[]const u8 = null;
    var language: []const u8 = "";
    const list = self.s.file_associations.items;
    var i = list.len;
    while (i > 0) {
        i -= 1;
        const x = list[i];
        if (best) |b| if (x.pattern.len <= b.len) continue;
        if (!try vscode_glob.matchesFile(a, x.pattern, path)) continue;
        best = x.pattern;
        language = x.language;
    }
    return if (best != null) parser.formOfLanguage(language) else null;
}

/// The form to read `path` in, opened in a language of form `language`:
/// null to detect it (or to take its association's)
pub fn opened(self: *Server, a: Allocator, path: []const u8, language: ?SourceForm) !?SourceForm {
    const lang = language orelse return null;
    if (suffixes.formOf(path) != .detect) return lang;
    const gop = try self.source_forms.getOrPut(self.gpa, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
            self.source_forms.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.value_ptr.* = .{ .language = lang };
    }
    const st = gop.value_ptr;
    st.language = lang;
    // the editor's language is the association's, or the user's since
    if (try association(self, a, path)) |assoc| {
        st.* = .{ .language = lang, .association = assoc };
        return lang;
    }
    st.association = null;
    const told = st.told orelse return null;
    if (lang == told) {
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
/// the first time, or again when `opened` asks; nothing for a file with an
/// association
pub fn tell(self: *Server, a: Allocator, uri: []const u8, path: []const u8, language: ?SourceForm) !void {
    const lang = language orelse return;
    const st = self.source_forms.getPtr(path) orelse return;
    if (st.association != null) return;
    if (st.told != null and !st.again) return;
    const file = self.workspace.get(path) orelse return;
    const detected: SourceForm = if (file.declared_fixed) .fixed else .free;
    st.again = false;
    st.told = detected;
    if (detected != lang) send(self, a, uri, detected);
}

/// `zfls/sourceForm`: the editor is to give `uri` the language of `form`
fn send(self: *Server, a: Allocator, uri: []const u8, form: SourceForm) void {
    const params: struct { uri: []const u8, form: []const u8, languageId: []const u8 } = .{
        .uri = uri,
        .form = @tagName(form),
        .languageId = if (form == .fixed) "FortranFixedForm" else "FortranFreeForm",
    };
    const v = json.from(a, params) catch |e| return self.logSendFailure(e);
    self.sendNotification(a, "zfls/sourceForm", v) catch |e| self.logSendFailure(e);
}

/// After `file_associations` changed: each file whose association changed
/// read in its new form; an open document's editor told its association's
/// form, or the detected one, when its language is another
pub fn associationsChanged(self: *Server, a: Allocator) !void {
    var changed = false;
    for (self.workspace.values()) |f| {
        if (suffixes.formOf(f.path) != .detect) continue;
        const now = try association(self, a, f.path);
        const st = if (self.open_docs.contains(f.path)) self.source_forms.getPtr(f.path) else null;
        // an open document's as opened; a re-indexed file's is the new one
        const was = if (st) |s| s.association else f.associated_form;
        f.associated_form = now;
        if (now == was) continue;
        var form = f.forced_form;
        if (st) |s| {
            // as when first opened
            s.* = .{ .language = s.language, .association = now, .closed_at = s.closed_at };
            form = null;
        }
        if (f.forceForm(form) and f.ast != null) {
            if (workspace.updateWorkspaceFile(self, f.path, false, true, false)) |c| {
                changed = changed or c;
            } else |e| self.log.err("reading {s} in its associated form: {s}", .{ f.path, @errorName(e) });
        }
        const s = st orelse continue;
        const uri = try paths.pathToUri(a, f.path);
        if (now) |n| {
            if (n != s.language) send(self, a, uri, n);
        } else try tell(self, a, uri, f.path, s.language);
    }
    if (changed) {
        _ = try summary.sleepAll(self, a);
        _ = try workspace.addNeededFiles(self, a, null);
        try linking.fullRelink(self, a);
        try summary.wakeIncluded(self, a);
    }
}

/// Frees `source_forms`
pub fn deinit(self: *Server) void {
    var it = self.source_forms.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.source_forms.deinit(self.gpa);
}
