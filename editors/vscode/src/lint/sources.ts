// What the linter reads from Fortran source text: the modules a file
// defines and uses, and its INCLUDE lines. No VS Code here (see test/unit).

export interface ModuleScan {
  /** Modules (not submodules) defined in the file, in lower case */
  defines: string[];
  /** Modules used by the file or extended by its submodules, in lower case,
   * without intrinsic modules and without those the file defines itself */
  uses: string[];
}

const MODULE = /^\s*module\s+(\w+)\s*$/i;
const SUBMODULE = /^\s*submodule\s*\(\s*(\w+)/i;
const USE = /^\s*use\b\s*(?:,\s*(intrinsic|non_intrinsic)\s*)?(?:::)?\s*(\w+)/i;
/** Modules every compiler provides; a plain `use iso_c_binding` (without
 * `, intrinsic`) still means these */
const INTRINSIC = new Set([
  "iso_fortran_env", "iso_c_binding", "ieee_arithmetic", "ieee_exceptions", "ieee_features",
  "omp_lib", "omp_lib_kinds", "openacc",
]);

/** The text of a line without a trailing `!` comment (quotes are not
 * tracked: the statements looked for here hold no strings) */
function code(line: string): string {
  const bang = line.indexOf("!");
  return bang < 0 ? line : line.slice(0, bang);
}

export function scanModules(text: string): ModuleScan {
  const defines = new Set<string>();
  const uses = new Set<string>();
  for (const raw of text.split(/\r?\n/)) {
    const line = code(raw);
    const mod = MODULE.exec(line);
    if (mod && mod[1].toLowerCase() !== "procedure") {
      defines.add(mod[1].toLowerCase());
      continue;
    }
    const sub = SUBMODULE.exec(line);
    if (sub) {
      uses.add(sub[1].toLowerCase());
      continue;
    }
    const use = USE.exec(line);
    if (use && use[1]?.toLowerCase() !== "intrinsic" && !INTRINSIC.has(use[2].toLowerCase())) {
      uses.add(use[2].toLowerCase());
    }
  }
  return { defines: [...defines], uses: [...uses].filter((u) => !defines.has(u)) };
}

export interface IncludeLine {
  /** 0-based */
  line: number;
  /** The file name as written */
  name: string;
  /** 0-based columns of the statement, without leading blanks */
  start: number;
  end: number;
}

const FORTRAN_INCLUDE = /^(\s*)(include\s*(['"])(.+?)\3)/i;
const CPP_INCLUDE = /^(\s*)(#\s*include\s*[<"](.+?)[>"])/;

/** The INCLUDE lines and `#include` directives of a file */
export function findIncludes(text: string): IncludeLine[] {
  const result: IncludeLine[] = [];
  text.split(/\r?\n/).forEach((line, i) => {
    const f = FORTRAN_INCLUDE.exec(line);
    if (f) {
      result.push({ line: i, name: f[4], start: f[1].length, end: f[1].length + f[2].length });
      return;
    }
    const c = CPP_INCLUDE.exec(line);
    if (c) {
      result.push({ line: i, name: c[3], start: c[1].length, end: c[1].length + c[2].length });
    }
  });
  return result;
}
