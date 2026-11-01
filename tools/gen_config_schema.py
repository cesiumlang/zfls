#!/usr/bin/env python3
"""Generate the JSON schema of zfls configuration files (.fortlsrc,
.fortls.json, .fortls) from the option table in src/settings.zig:

    python tools/gen_config_schema.py          # write the schema
    python tools/gen_config_schema.py --check  # fail if it is out of date

The schema lists the options `applyConfig` reads from a configuration file,
with the type of their command-line option (`opts`), its help text, and the
default value in the `Settings` struct. The VS Code extension contributes it
for those file names (editors/vscode/package.json, `jsonValidation`).
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "src" / "settings.zig"
CONSTANTS = ROOT / "src" / "constants.zig"
SCHEMA = ROOT / "editors" / "vscode" / "schemas" / "fortls.schema.json"

# JSON schema of each option kind of `opts`
KIND_TYPES = {
    "flag": {"type": "boolean"},
    "int": {"type": "integer"},
    "string": {"type": "string"},
    "list": {"type": "array", "items": {"type": "string"}, "uniqueItems": True},
    # pp_defs: {"NAME": value, ...}, or a list of names defined as empty
    "json": {
        "type": ["object", "array"],
        "additionalProperties": {"type": ["string", "number", "boolean", "null"]},
        "items": {"type": "string"},
    },
}


def block(src: str, start: str) -> str:
    """The text from `start` up to the closing brace of its block"""
    i = src.index(start)
    depth = 0
    for j in range(src.index("{", i), len(src)):
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        if depth == 0:
            return src[i:j]
    raise ValueError(f"unterminated block {start!r}")


def zig_string(s: str) -> str:
    return json.loads(s)  # the help texts only use \" and \\ escapes


def parse_opts(src: str) -> dict:
    opts = {}
    for line in block(src, "const opts = [_]Opt{").splitlines():
        m = re.match(r'\s*\.\{ \.long = "(\w+)"', line)
        if not m:
            continue
        kind = re.search(r"\.kind = \.(\w+)", line).group(1)
        help_text = zig_string(re.search(r'\.help = ("(?:[^"\\]|\\.)*")', line).group(1))
        opts[m.group(1)] = (kind, help_text.strip())
    return opts


def parse_defaults(src: str) -> dict:
    defaults = {}
    for line in block(src, "pub const Settings = struct {").splitlines():
        m = re.match(r"\s*(\w+): (\??)([\w.() \[\]]+?) = (.+),$", line)
        if not m:
            continue
        name, optional, typ, value = m.groups()
        if value == "null":
            defaults[name] = None
        elif value in ("true", "false"):
            defaults[name] = value == "true"
        elif re.fullmatch(r"-?\d+", value):
            defaults[name] = int(value)
        elif value.startswith('"'):
            defaults[name] = zig_string(value)
        elif typ == "StrList" and value == ".{}":
            defaults[name] = []
        elif value == ".empty" and typ.startswith("std.ArrayList("):
            # pp_defs, diagnostic_severity: JSON objects
            defaults[name] = {}
        else:
            raise ValueError(f"unknown default of Settings.{name}: {value}")
    return defaults


def diagnostic_codes() -> list:
    """The names of `C.DiagCode`, with `-` for `_`"""
    body = block(CONSTANTS.read_text(encoding="utf-8"), "pub const DiagCode = enum {")
    return [m.replace("_", "-") for m in re.findall(r"(?m)^\s+(\w+),$", body)]


# Options whose JSON is not that of their option kind
SPECIAL = {
    "diagnostic_severity": lambda: {
        "type": "object",
        "propertyNames": {"enum": diagnostic_codes()},
        "additionalProperties": {"enum": ["off", "error", "warning", "information", "hint"]},
    },
    "compiler_diagnostics": lambda: {
        "type": "string",
        "enum": ["gfortran", "ifx", "ifort", "flang", "nvfortran", "nagfor", "lfortran", "none", None],
    },
    # a list keeps repeated arguments; a string is split at spaces
    "compiler_args": lambda: {"type": ["array", "string"], "items": {"type": "string"}},
}


def config_keys(src: str) -> list:
    body = block(src, "pub fn applyConfig(")
    keys = []
    for k in re.findall(r'json\.get\(cfg, "(\w+)"\)', body):
        if k not in keys:
            keys.append(k)
    return keys


def schema() -> dict:
    src = SETTINGS.read_text(encoding="utf-8")
    opts = parse_opts(src)
    defaults = parse_defaults(src)
    properties = {}
    for key in config_keys(src):
        if key not in opts or key not in defaults:
            raise ValueError(f"applyConfig reads {key!r}, which opts or Settings lacks")
        kind, help_text = opts[key]
        prop = {"description": help_text}
        prop.update(SPECIAL[key]() if key in SPECIAL else json.loads(json.dumps(KIND_TYPES[kind])))
        default = defaults[key]
        if default is None:
            types = prop["type"] if isinstance(prop["type"], list) else [prop["type"]]
            prop["type"] = [*types, "null"]
        else:
            prop["default"] = default
        properties[key] = prop
    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "$comment": "Generated from src/settings.zig by tools/gen_config_schema.py; do not edit",
        "title": "zfls configuration",
        "description": "Options of the zfls (and fortls) Fortran language server; "
        "they override the command-line options",
        "type": "object",
        "properties": properties,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="fail if the schema is out of date")
    args = ap.parse_args()
    text = json.dumps(schema(), indent=2) + "\n"
    if args.check:
        current = SCHEMA.read_text(encoding="utf-8") if SCHEMA.exists() else ""
        if current != text:
            print(f"{SCHEMA.relative_to(ROOT).as_posix()} is out of date; run "
                  "python tools/gen_config_schema.py", file=sys.stderr)
            return 1
        return 0
    SCHEMA.parent.mkdir(parents=True, exist_ok=True)
    with open(SCHEMA, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
