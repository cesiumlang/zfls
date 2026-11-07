// Toggling fixed-form comments with a character in column 1 (`C`, `c`, `*`)
// instead of VS Code's `!` at the indentation (Modern Fortran #535). The
// pure part (`toggleComments`) has no `vscode` import (see test/unit).

/** The characters that make a fixed-form line a comment in column 1 */
const FIXED_COMMENT = /^[cC*!]/;

/** Comment the lines with `ch` in column 1, or uncomment them when every
 * line that is not blank is already a comment there. Blank lines are left
 * alone. Returns the new lines. */
export function toggleComments(lines: readonly string[], ch: string): string[] {
  const code = lines.filter((l) => l.trim() !== "");
  if (code.length > 0 && code.every((l) => FIXED_COMMENT.test(l))) {
    return lines.map((l) => (l.trim() === "" ? l : l.slice(1)));
  }
  return lines.map((l) => (l.trim() === "" ? l : ch + l));
}
