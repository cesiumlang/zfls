// VS Code's tokenizer (vscode-textmate with vscode-oniguruma, the regular
// expression engine VS Code uses) on the extension's grammars, with the
// injections package.json registers: for the grammar tests, without VS Code.

import * as fs from "node:fs";
import * as path from "node:path";
import * as oniguruma from "vscode-oniguruma";
import * as textmate from "vscode-textmate";

const root = path.join(__dirname, "..", "..");

interface GrammarEntry {
  scopeName: string;
  path: string;
  injectTo?: string[];
}

const grammars: GrammarEntry[] = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).contributes.grammars;

let registry: Promise<textmate.Registry> | undefined;

function load(): Promise<textmate.Registry> {
  registry ??= (async () => {
    const wasm = fs.readFileSync(path.join(root, "node_modules", "vscode-oniguruma", "release", "onig.wasm"));
    await oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength) as ArrayBuffer);
    return new textmate.Registry({
      onigLib: Promise.resolve({
        createOnigScanner: (patterns: string[]) => new oniguruma.OnigScanner(patterns),
        createOnigString: (s: string) => new oniguruma.OnigString(s),
      }),
      loadGrammar: async (scopeName: string) => {
        const entry = grammars.find((g) => g.scopeName === scopeName);
        if (!entry) {
          return null;
        }
        const file = path.join(root, entry.path);
        return textmate.parseRawGrammar(fs.readFileSync(file, "utf8"), file);
      },
      getInjections: (scopeName: string) =>
        grammars.filter((g) => g.injectTo?.includes(scopeName)).map((g) => g.scopeName),
    });
  })();
  return registry;
}

/** A token: its text and its scopes, without the grammar's own */
export interface Token {
  text: string;
  scopes: string[];
}

/** The tokens of each line of `source` in the grammar `scopeName`
 * (`source.fortran.free` or `source.fortran.fixed`) */
export async function tokenize(source: string, scopeName: string): Promise<Token[][]> {
  const grammar = await (await load()).loadGrammar(scopeName);
  if (!grammar) {
    throw new Error(`no grammar ${scopeName}`);
  }
  let state = textmate.INITIAL;
  const out: Token[][] = [];
  for (const line of source.split("\n")) {
    const result = grammar.tokenizeLine(line, state);
    out.push(
      result.tokens.map((t) => ({
        text: line.slice(t.startIndex, t.endIndex),
        scopes: t.scopes.slice(1),
      })),
    );
    state = result.ruleStack;
  }
  return out;
}

/** The scopes of the first token of `line` whose text is `text` (trimmed) */
export function scopesOf(line: Token[], text: string): string[] {
  const token = line.find((t) => t.text.trim() === text);
  if (!token) {
    throw new Error(`no token ${JSON.stringify(text)} in ${JSON.stringify(line.map((t) => t.text))}`);
  }
  return token.scopes;
}
