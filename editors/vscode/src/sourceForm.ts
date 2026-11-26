// The source form zfls detected of a document whose suffix names none
// (`.fpp`), which the extension gives the document as its language (#632):
// zfls decides, the extension applies; and the file associations it decides
// by (#686). No `vscode` import (see test/unit).

/** The parameters of zfls's notification `zfls/sourceForm` */
export interface SourceFormNote {
  uri: string;
  form: "fixed" | "free";
  /** the language of that form */
  languageId: string;
}

/** The extension's languages of the two forms */
export const FORM_LANGUAGES: readonly string[] = ["FortranFreeForm", "FortranFixedForm"];

/** The language to give a document of language `current` on `note`: null
 * to leave it (it has that language, or one of no form, as a namelist) */
export function languageToSet(current: string, note: SourceFormNote): string | null {
  if (!FORM_LANGUAGES.includes(note.languageId) || !FORM_LANGUAGES.includes(current)) {
    return null;
  }
  return current === note.languageId ? null : note.languageId;
}

/** VS Code's `files.associations` (`value`, merged over its scopes) as
 * zfls's `file_associations`: the patterns whose language is a string, as
 * VS Code reads them. zfls matches them against a `.fpp`'s path as VS Code
 * does (#686), all of them, since the longest pattern that matches wins
 * whatever its language. */
export function fileAssociations(value: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return out;
  }
  for (const [pattern, language] of Object.entries(value)) {
    if (typeof language === "string") {
      out[pattern] = language;
    }
  }
  return out;
}
