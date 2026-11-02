// Plain Node.js tests (no VS Code) of gdb's variables read as Fortran
// (`npm run unit`)

import * as assert from "node:assert/strict";
import { test } from "node:test";
import {
  addressOf,
  arrayPreview,
  arrayType,
  castCommand,
  chunkContext,
  chunkSection,
  chunks,
  derivedTypeName,
  dynamicType,
  element,
  fortranNumber,
  hoverExpressionStart,
  isClassWrapper,
  isHiddenLength,
  isNullPointer,
  isUnallocated,
  pointerTarget,
  shapePreview,
  structPreview,
} from "../../src/fortranDebug";
import { gdbVersion, mergeEnv } from "../../src/gdbAdapter";

test("arrays of gdb's type strings", () => {
  assert.deepEqual(arrayType("real(kind=4) (3)"), { element: "real(kind=4)", allocatable: false, dims: [{ lo: 1, hi: 3 }] });
  assert.deepEqual(arrayType("integer(kind=4) (2:3,-1:1)")?.dims, [
    { lo: 2, hi: 3 },
    { lo: -1, hi: 1 },
  ]);
  const unallocated = arrayType("real(kind=4), allocatable (:)")!;
  assert.equal(unallocated.allocatable, true);
  assert.equal(unallocated.element, "real(kind=4)");
  assert.ok(isUnallocated(unallocated));
  assert.ok(isUnallocated(arrayType("real(kind=4) (:,:)")!));
  assert.ok(!isUnallocated(arrayType("real(kind=4), allocatable (2,3)")!));
  assert.deepEqual(arrayType("real(kind=8) (0:*)")?.dims, [{ lo: 0 }]);
  assert.deepEqual(arrayType("character*5 (2)")?.dims, [{ lo: 1, hi: 2 }]);
  // scalars
  assert.equal(arrayType("real(kind=4)"), undefined);
  assert.equal(arrayType("Type point"), undefined);
  assert.equal(arrayType("character*8"), undefined);
  assert.equal(arrayType(undefined), undefined);
});

test("elements by their subscripts, columns of arrays", () => {
  const v = { expr: "v", dims: [{ lo: 1, hi: 3 }], fixed: [] };
  assert.deepEqual(element(v, "2"), { name: "(2)", evaluateName: "v(2)", sub: undefined });
  // gdb gives m(2:3,-1:1) as its columns m(:,-1), m(:,0), m(:,1)
  const m = { expr: "m", dims: [{ lo: 2, hi: 3 }, { lo: -1, hi: 1 }], fixed: [] };
  const column = element(m, "-1");
  assert.equal(column.name, "(:,-1)");
  assert.equal(column.evaluateName, "m(:,-1)");
  assert.deepEqual(element(column.sub!, "3"), { name: "(3,-1)", evaluateName: "m(3,-1)", sub: undefined });
  // no expression: names only
  assert.equal(element({ dims: [{ lo: 1, hi: 2 }], fixed: [] }, "1").evaluateName, undefined);
});

test("large arrays in sections", () => {
  assert.deepEqual(chunks(100), []);
  assert.deepEqual(
    chunks(250).map((c) => [c.start, c.count]),
    [
      [0, 100],
      [100, 100],
      [200, 50],
    ],
  );
  // at most 100 sections: of 10000 for a million
  const big = chunks(1_000_000);
  assert.equal(big.length, 100);
  assert.equal(big[0].count, 10000);
  const a = { expr: "a", dims: [{ lo: 0, hi: 999 }], fixed: [] };
  assert.deepEqual(chunkSection(a, { start: 100, count: 100 }), { name: "(100:199)", evaluateName: "a(100:199)" });
  // gdb numbers a section's elements from 1
  const section = chunkContext(a, { start: 100, count: 100 });
  assert.equal(element(section, "1").evaluateName, "a(100)");
  assert.equal(element(section, "100").name, "(199)");
  // a section of a section
  assert.equal(chunkSection(section, { start: 10, count: 5 }).name, "(110:114)");
  // the columns of a matrix of many columns, by their bounds
  const m = { expr: "m", dims: [{ lo: 2, hi: 3 }, { lo: 1, hi: 500 }], fixed: [] };
  assert.equal(chunkSection(m, { start: 200, count: 100 }).evaluateName, "m(:,201:300)");
  const columns = chunkContext(m, { start: 200, count: 100 });
  const column = element(columns, "1");
  assert.equal(column.name, "(:,201)");
  assert.equal(element(column.sub!, "1").evaluateName, "m(2,201)");
});

