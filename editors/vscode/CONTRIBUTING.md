# Translations and walkthroughs

The extension is in English only, with the hooks for translations in
place, to be used when someone asks for them.

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
- The messages the extension shows while it runs are written with
  `vscode.l10n.t("...")`, with `{0}`, `{1}`, ... for the values put in them;
  each is a whole sentence, never pieces glued together, so that a
  translation can order its words its own way. `python
  tools/l10n_bundle.py` collects them into `l10n/bundle.l10n.json` (each
  message is its own key; CI fails when the bundle is out of date). A
  translation is `l10n/bundle.l10n.<language>.json`, with the same keys.

## Walkthroughs

`contributes.walkthroughs` in `package.json` has the Getting Started
walkthrough (**zfls: Get Started**). Each step has an `id`, a `title`, a
`description` (a sentence or two, and a button: a link to a command) and a
`media` file, a Markdown page under `media/walkthroughs/`. Its strings go
to `package.nls.json` as `walkthrough.<id>.<step>.title` and
`.description` when `tools/package_nls.py` runs; the unit tests check that
each step's page exists and that its buttons run commands of the
extension.
