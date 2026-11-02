"""Move the user-visible strings of the VS Code extension's package.json
into package.nls.json, as `%key%` references, so that a translation is a
package.nls.<language>.json file of the same keys (VS Code picks the one of
its display language, and falls back to package.nls.json, English).

The keys follow where a string is: `zfls.run.compiler.markdownDescription`,
`command.zfls.restart.title`, `debugger.fortran.program.description`, ...
Strings already moved are left alone, so the script can run again after
new settings or commands are added; `--check` only says whether any string
is left to move (for CI).

Usage:
    python tools/package_nls.py [--check]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

EXT = Path(__file__).resolve().parent.parent / "editors" / "vscode"
PACKAGE = EXT / "package.json"
NLS = EXT / "package.nls.json"


def is_ref(s: object) -> bool:
    return isinstance(s, str) and s.startswith("%") and s.endswith("%") and len(s) > 2


class Mover:
    def __init__(self, strings: dict[str, str]):
        self.strings = strings
        self.moved = 0

    def move(self, obj: dict, field: str, key: str) -> None:
        """`obj[field]`, a string, to `key`"""
        value = obj.get(field)
        if not isinstance(value, str) or is_ref(value) or not value.strip():
            return
        self.strings[key] = value
        obj[field] = f"%{key}%"
        self.moved += 1

    def move_list(self, obj: dict, field: str, key: str) -> None:
        """Each string of the list `obj[field]`, to `key.<index>`"""
        values = obj.get(field)
        if not isinstance(values, list):
            return
        for i, v in enumerate(values):
            if isinstance(v, str) and not is_ref(v) and v.strip():
                self.strings[f"{key}.{i}"] = v
                values[i] = f"%{key}.{i}%"
                self.moved += 1

    def schema(self, props: dict, prefix: str) -> None:
        """The descriptions of JSON schema properties, and of theirs"""
        for name, prop in props.items():
            if not isinstance(prop, dict):
                continue
            key = f"{prefix}.{name}"
            for field in ("description", "markdownDescription", "deprecationMessage", "markdownDeprecationMessage"):
                self.move(prop, field, f"{key}.{field}")
            for field in ("enumDescriptions", "markdownEnumDescriptions"):
                self.move_list(prop, field, f"{key}.{field}")
            if isinstance(prop.get("properties"), dict):
                self.schema(prop["properties"], key)


def convert(pkg: dict, strings: dict[str, str]) -> int:
    m = Mover(strings)
    m.move(pkg, "displayName", "displayName")
    m.move(pkg, "description", "description")
    c = pkg.get("contributes", {})
    configs = c.get("configuration")
    for conf in configs if isinstance(configs, list) else [configs] if configs else []:
        m.move(conf, "title", "configuration.title")
        m.schema(conf.get("properties", {}), "config")
    for cmd in c.get("commands", []):
        m.move(cmd, "title", f"command.{cmd['command']}.title")
        m.move(cmd, "category", "command.category")
    for task in c.get("taskDefinitions", []):
        m.schema(task.get("properties", {}), f"taskDefinition.{task['type']}")
    for dbg in c.get("debuggers", []):
        t = dbg["type"]
        m.move(dbg, "label", f"debugger.{t}.label")
        for request, attrs in dbg.get("configurationAttributes", {}).items():
            m.schema(attrs.get("properties", {}), f"debugger.{t}.{request}")
        for i, snip in enumerate(dbg.get("configurationSnippets", [])):
            m.move(snip, "label", f"debugger.{t}.snippet.{i}.label")
            m.move(snip, "description", f"debugger.{t}.snippet.{i}.description")
    for container, views in c.get("views", {}).items():
        for v in views:
            m.move(v, "name", f"view.{v['id']}.name")
    for w in c.get("walkthroughs", []):
        wid = w["id"]
        m.move(w, "title", f"walkthrough.{wid}.title")
        m.move(w, "description", f"walkthrough.{wid}.description")
        for step in w.get("steps", []):
            sid = step["id"]
            m.move(step, "title", f"walkthrough.{wid}.{sid}.title")
            m.move(step, "description", f"walkthrough.{wid}.{sid}.description")
    for p in c.get("problemMatchers", []):
        m.move(p, "label", f"problemMatcher.{p['name']}.label")
    return m.moved


def main() -> int:
    check = "--check" in sys.argv[1:]
    pkg = json.loads(PACKAGE.read_text(encoding="utf-8"))
    strings = json.loads(NLS.read_text(encoding="utf-8")) if NLS.exists() else {}
    moved = convert(pkg, strings)
    if check:
        if moved:
            print(f"{moved} strings of package.json are not in package.nls.json: run tools/package_nls.py")
            return 1
        return 0
    PACKAGE.write_text(json.dumps(pkg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    NLS.write_text(json.dumps(strings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    print(f"moved {moved} strings to {NLS.name} ({len(strings)} in all)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
