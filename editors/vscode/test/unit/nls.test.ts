// Plain Node.js tests (no VS Code) of the extension's strings: each %key%
// of package.json is in package.nls.json (English), and a translation,
// package.nls.<language>.json, has only keys of it (`npm run unit`).
// tools/package_nls.py moves new strings there. The same for the messages
// shown while the extension runs, in l10n/ (tools/l10n_bundle.py).

import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const root = path.join(__dirname, "..", "..");
const nls = JSON.parse(fs.readFileSync(path.join(root, "package.nls.json"), "utf8")) as Record<string, string>;

function refs(node: unknown, out: string[] = []): string[] {
  if (typeof node === "string") {
    const m = /^%(.+)%$/.exec(node);
    if (m) out.push(m[1]);
  } else if (Array.isArray(node)) {
    node.forEach((n) => refs(n, out));
  } else if (node && typeof node === "object") {
    Object.values(node).forEach((n) => refs(n, out));
  }
  return out;
}

test("every string of package.json is in package.nls.json", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const keys = refs(pkg);
  assert.ok(keys.length > 50, "package.json has its strings as %key%");
  for (const k of keys) assert.ok(k in nls, `%${k}% is not in package.nls.json`);
});

test("translations have only the keys of package.nls.json", () => {
  for (const f of fs.readdirSync(root).filter((n) => /^package\.nls\..+\.json$/.test(n))) {
    const t = JSON.parse(fs.readFileSync(path.join(root, f), "utf8")) as Record<string, string>;
    for (const k of Object.keys(t)) assert.ok(k in nls, `${f}: unknown key ${k}`);
  }
});

test("translations of the runtime messages have only the keys of the bundle, with their placeholders", () => {
  const dir = path.join(root, "l10n");
  const bundle = JSON.parse(fs.readFileSync(path.join(dir, "bundle.l10n.json"), "utf8")) as Record<string, string>;
  assert.ok(Object.keys(bundle).length > 30, "the extension's messages are in l10n/bundle.l10n.json");
  const holes = (s: string): string => [...new Set(s.match(/\{\d+\}/g) ?? [])].sort().join();
  for (const f of fs.readdirSync(dir).filter((n) => /^bundle\.l10n\..+\.json$/.test(n))) {
    const t = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")) as Record<string, string>;
    for (const [k, v] of Object.entries(t)) {
      assert.ok(k in bundle, `${f}: unknown message ${k}`);
      assert.equal(holes(v), holes(k), `${f}: ${k} has other placeholders`);
    }
  }
});

test("each walkthrough step has its page, and its buttons run commands that exist", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const ours = new Set<string>(pkg.contributes.commands.map((c: { command: string }) => c.command));
  const walkthroughs = pkg.contributes.walkthroughs as {
    steps: { id: string; description: string; media: { markdown: string } }[];
  }[];
  assert.ok(walkthroughs.length > 0);
  for (const step of walkthroughs.flatMap((w) => w.steps)) {
    assert.ok(fs.existsSync(path.join(root, step.media.markdown)), `${step.id}: ${step.media.markdown} is missing`);
    const text = nls[/^%(.+)%$/.exec(step.description)![1]];
    const buttons = [...text.matchAll(/\]\(command:([\w.]+)/g)].map((m) => m[1]);
    assert.ok(buttons.length > 0, `${step.id} has no button`);
    for (const c of buttons) assert.ok(!c.startsWith("zfls.") || ours.has(c), `${step.id}: no command ${c}`);
  }
});
