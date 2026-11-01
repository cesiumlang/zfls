// The groups of a namelist file (`.nml`) and the variables they set, for
// its outline (Modern Fortran #1296). No `vscode` import (see test/unit).

export interface NamelistVariable {
  name: string;
  line: number;
  column: number;
}

export interface NamelistGroup {
  name: string;
  /** the line of `&name` */
  line: number;
  column: number;
  /** the line of the `/` (or `&end`) that ends it; the last line when none */
  endLine: number;
  variables: NamelistVariable[];
}

const GROUP_START = /^(\s*)[&$](?![eE][nN][dD]\b)([A-Za-z]\w*)/;
const GROUP_END = /^\s*[&$][eE][nN][dD]\b/;
const VARIABLE = /\b([A-Za-z]\w*(?:\s*%\s*[A-Za-z]\w*)*)\s*(?:\([^)=]*\))?\s*=/g;

/** The line without its strings (blanked, so columns stay) and comment */
function code(line: string): string {
  let out = "";
  let quote = "";
  for (const c of line) {
    if (quote) {
      out += " ";
      if (c === quote) {
        quote = "";
      }
    } else if (c === "'" || c === '"') {
      quote = c;
      out += " ";
    } else if (c === "!") {
      break;
    } else {
      out += c;
    }
  }
  return out;
}

export function namelistGroups(lines: readonly string[]): NamelistGroup[] {
  const groups: NamelistGroup[] = [];
  let group: NamelistGroup | undefined;
  lines.forEach((raw, ln) => {
    let text = code(raw);
    let from = 0;
    if (!group) {
      const m = GROUP_START.exec(text);
      if (!m) {
        return;
      }
      group = { name: m[2], line: ln, column: m[1].length + 1, endLine: lines.length - 1, variables: [] };
      groups.push(group);
      from = m[0].length;
    }
    // the group ends at `/` or `&end`
    let end = text.indexOf("/", from);
    if (GROUP_END.test(text)) {
      end = 0;
    }
    if (end >= 0) {
      text = text.slice(0, end);
    }
    VARIABLE.lastIndex = from;
    for (let m = VARIABLE.exec(text); m; m = VARIABLE.exec(text)) {
      group.variables.push({ name: m[1].replace(/\s+/g, ""), line: ln, column: m.index });
    }
    if (end >= 0) {
      group.endLine = ln;
      group = undefined;
    }
  });
  return groups;
}
