// The launch configuration a new launch.json starts with. It is provided
// only here: package.json has no initialConfigurations, which VS Code would
// add a second time (type import only, so that a unit test can load it).

import type * as vscode from "vscode";

export function initialConfiguration(): vscode.DebugConfiguration {
  return {
    type: "fortran",
    request: "launch",
    name: "Debug Fortran program",
    program: "${workspaceFolder}/a.out",
    args: [],
    cwd: "${workspaceFolder}",
  };
}
