// The commands of zfls's code lenses (the reference count above modules,
// procedures and types; Run and Debug above a program): the server names
// them in its lenses once the client says it has them, in its capabilities
// under experimental.commands.commands (as rust-analyzer's clients do).
// Their arguments arrive as JSON: a URI string, and positions and locations
// of the protocol, which VS Code's own commands take as objects. No `vscode`
// import (see test/unit).

import type { StaticFeature } from "vscode-languageclient/node";

/** The commands of the lenses that the extension runs */
export const LENS_COMMANDS = ["zfls.showReferences", "zfls.runFile", "zfls.debugFile"] as const;

export interface ProtocolPosition {
  line: number;
  character: number;
}

interface ProtocolLocation {
  uri: string;
  range: { start: ProtocolPosition; end: ProtocolPosition };
}

/** The arguments of zfls.showReferences: the document, the position of the
 * name, and its references; undefined for anything else */
export function referenceArgs(
  args: unknown[],
): { uri: string; position: ProtocolPosition; locations: ProtocolLocation[] } | undefined {
  const [uri, position, locations] = args;
  if (typeof uri !== "string" || !isPosition(position) || !Array.isArray(locations)) {
    return undefined;
  }
  if (!locations.every(isLocation)) {
    return undefined;
  }
  return { uri, position, locations };
}

function isPosition(x: unknown): x is ProtocolPosition {
  const p = x as ProtocolPosition | undefined;
  return typeof p?.line === "number" && typeof p?.character === "number";
}

function isLocation(x: unknown): x is ProtocolLocation {
  const l = x as ProtocolLocation | undefined;
  return typeof l?.uri === "string" && isPosition(l?.range?.start) && isPosition(l?.range?.end);
}

/** The client feature that tells zfls which lens commands the extension runs */
export function lensCommandsFeature(): StaticFeature {
  return {
    fillClientCapabilities(capabilities) {
      const experimental = (capabilities.experimental ?? {}) as { commands?: { commands?: string[] } };
      experimental.commands = { commands: [...(experimental.commands?.commands ?? []), ...LENS_COMMANDS] };
      capabilities.experimental = experimental;
    },
    initialize() {},
    getState() {
      return { kind: "static" };
    },
    clear() {},
  };
}
