// Tests of the indentation rules of language-configuration.json (free and
// fixed form) with plain Node.js (no VS Code), applied as VS Code applies
// them: `new RegExp(pattern, flags)` on one line.
//   npm run unit
// increaseIndentPattern: the line after this one is indented.
// decreaseIndentPattern: this line is outdented as it is typed.

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const root = path.join(__dirname, "..", "..");
const rules = JSON.parse(fs.readFileSync(path.join(root, "language-configuration.json"), "utf8")).indentationRules;
const increase = new RegExp(rules.increaseIndentPattern.pattern, rules.increaseIndentPattern.flags);
const decrease = new RegExp(rules.decreaseIndentPattern.pattern, rules.decreaseIndentPattern.flags);

/** Lines and what they do: `in` indents the next line, `out` outdents
 * itself, `both` does both (a middle statement), `none` neither */
const table: [string, "in" | "out" | "both" | "none"][] = [
  // END statements
  ["end block", "out"],
  ["end associate", "out"],
  ["end procedure", "out"],
  ["end type", "out"],
  ["end type point", "out"],
  ["end interface", "out"],
  ["end where", "out"],
  ["end forall", "out"],
  ["end critical", "out"],
  ["end enum", "out"],
  ["end submodule", "out"],
  ["end team", "out"],
  ["end", "out"],
  ["end ! of the program", "out"],
  ["end select", "out"],
  ["end if", "out"],
  ["endif", "out"],
  ["enddo", "out"],
  ["end do outer", "out"],
  ["end function f", "out"],
  ["end subroutine", "out"],
  ["end module m", "out"],
  ["end program p", "out"],
  ["END BLOCK DATA", "out"],
  ["10    end do", "out"],
  // openers
  ["program p", "in"],
  ["module m", "in"],
  ["MODULE M", "in"],
  ["submodule (a) b", "in"],
  ["submodule (a:b) c", "in"],
  ["block data", "in"],
  ["subroutine s(a, b)", "in"],
  ["function f(x) result(y)", "in"],
  ["integer function f(x)", "in"],
  ["pure function f()", "in"],
  ["recursive subroutine s()", "in"],
  ["module function f()", "in"],
  ["module subroutine s()", "in"],
  ["elemental real(dp) function g(x)", "in"],
  ["character(len=*) function h(x)", "in"],
  ["real*8 function r(x)", "in"],
  ["type(point) function p()", "in"],
  ["impure elemental subroutine e(x)", "in"],
  ["type :: t", "in"],
  ["type t", "in"],
  ["type t(k)", "in"],
  ["type, extends(base) :: t", "in"],
  ["type, public, abstract :: t", "in"],
  ["interface", "in"],
  ["interface operator(+)", "in"],
  ["interface assignment(=)", "in"],
  ["abstract interface", "in"],
  ["enum, bind(c)", "in"],
  ["if (x) then", "in"],
  ["if (x) then ! comment", "in"],
  ["if (f(a(1), b)) then", "in"],
  ["outer: if (x) then", "in"],
  ["  x > 0) then", "in"],
  ["do", "in"],
  ["do i = 1, n", "in"],
  ["do while (x)", "in"],
  ["do concurrent (i=1:n)", "in"],
  ["do 10 i = 1, n", "in"],
  ["lbl: do i=1,3", "in"],
  ["lbl: do", "in"],
  ["block", "in"],
  ["lbl: block", "in"],
  ["associate (a => b%c)", "in"],
  ["lbl: associate (a => b)", "in"],
  ["select case (i)", "in"],
  ["lbl: select case (i)", "in"],
  ["select type (p)", "in"],
  ["select rank (a)", "in"],
  ["where (a > 0)", "in"],
  ["where (a > f(b))", "in"],
  ["forall (i=1:n)", "in"],
  ["critical", "in"],
  ["change team (t)", "in"],
  ["10    do 20 i = 1, n", "in"],
  // middle statements
  ["else", "both"],
  ["else outer", "both"],
  ["else if (x) then", "both"],
  ["elseif (x) then", "both"],
  ["elsewhere", "both"],
  ["else where (b)", "both"],
  ["contains", "both"],
  ["case (1)", "both"],
  ["case (1:3, 5)", "both"],
  ["case default", "both"],
  ["type is (integer)", "both"],
  ["class is (t)", "both"],
  ["class default", "both"],
  ["rank (2)", "both"],
  ["rank (*)", "both"],
  ["rank default", "both"],
  // statements
  ["type(t) :: x", "none"],
  ["type (t), pointer :: p", "none"],
  ["class(*), intent(in) :: v", "none"],
  ["where (a > 0) b = 1", "none"],
  ["where (a > 0) b = f(x)", "none"],
  ["forall (i=1:n) a(i) = 0", "none"],
  ["if (x) return", "none"],
  ["if (f(x)) call g(y)", "none"],
  ["10 continue", "none"],
  ["module procedure foo", "none"],
  ["endpoint = 1", "none"],
  ["end_time = 2", "none"],
  ["end = 3", "none"],
  ["ending(2) = 1", "none"],
  ["x = 1 ! then", "none"],
  ["x = 1 ! else", "none"],
  ["print *, 'or else'", "none"],
  ["print *, 'then'", "none"],
  ["call foo(type)", "none"],
  ["integer :: n", "none"],
  ["real :: do", "none"],
  ["do = 1", "none"],
  ["block = 2", "none"],
  ["doi = 1", "none"],
  ["case_n = 1", "none"],
  ["else_x = 1", "none"],
  ["contains_x = 1", "none"],
  ["call else_branch()", "none"],
  ["function_value = 2", "none"],
  ["interface_count = 3", "none"],
  ["print *, real(n)", "none"],
  ["implicit none", "none"],
  ["use m, only: f", "none"],
  // a fixed-form comment
  ["c     if (x) then", "none"],
  ["C     end do", "none"],
  ["*     do i = 1, n", "none"],
];

for (const [line, expected] of table) {
  test(`indentation: ${line}`, () => {
    const answer = { in: increase.test(line), out: decrease.test(line) };
    const want = { in: expected === "in" || expected === "both", out: expected === "out" || expected === "both" };
    assert.deepEqual(answer, want);
  });
}
