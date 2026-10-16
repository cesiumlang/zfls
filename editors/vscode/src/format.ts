// The pure parts of formatting with findent or fprettify: the arguments,
// the lines of a selection, and the smallest edit that turns the old lines
// into the formatted ones. No `vscode` import (see test/unit).

export type Formatter = "findent" | "fprettify";

export const FORMATTERS: readonly Formatter[] = ["findent", "fprettify"];

/** How to install each formatter, for the message when it is missing */
export const INSTALL_HINTS: Record<Formatter, string> = {
  findent: "pip install findent (or conda install -c conda-forge findent)",
  fprettify: "pip install fprettify (or conda install -c conda-forge fprettify)",
};

/** The language IDs of the extension: fixed form or else free form */
export function isFixedForm(languageId: string): boolean {
  return languageId === "FortranFixedForm";
}

/**
 * The arguments for a formatter that reads the source from stdin and writes
 * the result to stdout.
 *
 * - findent cannot see the file name, so the input form is given with
 *   `-ifixed` or `-ifree`, unless the user's arguments set one (`-i...` form
 *   or `--input_format`/`--input-format`). For a selection, `-Ia` makes the
 *   first selected line's indentation the starting indentation.
 * - fprettify reads stdin when given no file.
 *
 * The user's arguments come last, so they can override the defaults where
 * the tool takes the last of repeated options.
 */
export function formatterArgs(
  formatter: Formatter,
  languageId: string,
  userArgs: readonly string[],
  selection: boolean,
): string[] {
  const args: string[] = [];
  if (formatter === "findent") {
    if (!userArgs.some(isFindentInputFormat)) {
      args.push(isFixedForm(languageId) ? "-ifixed" : "-ifree");
    }
    if (selection && !userArgs.some(isFindentStartIndent)) {
      args.push("-Ia");
    }
  }
  return [...args, ...userArgs];
}

function isFindentInputFormat(arg: string): boolean {
  return /^-i(fixed|free|auto)$/.test(arg) || /^--input[_-]format(=|$)/.test(arg);
}

function isFindentStartIndent(arg: string): boolean {
  return /^-I/.test(arg) || /^--start[_-]indent(=|$)/.test(arg);
}

/** Why `formatter` cannot format this language, if it cannot. */
export function unsupportedReason(formatter: Formatter, languageId: string): string | undefined {
  if (formatter === "fprettify" && isFixedForm(languageId)) {
    return "fprettify formats free-form Fortran only; use findent for fixed-form files";
  }
  return undefined;
}

/**
 * The whole lines a selection covers, as [first, last] (0-based, inclusive).
 * A selection that ends at the start of a line, after covering earlier
 * lines, does not include that line.
 */
export function selectedLines(
  startLine: number,
  endLine: number,
  endCharacter: number,
): [number, number] {
  const last = endLine > startLine && endCharacter === 0 ? endLine - 1 : endLine;
  return [startLine, last];
}

/** The lines of a formatter's output, without a final line terminator. */
export function outputLines(stdout: string): string[] {
  const text = stdout.replace(/\r\n?/g, "\n");
  const lines = text.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") {
    lines.pop();
  }
  return lines;
}

/** The text to give a formatter for some lines: each ends with a newline. */
export function inputText(lines: readonly string[]): string {
  return lines.map((l) => `${l}\n`).join("");
}

/**
 * The smallest replacement that turns `before` into `after`: the text from
 * offset `start` up to `end` of `before` is replaced by `text`. Undefined
 * when nothing changes. Text the formatter left alone is not touched, so
 * the cursor, folding and markers there stay put.
 */
export function textDiff(
  before: string,
  after: string,
): { start: number; end: number; text: string } | undefined {
  if (before === after) {
    return undefined;
  }
  let start = 0;
  const shorter = Math.min(before.length, after.length);
  while (start < shorter && before.charCodeAt(start) === after.charCodeAt(start)) {
    start++;
  }
  let endBefore = before.length;
  let endAfter = after.length;
  while (endBefore > start && endAfter > start && before.charCodeAt(endBefore - 1) === after.charCodeAt(endAfter - 1)) {
    endBefore--;
    endAfter--;
  }
  // not between the halves of a surrogate pair
  if (start > 0 && isHighSurrogate(before.charCodeAt(start - 1))) {
    start--;
  }
  if (endBefore < before.length && isLowSurrogate(before.charCodeAt(endBefore))) {
    endBefore++;
    endAfter++;
  }
  return { start, end: endBefore, text: after.slice(start, endAfter) };
}

function isHighSurrogate(c: number): boolean {
  return c >= 0xd800 && c <= 0xdbff;
}

function isLowSurrogate(c: number): boolean {
  return c >= 0xdc00 && c <= 0xdfff;
}
