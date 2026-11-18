// A stand-in for the `vscode` module in the unit tests, so that they can
// load modules that read settings (src/options.ts): the `unit` script of
// package.json bundles it in place of `vscode`. It has what those modules
// use, no more: settings are read from `settings`, by full name
// ("zfls.linter.extraArgs"), for every folder and language alike.

/** The settings in effect: set and clear them in a test */
export const settings: Record<string, unknown> = {};

export const workspace = {
  workspaceFolders: [] as { name: string; uri: { fsPath: string } }[],
  getConfiguration(section: string) {
    return {
      get<T>(key: string, fallback?: T): T | undefined {
        const value = settings[`${section}.${key}`];
        return value === undefined ? fallback : (value as T);
      },
    };
  },
};
