// Tests of the Fortran grammar with VS Code's tokenizer (test/unit/tokenize.ts,
// no VS Code): a type keyword starts a type declaration only where a
// statement starts (#258); elsewhere it is the intrinsic function or a
// variable.
//   npm run unit

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { scopesOf, Token, tokenize } from "./tokenize";

const FREE = "source.fortran.free";
const FIXED = "source.fortran.fixed";

/** The source in free form, or in fixed form: from column 7, or with its
 * label in columns 1 to 5 */
function inForm(lines: string[], scope: string): string {
  if (scope === FREE) {
    return lines.join("\n");
  }
  return lines
    .map((l) => {
      const label = /^(\d+)\s+(.*)$/.exec(l.trim());
      return label ? label[1].padStart(5) + " " + label[2] : "      " + l.trim();
    })
    .join("\n");
}

const has = (scopes: string[], scope: string) => scopes.some((s) => s.startsWith(scope));

function noInvalid(lines: Token[][]): void {
  for (const [i, line] of lines.entries()) {
    for (const t of line) {
      assert.ok(!has(t.scopes, "invalid."), `line ${i + 1}: ${JSON.stringify(t.text)} is ${t.scopes.join(" ")}`);
    }
  }
}

for (const scope of [FREE, FIXED]) {
  test(`${scope}: a type keyword as a function in an expression`, async () => {
    const lines = await tokenize(
      inForm(
        [
          "program p",
          "  integer :: n = 2",
          "  real :: x, a = 1.5",
          "  print *, real(n), 'text'",
          "  x = real(a) * 2",
          "  write (*, *) real(a)",
          "end program p",
        ],
        scope,
      ),
      scope,
    );
    for (const line of [3, 4, 5]) {
      const real = scopesOf(lines[line], "real");
      assert.ok(has(real, "support.function.intrinsic"), `line ${line + 1}: ${real.join(" ")}`);
      assert.ok(!has(real, "meta.specification.type"), `line ${line + 1}: ${real.join(" ")}`);
    }
    assert.ok(has(scopesOf(lines[3], "text"), "string.quoted.single"));
    assert.ok(has(scopesOf(lines[4], "*"), "keyword.operator"));
    assert.ok(has(scopesOf(lines[4], "2"), "constant.numeric"));
    noInvalid(lines);
  });

  test(`${scope}: a variable named like a type keyword, assigned a string`, async () => {
    const lines = await tokenize(
      inForm(
        [
          "subroutine sub()",
          "    implicit none",
          "    character :: type(5)",
          "    integer :: i",
          "    i = 1",
          "    type(i) = 'a'",
          "    call foo(type)",
          "    print *, 'still a string?'",
          "end subroutine",
        ],
        scope,
      ),
      scope,
    );
    assert.ok(!has(scopesOf(lines[5], "type"), "storage.type"));
    assert.ok(has(scopesOf(lines[5], "a"), "string.quoted.single"));
    assert.ok(has(scopesOf(lines[6], "call"), "keyword.control.call"));
    assert.ok(!has(scopesOf(lines[6], "call"), "string"));
    assert.ok(has(scopesOf(lines[7], "still a string?"), "string.quoted.single"));
    assert.ok(!has(scopesOf(lines[8], "end subroutine"), "string"));
    noInvalid(lines);
  });

  test(`${scope}: declarations stay declarations`, async () => {
    const lines = await tokenize(
      inForm(
        [
          "module m",
          "  implicit real (a-h), integer (i-n)",
          "  real(dp) :: x",
          "  real y",
          "  type(t), pointer :: p",
          "  class(*), allocatable :: v",
          "  character(len=*), parameter :: s = 'abc'",
          "contains",
          "  integer function f()",
          "    f = 1",
          "  end function f",
          "  subroutine g(v)",
          "    class(*), intent(in) :: v",
          "10  integer i",
          "    i = 1; real :: q",
          "  end subroutine g",
          "end module m",
        ],
        scope,
      ),
      scope,
    );
    const types: [number, string, string][] = [
      [1, "real", "storage.type.real"],
      [1, "integer", "storage.type.integer"],
      [2, "real", "storage.type.real"],
      [3, "real", "storage.type.real"],
      [4, "type", "storage.type.type"],
      [5, "class", "storage.type.class"],
      [6, "character", "storage.type.character"],
      [8, "integer", "storage.type.integer"],
      [12, "class", "storage.type.class"],
      [13, "integer", "storage.type.integer"],
      [14, "real", "storage.type.real"],
    ];
    for (const [line, word, want] of types) {
      const scopes = scopesOf(lines[line], word);
      assert.ok(has(scopes, want), `line ${line + 1} ${word}: ${scopes.join(" ")}`);
    }
    for (const line of [2, 3, 4, 5, 6, 12, 13, 14]) {
      const name = lines[line].find((t) => has(t.scopes, "meta.name-list"));
      assert.ok(name, `line ${line + 1}: no declared names`);
    }
    assert.ok(has(scopesOf(lines[8], "function"), "keyword.other.function"));
    assert.ok(has(scopesOf(lines[6], "abc"), "string.quoted.single"));
    noInvalid(lines);
  });

  test(`${scope}: type-specs and type-keyword functions inside statements`, async () => {
    const lines = await tokenize(
      inForm(
        [
          "subroutine s(c, y, n, z)",
          "    if (c) x = real(y)",
          "    y = real(n, dp) + 1",
          "    allocate (real(dp) :: z)",
          "    k = [integer :: 1, 2]",
          "    real(1) = 2.0",
          "    type(i)%a = 'b'",
          "end subroutine s",
        ],
        scope,
      ),
      scope,
    );
    assert.ok(has(scopesOf(lines[1], "real"), "support.function.intrinsic"));
    assert.ok(has(scopesOf(lines[2], "real"), "support.function.intrinsic"));
    assert.ok(has(scopesOf(lines[2], "+"), "keyword.operator"));
    assert.ok(has(scopesOf(lines[3], "real"), "storage.type.real"));
    assert.ok(has(scopesOf(lines[4], "integer"), "storage.type.integer"));
    for (const line of [5, 6]) {
      for (const t of lines[line]) {
        assert.ok(!has(t.scopes, "meta.specification.type"), `line ${line + 1}: ${t.text} ${t.scopes.join(" ")}`);
      }
    }
    assert.ok(has(scopesOf(lines[6], "b"), "string.quoted.single"));
    assert.ok(has(scopesOf(lines[7], "end subroutine"), "keyword.other.endsubroutine"));
    noInvalid(lines);
  });
}
