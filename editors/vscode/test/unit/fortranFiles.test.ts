// The file watcher's glob follows zfls.includeSuffixes and ppSuffixes (#788).

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { FORTRAN_FILES, fortranFiles } from "../../src/tools";

test("the watcher glob adds the extra suffixes, in both cases", () => {
  assert.equal(fortranFiles([]), FORTRAN_FILES);
  const glob = fortranFiles([".inc", "Fh", " *.Tpl "]);
  assert.ok(glob.startsWith("*.{f90,"));
  for (const name of ["inc", "INC", "Fh", "fh", "FH", "Tpl", "tpl", "TPL"]) {
    assert.ok(glob.includes(`,${name}`) || glob.includes(`,${name},`), name);
  }
  assert.ok(glob.endsWith("}"));
});

test("a suffix with glob characters cannot break the glob", () => {
  assert.equal(fortranFiles(["{x,*}", ".", ""]), fortranFiles(["x"]));
});
