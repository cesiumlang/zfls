// Plain Node.js tests (no VS Code) of the names of module variables for the
// debuggers (`npm run unit`)

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { byModule, expression, formsFor, isErrorValue, tryOrder } from "../../src/moduleVariables";

test("a module variable's name for each compiler and debugger", () => {
  assert.equal(expression("gdb", "Grid", "Cells"), "grid::cells");
  assert.equal(expression("gfortran", "Grid", "Cells"), "__grid_MOD_cells");
  assert.equal(expression("flang", "Grid", "Cells"), "_QMgridEcells");
  assert.equal(expression("intel", "Grid", "Cells"), "GRID_mp_CELLS");
});

test("the forms each debug type tries first", () => {
  assert.equal(formsFor("cppdbg")[0], "gdb");
  assert.equal(formsFor("gdb")[0], "gdb");
  assert.equal(formsFor("lldb")[0], "gfortran");
  assert.equal(formsFor("cppvsdbg")[0], "intel");
  assert.equal(formsFor("other").length, 4);
  // the form that worked in the session first, the others after
  assert.deepEqual(tryOrder("cppdbg", "gfortran"), ["gfortran", "gdb", "flang", "intel"]);
  assert.deepEqual(tryOrder("lldb", "intel"), formsFor("lldb"));
});

test("a debugger's error in place of a value", () => {
  assert.ok(isErrorValue('No symbol "grid" in current context.'));
  assert.ok(isErrorValue("<error: use of undeclared identifier 'x'>"));
  assert.ok(isErrorValue("identifier \"GRID_mp_CELLS\" is undefined"));
  // gdb, on gfortran's symbol of a module variable
  assert.ok(isErrorValue("'__grid_MOD_cells' has unknown type; cast it to its declared type"));
  assert.ok(!isErrorValue("(1.5, 2, 3)"));
  assert.ok(!isErrorValue("0"));
});

test("variables grouped by module, in order", () => {
  const v = (module: string, name: string) => ({ module, name, local: name, type: "REAL" });
  const groups = byModule([v("grid", "cells"), v("consts", "scale"), v("GRID", "secret")]);
  assert.deepEqual(
    groups.map((g) => [g.module, g.vars.map((x) => x.name)]),
    [
      ["grid", ["cells", "secret"]],
      ["consts", ["scale"]],
    ],
  );
});
