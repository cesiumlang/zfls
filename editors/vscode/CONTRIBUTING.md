# Translations and walkthroughs

The extension is in English only, with the hooks for translations and
walkthroughs in place, to be used when someone asks for them.

## Translations

Every string that VS Code shows from `package.json` (setting descriptions,
command titles, the debug type's attributes, ...) is a `%key%` there, whose
English text is in `package.nls.json`. A translation is a file
`package.nls.<language>.json` next to it, with the same keys (`de`, `fr`,
`ja`, `zh-cn`, ...): VS Code picks the one of its display language, and
takes the English text of the keys it lacks.

- After adding a setting or a command, run `python tools/package_nls.py`,
  which moves its strings into `package.nls.json` (CI fails when one is
  left in `package.json`).
- The unit tests check that every key is in `package.nls.json`, and that a
  translation has no key that is not.
- The messages the extension shows while it runs are not translated yet.
  The next step is to write them with `vscode.l10n.t(...)`, add
  `"l10n": "./l10n"` to `package.json`, and generate `l10n/bundle.l10n.json`
  with `npx @vscode/l10n-dev export`; a translation is then
  `l10n/bundle.l10n.<language>.json` too.

## Walkthroughs

`contributes.walkthroughs` in `package.json` is empty. A walkthrough is an
entry there with an `id`, a `title`, a `description` and `steps`, each step
with a `media` file (Markdown or an image, under `media/walkthroughs/`); its
strings go to `package.nls.json` as `walkthrough.<id>.<step>.title` and
`.description` when `tools/package_nls.py` runs.
