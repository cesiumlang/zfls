// Tests of the Fortran grammar with VS Code's tokenizer (test/unit/tokenize.ts,
// no VS Code): the prefixes of a procedure, Fortran 2023's SIMPLE among them
// (#727).
//   npm run unit

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { scopesOf, tokenize } from "./tokenize";

const FREE = "source.fortran.free";

const has = (scopes: string[], scope: string) => scopes.some((s) => s.startsWith(scope));

test("SIMPLE, NON_RECURSIVE and ELEMENTAL are procedure prefixes", async () => {
  const lines = await tokenize(
    [
      "module m",
      "contains",
      "  simple function twice(x) result(y)",
      "    real, intent(in) :: x",
      "    real :: y",
      "    y = 2*x",
      "  end function twice",
      "  simple elemental subroutine inc(k)",
      "    integer, intent(inout) :: k",
      "    k = k + 1",
      "  end subroutine inc",
      "  non_recursive subroutine once()",
      "  end subroutine once",
      "end module m",
    ].join("\n"),
    FREE,
  );
  for (const line of [2, 7]) {
    const simple = scopesOf(lines[line], "simple");
    assert.ok(has(simple, "storage.modifier.simple"), `line ${line + 1}: ${simple.join(" ")}`);
    assert.ok(!has(simple, "invalid."), `line ${line + 1}: ${simple.join(" ")}`);
  }
  assert.ok(has(scopesOf(lines[7], "elemental"), "storage.modifier.elemental"));
  assert.ok(has(scopesOf(lines[11], "non_recursive"), "storage.modifier.non_recursive"));
});
