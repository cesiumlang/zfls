// What `${...}` variables in settings stand for in this workspace; tools.ts
// expands them (it has no VS Code import, for the unit tests).

import * as vscode from "vscode";
import { VariableContext } from "./tools";

/** The variables of a setting of `folder` (undefined: files outside any
 * workspace folder, where `${workspaceFolder}` stays as it is) */
export function folderVariables(folder: vscode.WorkspaceFolder | undefined): VariableContext {
  const folders: Record<string, string> = {};
  for (const f of vscode.workspace.workspaceFolders ?? []) {
    folders[f.name] = f.uri.fsPath;
  }
  return { workspaceFolder: folder?.uri.fsPath, workspaceFolders: folders };
}

/** The variables of a tool run on a document: its workspace folder, or the
 * first one, and its file */
export function documentVariables(uri: vscode.Uri): VariableContext {
  const folder = vscode.workspace.getWorkspaceFolder(uri) ?? vscode.workspace.workspaceFolders?.[0];
  return {
    ...folderVariables(folder),
    file: uri.scheme === "file" ? uri.fsPath : undefined,
  };
}
