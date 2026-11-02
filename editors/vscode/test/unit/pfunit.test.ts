// Plain Node.js tests (no VS Code) of reading pFUnit projects (`npm run unit`)

import * as assert from "node:assert/strict";
import { test } from "node:test";
import { parseAddPfunitCtest, parseCtestJson, parsePf, parsePfunitXml, pfunitArgs, resultOf } from "../../src/pfunit";

const PF = `module test_vectors
   use funit
   use vectors
   implicit none
contains

   @test
   subroutine test_norm()
      @assertEqual(5.0, norm([3.0, 4.0]))
   end subroutine test_norm

   ! @test in a comment does not count
   @test(testParameters={[1, 2]})
   subroutine test_cases(this)
      class (MyCase), intent(inout) :: this
   end subroutine test_cases

   @Test
   subroutine Test_Dot
   end subroutine Test_Dot

   subroutine helper()
   end subroutine helper
end module test_vectors
`;

test("a .pf file: its suite (the module's name) and @test procedures", () => {
  const s = parsePf(PF, "test_vectors");
  assert.equal(s.name, "test_vectors_suite");
  assert.equal(s.line, 0);
  assert.deepEqual(
    s.tests.map((t) => [t.name, t.line, t.parameterized]),
    [
      ["test_norm", 6, false],
      ["test_cases", 12, true],
      ["Test_Dot", 17, false],
    ],
  );
});

test("a .pf file: @suite names the suite; without a module, the file does", () => {
  assert.equal(parsePf(`@suite(name='vec_tests')\nmodule m\nend module m\n`, "x").name, "vec_tests");
  assert.equal(parsePf(`@test\nsubroutine t()\nend subroutine t\n`, "loose").name, "loose_suite");
});

test("a .pf file: the tests of a @testCase with parameters are parameterized", () => {
  const s = parsePf(
    `module m\n@testParameter\ntype, extends(AbstractTestParameter) :: P\nend type\n@testCase(testParameters={getParameters()})\n` +
      `type, extends(ParameterizedTestCase) :: C\nend type\ncontains\n@test\nsubroutine t(this)\nend subroutine t\nend module m\n`,
    "m",
  );
  assert.deepEqual(s.tests.map((t) => [t.name, t.parameterized]), [["t", true]]);
});

test("add_pfunit_ctest: the test's name and its .pf files, with set() variables", () => {
  const cmake = `
set(pf_files test_a.pf \${CMAKE_CURRENT_SOURCE_DIR}/sub/test_b.pf)
add_pfunit_ctest (vector_tests
  TEST_SOURCES \${pf_files} "test c.pf"
  LINK_LIBRARIES vectors  # not a test
  OTHER_SOURCES helper.F90
  )
# add_pfunit_ctest(commented TEST_SOURCES x.pf)
add_pfunit_ctest(other TEST_SOURCES other.pf MAX_PES 4)
`;
  assert.deepEqual(parseAddPfunitCtest(cmake), [
    { name: "vector_tests", sources: ["test_a.pf", "sub/test_b.pf", "test c.pf"] },
    { name: "other", sources: ["other.pf"] },
  ]);
});

test("ctest --show-only=json-v1: each test's command and working directory", () => {
  const json = JSON.stringify({
    kind: "ctestInfo",
    tests: [
      {
        name: "vector_tests",
        command: ["C:/p/build/tests/vector_tests.exe"],
        properties: [{ name: "WORKING_DIRECTORY", value: "C:/p/build/tests" }],
      },
      { name: "plain", command: ["/b/plain", "--flag"] },
      { name: "no-command" },
    ],
  });
  const m = parseCtestJson(`Test project C:/p/build\n${json}`);
  assert.deepEqual(m.get("vector_tests"), {
    command: ["C:/p/build/tests/vector_tests.exe"],
    workingDirectory: "C:/p/build/tests",
  });
  assert.deepEqual(m.get("plain"), { command: ["/b/plain", "--flag"], workingDirectory: undefined });
  assert.equal(m.size, 2);
  assert.equal(parseCtestJson("not json").size, 0);
});

