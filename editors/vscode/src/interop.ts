// Fortran and C (BIND(C), hansec #115): go to definition of a BIND(C)
// procedure adds its declarations from the C language server (clangd, or
// Microsoft's C/C++, through VS Code's workspace symbols), and find
// references the C server's references of them; in a C or C++ file, go to
// definition and find references add the Fortran procedures of the name
// and their references, which zfls gives (`zfls/bindCTargets`,
// `zfls/bindCReferences`). zfls parses no C. The pure parts; extension.ts
// registers them. No `vscode` import (see test/unit).

/** The languages of C files whose definitions zfls adds to */
export const C_LANGUAGES = ["c", "cpp", "cuda-cpp"];

const C_EXTENSIONS = new Set([".h", ".hh", ".hpp", ".hxx", ".c", ".cc", ".cpp", ".cxx", ".cu", ".cuh"]);

/** Whether a path is a C (or C++, or CUDA) file */
export function isCFile(file: string): boolean {
  const dot = file.lastIndexOf(".");
  return dot >= 0 && C_EXTENSIONS.has(file.slice(dot).toLowerCase());
}

/** The answer of `zfls/bindC` */
export interface BindC {
  name: string;
  cName: string;
}

/** A location by file and line (and column, for references), for dropping
 * the same place found twice (by zfls's search and by the C language
 * server) */
export interface Place {
  uri: string;
  line: number;
  character?: number;
}

/** `items` without those of a place already seen, in order */
export function uniqueByPlace<T>(items: readonly T[], placeOf: (item: T) => Place): T[] {
  const seen = new Set<string>();
  return items.filter((item) => {
    const p = placeOf(item);
    const key = `${p.uri}\u0000${p.line}\u0000${p.character ?? ""}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

/** The C identifier at `character` of `line`, or undefined */
export function identifierAt(line: string, character: number): string | undefined {
  let s = Math.min(character, line.length);
  let e = s;
  while (s > 0 && /\w/.test(line[s - 1])) s--;
  while (e < line.length && /\w/.test(line[e])) e++;
  const word = line.slice(s, e);
  return /^[A-Za-z_]\w*$/.test(word) ? word : undefined;
}
