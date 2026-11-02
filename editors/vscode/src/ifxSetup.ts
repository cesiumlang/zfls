// zfls: Set Up ifx (Windows x64): Intel's ifx without Intel's installer
// or Visual Studio, by `zfls setup-ifx` (src/ifxsetup.zig) on the offline
// installer the user downloaded from Intel. Shows Intel's license from the
// installer and asks for its acceptance first, as Intel's installer would;
// then offers to use the ifx for Run Fortran File and fpm.

import { execFile } from "node:child_process";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";

/** Intel's page of the Fortran compiler's downloads (Windows, offline installer) */
export const INTEL_DOWNLOAD_URL =
  "https://www.intel.com/content/www/us/en/developer/tools/oneapi/fortran-compiler-download.html";

interface SetupResult {
  ifx: string;
  version: string;
  dest: string;
  files: number;
}

export function registerIfxSetup(
  context: vscode.ExtensionContext,
  log: vscode.LogOutputChannel,
  zfls: () => string | undefined,
): void {
  context.subscriptions.push(vscode.commands.registerCommand("zfls.setUpIfx", () => setUp(log, zfls)));
}

async function setUp(log: vscode.LogOutputChannel, zfls: () => string | undefined): Promise<void> {
  if (process.platform !== "win32" || process.arch !== "x64") {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: ifx without Visual Studio is for Windows on x64."));
    return;
  }
  const exe = zfls();
  if (!exe) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: no zfls executable found. Set zfls.path, or put zfls on the PATH."));
    return;
  }
  const choose = vscode.l10n.t("Choose the Installer...");
  const download = vscode.l10n.t("Open Intel's Download Page");
  const start = await vscode.window.showInformationMessage(
    vscode.l10n.t("Set up Intel's ifx"),
    {
      modal: true,
      detail: vscode.l10n.t(
        "zfls unpacks ifx from Intel's Fortran offline installer for Windows, without running the installer, and sets it up to build without Visual Studio. Download the offline installer from Intel, then choose it.",
      ),
    },
    choose,
    download,
  );
  if (start === download) {
    await vscode.env.openExternal(vscode.Uri.parse(INTEL_DOWNLOAD_URL));
    return;
  }
  if (start !== choose) {
    return;
  }
  const picked = await vscode.window.showOpenDialog({
    canSelectMany: false,
    defaultUri: vscode.Uri.file(path.join(os.homedir(), "Downloads")),
    filters: { [vscode.l10n.t("Intel's offline installer")]: ["exe"] },
    openLabel: vscode.l10n.t("Set Up ifx"),
  });
  const installer = picked?.[0]?.fsPath;
  if (!installer) {
    return;
  }

  // Intel's license, from the installer: accepted, or nothing is done
  const license = await run(exe, ["setup-ifx", installer, "--show-license"]);
  if (license.code !== 0) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: {0}", (license.stderr || license.stdout).trim()));
    return;
  }
  const doc = await vscode.workspace.openTextDocument({ content: license.stdout, language: "plaintext" });
  await vscode.window.showTextDocument(doc, { preview: true });
  const accept = vscode.l10n.t("Accept");
  const answer = await vscode.window.showInformationMessage(
    vscode.l10n.t("Do you accept Intel's license?"),
    {
      modal: true,
      detail: vscode.l10n.t("Intel's license for ifx is open in the editor. zfls sets up ifx only if you accept it."),
    },
    accept,
  );
  if (answer !== accept) {
    return;
  }

  const result = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: vscode.l10n.t("zfls: setting up ifx...") },
    () => run(exe, ["setup-ifx", installer, "--accept-intel-license", "--json"]),
  );
  log.info(`[ifx] zfls setup-ifx: exit ${result.code}\n${result.stdout}${result.stderr}`);
  let setup: SetupResult | undefined;
  try {
    setup = result.code === 0 ? (JSON.parse(result.stdout) as SetupResult) : undefined;
  } catch {
    setup = undefined;
  }
  if (!setup) {
    void vscode.window.showErrorMessage(vscode.l10n.t("zfls: setting up ifx failed: {0}", (result.stderr || result.stdout).trim()));
    return;
  }

  const use = vscode.l10n.t("Use It");
  const choice = await vscode.window.showInformationMessage(
    vscode.l10n.t("zfls: ifx {0} is ready in {1}. Use it for Run Fortran File and fpm?", setup.version, setup.dest),
    use,
    vscode.l10n.t("Not Now"),
  );
  if (choice === use) {
    const target = vscode.ConfigurationTarget.Global;
    const run = vscode.workspace.getConfiguration("zfls.run");
    await run.update("compiler", "ifx", target);
    await run.update("compilerPath", path.dirname(setup.ifx), target);
    await vscode.workspace.getConfiguration("zfls.fpm").update("compiler", setup.ifx, target);
  }
}

function run(exe: string, args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    execFile(exe, args, { maxBuffer: 16 * 1024 * 1024, windowsHide: true }, (error, stdout, stderr) => {
      const code = error ? (typeof error.code === "number" ? error.code : 1) : 0;
      resolve({ code, stdout: String(stdout), stderr: String(stderr) || (error && typeof error.code !== "number" ? error.message : "") });
    });
  });
}
