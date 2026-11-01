// Comment markers of a dialect (zfls.commentMarkers, such as `;*`): the
// grammar injection that highlights the comments they start, outside
// strings, so that a quote in such a comment does not open a string. A
// grammar is a file VS Code reads once, so the extension writes this one
// from the setting and asks for a reload when it changes. No `vscode`
// import (see test/unit).

export const INJECTION_FILE = "fortran_comment-markers.injection.json";
export const INJECTION_SCOPE = "source.fortran.comment-markers.injection";

/** `text` with the characters that mean something in a regular expression
 * escaped */
export function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

/** The injection grammar for `markers` (none: it matches nothing) */
export function markerGrammar(markers: readonly string[]): Record<string, unknown> {
  const valid = [...new Set(markers.filter((m) => m.trim() !== ""))];
  const patterns = valid.length
    ? [
        {
          begin: `(?:${valid.map(escapeRegExp).join("|")})`,
          end: "$",
          beginCaptures: { "0": { name: "punctuation.definition.comment.fortran" } },
          name: "comment.line.marker.fortran",
        },
      ]
    : [];
  return {
    $schema: "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
    comment: "Written by the zfls extension from zfls.commentMarkers; do not edit",
    scopeName: INJECTION_SCOPE,
    injectionSelector: "L:source.fortran.free -string -comment, L:source.fortran.fixed -string -comment",
    patterns,
  };
}

/** The file's text for `markers`, as the extension writes it */
export function markerGrammarText(markers: readonly string[]): string {
  return JSON.stringify(markerGrammar(markers), null, 2) + "\n";
}
