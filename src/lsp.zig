//! Types of the Language Server Protocol messages zfls receives and sends.
//!
//! Requests are decoded with `json.decode` and responses encoded with
//! `json.from`. When encoding, an optional field that defaults to `null` is
//! left out while it is null, which is how LSP treats absent optional
//! properties.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

// --------------------------------------------------------------------------
// Basic structures

pub const Position = struct { line: usize, character: usize };

pub const Range = struct { start: Position, end: Position };

pub const Location = struct { uri: []const u8, range: Range };

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

pub const TextEdit = struct { range: Range, newText: []const u8 };

pub const DiagnosticRelatedInformation = struct { location: Location, message: []const u8 };

pub const Diagnostic = struct {
    range: Range,
    message: []const u8,
    severity: i64,
    relatedInformation: ?[]const DiagnosticRelatedInformation = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    /// 1: unnecessary (shown faded), 2: deprecated
    tags: ?[]const i64 = null,
};

/// The edits of each file, as the object `{uri: [TextEdit]}` of
/// `WorkspaceEdit.changes`
pub const Changes = struct {
    pub const File = struct { uri: []const u8, edits: []const TextEdit };

    files: []const File,

    pub fn toJson(self: Changes, a: Allocator) Allocator.Error!json.Value {
        var obj: json.ObjectMap = .empty;
        for (self.files) |f| try obj.put(a, try json.validUtf8(a, f.uri), try json.from(a, f.edits));
        return .{ .object = obj };
    }
};

pub const WorkspaceEdit = struct { changes: Changes };

// --------------------------------------------------------------------------
// Responses

pub const SymbolInformation = struct {
    name: []const u8,
    kind: i64,
    location: Location,
    containerName: ?[]const u8 = null,
};

/// A symbol of a document's outline, with those it contains
pub const DocumentSymbol = struct {
    name: []const u8,
    detail: ?[]const u8 = null,
    kind: i64,
    range: Range,
    selectionRange: Range,
    children: []const DocumentSymbol = &.{},
};

pub const SemanticTokens = struct { data: []const u32 };

pub const FoldingRange = struct {
    startLine: usize,
    endLine: usize,
    kind: ?[]const u8 = null,
};

/// `insertTextFormat` of a snippet
pub const snippet_format: i64 = 2;

pub const CompletionItem = struct {
    label: []const u8,
    insertText: ?[]const u8 = null,
    insertTextFormat: ?i64 = null,
    kind: i64,
    detail: []const u8,
    documentation: ?MarkupContent = null,
    sortText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
    additionalTextEdits: ?[]const TextEdit = null,
};

pub const Hover = struct { contents: MarkupContent };

pub const ParameterInformation = struct {
    label: []const u8,
    documentation: ?MarkupContent = null,
};

pub const SignatureInformation = struct {
    label: []const u8,
    parameters: []const ParameterInformation,
    documentation: ?MarkupContent = null,
    /// of this signature, when there are several (a generic interface)
    activeParameter: ?i64 = null,
};

pub const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeParameter: i64,
    activeSignature: ?i64 = null,
};

pub const CodeAction = struct {
    title: []const u8,
    kind: []const u8,
    edit: WorkspaceEdit,
    diagnostics: []const Diagnostic,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};

pub const ShowMessageParams = struct { type: i64, message: []const u8 };

pub const CompletionOptions = struct {
    resolveProvider: bool,
    triggerCharacters: []const []const u8,
};

pub const SignatureHelpOptions = struct { triggerCharacters: []const []const u8 };

pub const SemanticTokensLegend = struct {
    tokenTypes: []const []const u8,
    tokenModifiers: []const []const u8,
};

pub const SemanticTokensOptions = struct {
    legend: SemanticTokensLegend,
    full: bool = true,
};

