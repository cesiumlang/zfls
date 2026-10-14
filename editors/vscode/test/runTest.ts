// Runs test/suite.ts inside a downloaded VS Code with only this extension,
// on the zfls fixture workspace tests/fortran. ZFLS_PATH, when set, names
// the zfls to test (otherwise bin/zfls, then the PATH).

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runTests } from "@vscode/test-electron";

async function main(): Promise<void> {
  // set in VS Code's own terminals; the VS Code under test would then start
  // as plain Node.js
  delete process.env.ELECTRON_RUN_AS_NODE;
  // ZFLS_EXTENSION_PATH: an unpacked VSIX (its `extension` directory), to
  // test the packaged extension with its bundled zfls
  const extensionDevelopmentPath = process.env.ZFLS_EXTENSION_PATH
    ? path.resolve(process.env.ZFLS_EXTENSION_PATH)
    : path.resolve(__dirname, "..");
  const extensionTestsPath = path.resolve(__dirname, "suite.js");
  const workspace = path.resolve(__dirname, "..", "..", "..", "tests", "fortran");
  await runTests({
    extensionDevelopmentPath,
    extensionTestsPath,
    // fresh settings each run
    launchArgs: [
      workspace,
      "--disable-extensions",
      "--disable-workspace-trust",
      `--user-data-dir=${fs.mkdtempSync(path.join(os.tmpdir(), "zfls-vscode-"))}`,
    ],
    extensionTestsEnv: { ZFLS_PATH: process.env.ZFLS_PATH ?? "" },
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
