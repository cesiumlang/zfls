// The files a zfls server takes, as a document selector pattern. The root
// is the base of a relative pattern, not text of a glob: a root with glob
// characters (`proj[1]`, `a{b}`) matches nothing as a string pattern.

/** A folder's server takes the files under it; a directory's server only
 * the files directly in it. `rootUri` is the root's URI as a string. */
export function servedPattern(rootUri: string, folder: boolean): { baseUri: string; pattern: string } {
  return { baseUri: rootUri, pattern: folder ? "**/*" : "*" };
}