test("values as Fortran writes them", () => {
  assert.equal(fortranNumber("6", "real(kind=4)"), "6.0");
  assert.equal(fortranNumber("-2", "real(kind=8)"), "-2.0");
  assert.equal(fortranNumber("1.5", "real(kind=4)"), "1.5");
  assert.equal(fortranNumber("inf", "real(kind=4)"), "inf");
  assert.equal(fortranNumber("(1,-2)", "complex(kind=4)"), "(1.0, -2.0)");
  assert.equal(fortranNumber("6", "integer(kind=4)"), "6");
  assert.equal(fortranNumber(".TRUE.", "logical(kind=4)"), ".TRUE.");
  assert.equal(arrayPreview(["1.0", "2.0"], 2), "[1.0, 2.0]");
  assert.equal(arrayPreview(["1", "2", "3", "4", "5", "6", "7"], 1000), "[1, 2, 3, 4, 5, 6, …]");
  assert.equal(shapePreview([{ lo: 2, hi: 3 }, { lo: -1, hi: 1 }]), "[2×3]");
  assert.equal(shapePreview([{ lo: 1 }]), "[?]");
  assert.equal(structPreview("point", [{ name: "x", value: "9.0" }, { name: "id", value: "7" }]), "point(x=9.0, id=7)");
  assert.equal(
    structPreview("t", ["a", "b", "c", "d", "e"].map((name) => ({ name, value: "1" }))),
    "t(a=1, b=1, c=1, d=1, …)",
  );
  assert.equal(derivedTypeName("Type point"), "point");
  assert.equal(derivedTypeName("Type __class_grid_Point_t"), undefined);
  assert.equal(derivedTypeName("real(kind=4)"), undefined);
  assert.equal(pointerTarget("PTR TO -> ( character*7 )"), "character*7");
  assert.equal(pointerTarget("real(kind=4)"), undefined);
  assert.ok(isNullPointer("0x0"));
  assert.ok(!isNullPointer("0x7ff63be140c0 <tg>"));
});

test("gfortran's hidden lengths of CHARACTER arguments", () => {
  const args = [
    { name: "s", type: "character*6" },
    { name: "n", type: "integer(kind=4)" },
    { name: "_s", type: "integer(kind=8)" },
    { name: "_n", type: "integer(kind=8)" },
  ];
  assert.ok(isHiddenLength("_s", args));
  assert.ok(!isHiddenLength("_n", args));
  assert.ok(!isHiddenLength("s", args));
});

test("the dynamic type of a polymorphic object", () => {
  assert.ok(isClassWrapper("Type __class_grid_Point_t"));
  assert.ok(!isClassWrapper("Type point"));
  assert.deepEqual(dynamicType("0x7ff63be14040 <__grid_MOD___vtab_grid_Tagged>"), { module: "grid", name: "tagged" });
  assert.deepEqual(dynamicType("0x1 <__my_mod_MOD___vtab_my_mod_My_type>"), { module: "my_mod", name: "my_type" });
  // intrinsic types, and those of no module
  assert.equal(dynamicType("0x1 <__vtab_INTEGER_4_>"), undefined);
  assert.equal(dynamicType("0x0"), undefined);
  assert.equal(addressOf("0x7ff6c1d640c0 <tg>"), "0x7ff6c1d640c0");
  assert.equal(
    castCommand("zfls_1", "0x10", { module: "grid", name: "tagged" }),
    'python gdb.set_convenience_variable("zfls_1", gdb.Value(0x10).cast(gdb.lookup_type("grid::tagged").pointer()))',
  );
});

test("the expression under the mouse", () => {
  const line = "  y = p%x + a(i, 2)%w(3) + q % z";
  assert.equal(hoverExpressionStart(line, line.indexOf("x +")), line.indexOf("p%x"));
  assert.equal(hoverExpressionStart(line, line.indexOf("w(3)")), line.indexOf("a(i, 2)"));
  assert.equal(hoverExpressionStart(line, line.indexOf("z")), line.indexOf("q % z"));
  assert.equal(hoverExpressionStart(line, line.indexOf("y")), line.indexOf("y"));
  // no name before the %
  assert.equal(hoverExpressionStart("  (1)%x", 6), 6);
});

test("gdb's version, the program's environment", () => {
  assert.deepEqual(gdbVersion("GNU gdb (GDB) 17.2\nCopyright"), [17, 2]);
  assert.deepEqual(gdbVersion("GNU gdb (Ubuntu 15.0.50.20240403-0ubuntu1) 15.0.50.20240403-git"), [15, 0]);
  assert.deepEqual(gdbVersion("GNU gdb (GDB; SUSE Linux Enterprise 15) 12.1"), [12, 1]);
  assert.deepEqual(gdbVersion("GNU gdb (Fedora Linux) 14.1-2.fc39\r\nCopyright"), [14, 1]);
  assert.equal(gdbVersion("lldb version 21"), undefined);
  const env = mergeEnv({ A: "1", B: "2" }, { B: "3", C: 4 });
  assert.deepEqual(env, { A: "1", B: "3", C: "4" });
});
