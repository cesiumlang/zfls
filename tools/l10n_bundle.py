"""Write the messages the VS Code extension shows while it runs (each
`vscode.l10n.t("...")` of its sources) into l10n/bundle.l10n.json, the
English bundle a translation starts from: a translation is a
bundle.l10n.<language>.json file of the same keys, next to it. VS Code
shows the message itself when there is none for its display language.

The bundle has the format of `@vscode/l10n-dev export`: each message is
its own key. `--check` only says whether the bundle is up to date (for CI).

Usage:
    python tools/l10n_bundle.py [--check]
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

EXT = Path(__file__).resolve().parent.parent / "editors" / "vscode"
BUNDLE = EXT / "l10n" / "bundle.l10n.json"

CALL = re.compile(r"\bl10n\.t\(\s*")
# a string literal, then `+` and another, ...
LITERAL = re.compile(r"""("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')""")
PLUS = re.compile(r"\s*\+\s*")


def unquote(literal: str) -> str:
    if literal[0] == "'":
        body = literal[1:-1].replace("\\'", "'").replace('"', '\\"')
        return json.loads(f'"{body}"')
    return json.loads(literal)


def messages(source: str, where: str) -> list[str]:
    """The messages of the `l10n.t` calls of a source file"""
    found = []
    for m in CALL.finditer(source):
        pos = m.end()
        parts = []
        while lit := LITERAL.match(source, pos):
            parts.append(unquote(lit.group(1)))
            pos = lit.end()
            plus = PLUS.match(source, pos)
            if not plus or not LITERAL.match(source, plus.end()):
                break
            pos = plus.end()
        if not parts:
            line = source.count("\n", 0, m.start()) + 1
            sys.exit(f"{where}:{line}: l10n.t needs a string literal (not a template or a variable)")
        found.append("".join(parts))
    return found


def bundle() -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted((EXT / "src").rglob("*.ts")):
        for msg in messages(path.read_text(encoding="utf-8"), str(path.relative_to(EXT))):
            out[msg] = msg
    return dict(sorted(out.items()))


def main() -> None:
    text = json.dumps(bundle(), indent=2, ensure_ascii=False) + "\n"
    old = BUNDLE.read_text(encoding="utf-8") if BUNDLE.exists() else ""
    if "--check" in sys.argv[1:]:
        if text != old:
            sys.exit(f"{BUNDLE.relative_to(EXT.parent.parent)} is out of date: run python tools/l10n_bundle.py")
        print(f"{BUNDLE.name}: up to date")
        return
    BUNDLE.parent.mkdir(exist_ok=True)
    BUNDLE.write_text(text, encoding="utf-8", newline="\n")
    print(f"{BUNDLE.name}: {len(json.loads(text))} messages")


if __name__ == "__main__":
    main()
