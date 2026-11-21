// Plain Node.js tests (no VS Code) of the language the extension gives a
// document on zfls's `zfls/sourceForm` (#632): `npm run unit`. When the
// server sends it is tested in Zig (tests/issues/source_form.zig).

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { fileAssociations, languageToSet } from "../../src/sourceForm";

const fixed = { uri: "file:///w/a.fpp", form: "fixed", languageId: "FortranFixedForm" } as const;
const free = { uri: "file:///w/b.fpp", form: "free", languageId: "FortranFreeForm" } as const;

test("a .fpp opened as free form that zfls reads as fixed form gets the fixed form's language", () => {
  assert.equal(languageToSet("FortranFreeForm", fixed), "FortranFixedForm");
  assert.equal(languageToSet("FortranFixedForm", free), "FortranFreeForm");
});

test("a document of the form's language already, or of no form's, is left as it is", () => {
  // the didOpen that follows the switch: no other switch
  assert.equal(languageToSet("FortranFixedForm", fixed), null);
  assert.equal(languageToSet("FortranFreeForm", free), null);
  assert.equal(languageToSet("FortranNamelist", fixed), null);
  assert.equal(languageToSet("plaintext", fixed), null);
  assert.equal(languageToSet("FortranFreeForm", { ...fixed, languageId: "c" }), null);
});

test("files.associations goes to zfls as it is, but for languages that are not strings (#686)", () => {
  const value = { "*.fpp": "FortranFixedForm", "**/gen/*.fpp": "FortranFreeForm", "*.md": "markdown", "*.x": 3, "*.y": null };
  assert.deepEqual(fileAssociations(value), {
    "*.fpp": "FortranFixedForm",
    "**/gen/*.fpp": "FortranFreeForm",
    "*.md": "markdown",
  });
  assert.deepEqual(fileAssociations(undefined), {});
  assert.deepEqual(fileAssociations(["*.fpp"]), {});
});