test("pFUnit's XML results (4.19 on): a testsuite each, failures with their place", () => {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="test_vectors_suite" errors="1" failures="1" tests="3" time=".0020">
<testcase name="test_norm" time=".0010">
<failure message="Location: [test_vectors.pf:8], expected: &lt;5.000000&gt; but found: &lt;4.000000&gt;" />
</testcase>
<testcase name="test_dot" time=".0005"/>
<testcase name="test_crash" time="0.0">
<error message="Location: [&lt;unknown location&gt;], boom" />
</testcase>
</testsuite>
</testsuites>
`;
  assert.deepEqual(parsePfunitXml(xml), [
    {
      name: "test_vectors_suite.test_norm",
      status: "failed",
      time: 0.001,
      messages: [{ text: "expected: <5.000000> but found: <4.000000>", file: "test_vectors.pf", line: 8 }],
    },
    { name: "test_vectors_suite.test_dot", status: "passed", time: 0.0005, messages: [] },
    { name: "test_vectors_suite.test_crash", status: "errored", time: 0, messages: [{ text: "boom", file: undefined, line: undefined }] },
  ]);
});

test("pFUnit's XML results before 4.19: full names in one testsuite", () => {
  const xml = `<testsuites><testsuite name="pFUnit" errors="0" failures="0" tests="1" time="0">
<testcase name="s_suite.t1"/>
</testsuite></testsuites>`;
  assert.deepEqual(parsePfunitXml(xml).map((r) => [r.name, r.status]), [["s_suite.t1", "passed"]]);
});

test("a result is a test's, or one of its parameters'", () => {
  assert.ok(resultOf("vec_suite.test_norm", "vec_suite", "test_norm"));
  assert.ok(resultOf("VEC_suite.Test_Norm", "vec_suite", "test_norm"));
  assert.ok(resultOf("vec_suite.test_cases[1]", "vec_suite", "test_cases"));
  assert.ok(resultOf("vec_suite.test_cases(i=1)", "vec_suite", "test_cases"));
  assert.ok(!resultOf("vec_suite.test_norm2", "vec_suite", "test_norm"));
  assert.ok(!resultOf("other_suite.test_norm", "vec_suite", "test_norm"));
});

test("the program's arguments: CTest's but --verbose, XML into a file, one test filtered", () => {
  assert.deepEqual(pfunitArgs(["--verbose"], "r.xml", undefined, []), ["-x", "-o", "r.xml"]);
  assert.deepEqual(pfunitArgs(["-n", "4"], "r.xml", "s_suite.t", ["--shuffle"]), [
    "-n",
    "4",
    "-x",
    "-o",
    "r.xml",
    "-f",
    "s_suite.t",
    "--shuffle",
  ]);
});

test("pFUnit 4.20's XML of a real run: failures over several lines", () => {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="test_more_suite" errors="0" failures="1" tests="2" time=".0001">
<testcase name="test_ok" time=".0000"/>
<testcase name="test_two" time=".0001">
<failure message="Location: [test_more.pf:14], two is not three
AssertEqual failure:
      Expected: [2]
        Actual: [3]
    Difference: [1] "/>
</testcase>
</testsuite>
</testsuites>
`;
  const r = parsePfunitXml(xml);
  assert.deepEqual(r.map((x) => [x.name, x.status]), [
    ["test_more_suite.test_ok", "passed"],
    ["test_more_suite.test_two", "failed"],
  ]);
  assert.deepEqual(r[1].messages, [
    {
      text: "two is not three\nAssertEqual failure:\n      Expected: [2]\n        Actual: [3]\n    Difference: [1]",
      file: "test_more.pf",
      line: 14,
    },
  ]);
});