pub const ServerCapabilities = struct {
    completionProvider: CompletionOptions,
    definitionProvider: bool = true,
    documentSymbolProvider: bool = true,
    foldingRangeProvider: bool = true,
    documentHighlightProvider: bool = true,
    referencesProvider: bool = true,
    hoverProvider: bool = true,
    implementationProvider: bool = true,
    /// `true`, or `{"prepareProvider": true}` for clients with prepareSupport
    renameProvider: json.Value = .{ .bool = true },
    selectionRangeProvider: bool = true,
    documentLinkProvider: struct { resolveProvider: bool = false } = .{},
    documentOnTypeFormattingProvider: struct { firstTriggerCharacter: []const u8 = "#" } = .{},
    inlayHintProvider: bool = true,
    workspaceSymbolProvider: bool = true,
    textDocumentSync: i64,
    signatureHelpProvider: ?SignatureHelpOptions = null,
    codeActionProvider: ?bool = null,
    semanticTokensProvider: ?SemanticTokensOptions = null,
};

pub const InitializeResult = struct { capabilities: ServerCapabilities };

/// The `data` of an error response
pub const ErrorData = struct { traceback: []const u8 };

pub const ResponseError = struct {
    code: i64,
    message: []const u8,
    data: ?ErrorData = null,
};

// --------------------------------------------------------------------------
// Request parameters

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
    /// `didOpen`: the document's text (zfls reads files from disk, as fortls
    /// does; it uses this for documents that are not files)
    text: ?[]const u8 = null,
};

/// `didOpen`, `didSave`, `didClose`, `documentSymbol`, `foldingRange` and
/// `semanticTokens/full`
pub const TextDocumentParams = struct { textDocument: TextDocumentIdentifier };

/// `completion`, `hover`, `signatureHelp`, `definition`, `references`,
/// `documentHighlight` and `implementation`
pub const PositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

pub const RenameParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    newName: []const u8,
};

pub const CodeActionParams = struct {
    textDocument: TextDocumentIdentifier,
    range: Range,
};

pub const WorkspaceSymbolParams = struct { query: []const u8 };

/// `type`: 1 created, 2 changed, 3 deleted
pub const FileEvent = struct { uri: []const u8, type: i64 };

pub const DidChangeWatchedFilesParams = struct { changes: []const FileEvent };

pub const ContentChange = struct {
    range: ?Range = null,
    text: []const u8,
};

pub const DidChangeParams = struct {
    textDocument: TextDocumentIdentifier,
    contentChanges: []const ContentChange,
};

pub const InitializeParams = struct {
    rootUri: ?[]const u8 = null,
    rootPath: ?[]const u8 = null,
    capabilities: ClientCapabilities = .{},
    /// to report the progress of indexing with
    workDoneToken: ?json.Value = null,
};

/// The `value` of a `$/progress` notification
pub const WorkDoneProgress = struct {
    kind: []const u8,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    percentage: ?i64 = null,
};

/// What the client supports, of what zfls looks at
pub const ClientCapabilities = struct {
    textDocument: struct {
        documentSymbol: struct {
            hierarchicalDocumentSymbolSupport: bool = false,
        } = .{},
        rename: struct {
            prepareSupport: bool = false,
        } = .{},
    } = .{},
};

pub const SelectionRangeParams = struct {
    textDocument: TextDocumentIdentifier,
    positions: []const Position,
};

pub const SelectionRange = struct { range: Range, parent: ?*const SelectionRange = null };

pub const DocumentLink = struct { range: Range, target: []const u8 };

pub const PrepareRenameResult = struct { range: Range, placeholder: []const u8 };

pub const InlayHintParams = struct {
    textDocument: TextDocumentIdentifier,
    range: Range,
};

/// `kind`: 1 type, 2 parameter
pub const InlayHint = struct {
    position: Position,
    label: []const u8,
    kind: i64,
    paddingLeft: ?bool = null,
    paddingRight: ?bool = null,
};

pub const OnTypeFormattingParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    ch: []const u8,
};
