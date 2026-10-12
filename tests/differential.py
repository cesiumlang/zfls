"""Differential testing of zfls against the reference Python fortls.

For each Fortran source in a corpus, the same sequence of LSP requests
(document symbols, diagnostics, hover, definition, references, completion,
signature help, implementation) is sent to both servers and the responses
are compared. fortls runs from its source tree; its third-party
dependencies (json5, packaging, setuptools_scm) are replaced by stubs.

Usage:
    python tests/differential.py [--fortls PATH] [--zfls EXE] [--root DIR]
                                 [-k SUBSTR] [--max-diffs N]
                                 [--requests KIND,...]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from io import StringIO
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
EXE = "zfls.exe" if os.name == "nt" else "zfls"
ALL_KINDS = (
    "symbols,diagnostics,hover,definition,implementation,"
    "references,completion,signature"
)

JSON5_STUB = r'''
import json, re


def _strip(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            if c == "'":
                body = text[i + 1:j].replace('"', '\\"')
                out.append('"' + body + '"')
            else:
                out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def loads(s, *a, **k):
    return json.loads(_strip(s))


def load(f, *a, **k):
    return loads(f.read())


def dumps(o, *a, **k):
    return json.dumps(o, *a, **k)
'''

VERSION_STUB = r'''
class _V:
    def __init__(self, s):
        self.s = s
        self.is_prerelease = True

    def __gt__(self, o):
        return False


def parse(s):
    return _V(s)
'''

STUBS = {
    "json5.py": JSON5_STUB,
    "packaging/__init__.py": "",
    "packaging/version.py": VERSION_STUB,
    "setuptools_scm.py": "def get_version(*a, **k):\n    return '0.0.0'\n",
}

WORD = re.compile(
    r"[a-z_][\w$]*|\d+(\.\d*)?|\.(true|false)\.|'[^']*'|\"[^\"]*\"", re.I
)


# Typos fixed in zfls's copy of the fortls data files
# cSpell:disable-next-line
TEXT_FIXES = [("RSHIFT(I,SHIFT) eturns", "RSHIFT(I,SHIFT) returns")]
INTRINSIC_DOC = re.compile(
    r"(?:(?:```\w*\n.*?\n```)?\n-----\n)?## `?(\w+)`?\n\n### \*\*Name\*\*",
    re.S,
)


def write_stubs() -> str:
    d = Path(tempfile.mkdtemp(prefix="fortls_stubs_"))
    for rel, text in STUBS.items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return str(d)


def rpc(rid, method, params) -> str:
    body = {"jsonrpc": "2.0", "method": method, "params": params}
    if rid is not None:
        body["id"] = rid
    text = json.dumps(body, separators=(",", ":"))
    return (
        f"Content-Length: {len(text)}\r\n"
        "Content-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n"
        f"{text}"
    )


def read_messages(data: bytes) -> list[dict]:
    msgs = []
    f = StringIO(data.decode("utf-8", errors="replace"))
    while True:
        line = f.readline()
        if not line:
            break
        if not line.startswith("Content-Length:"):
            continue
        length = int(line.split(":", 1)[1].strip())
        while line not in ("\r\n", "\n", ""):
            line = f.readline()
        msgs.append(json.loads(f.read(length)))
    return msgs


def build_requests(path: Path, root: Path, kinds: set[str]):
    """Return the request stream and (id, kind, params) per request."""
    uri = str(path)
    stream = rpc(1, "initialize", {"rootPath": str(root)})
    stream += rpc(
        None, "textDocument/didOpen", {"textDocument": {"uri": uri}}
    )
    reqs: list[tuple[int, str, dict]] = []
    rid = 10

    def add(kind, method, params):
        nonlocal stream, rid
        if kind not in kinds:
            return
        rid += 1
        stream += rpc(rid, method, params)
        reqs.append((rid, kind, params))

    td = {"textDocument": {"uri": uri}}

    def at(line, char):
        return {**td, "position": {"line": line, "character": char}}

    add("symbols", "textDocument/documentSymbol", td)
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
    except OSError:
        lines = []
    for ln, text in enumerate(lines):
        if len(text) > 400:
            continue
        for m in WORD.finditer(text):
            inside = at(ln, m.start() + 1)
            add("hover", "textDocument/hover", inside)
            add("definition", "textDocument/definition", inside)
            add("implementation", "textDocument/implementation", inside)
            add("references", "textDocument/references", inside)
            add("completion", "textDocument/completion", at(ln, m.end()))
        for m in re.finditer(r"[(,]", text):
            add("signature", "textDocument/signatureHelp", at(ln, m.end()))
    stream += rpc(2, "shutdown", None)
    stream += rpc(None, "exit", None)
    return stream, reqs


def run_server(cmd: list[str], stream: str, env=None) -> dict:
    p = subprocess.run(
        cmd, input=stream.encode(), capture_output=True, env=env,
        timeout=1800,
    )
    out = {
        "notifications": [],
        "responses": {},
        "stderr": p.stderr.decode(errors="replace"),
    }
    for m in read_messages(p.stdout):
        if "id" in m and ("result" in m or "error" in m):
            if "result" in m:
                out["responses"][m["id"]] = m["result"]
            else:
                err = {"__error__": m["error"].get("message")}
                out["responses"][m["id"]] = err
        elif "method" in m:
            out["notifications"].append(m)
    return out


def normalize(v):
    """Drop details that legitimately differ between the servers."""
    if isinstance(v, dict):
        return {k: normalize(x) for k, x in v.items() if k != "traceback"}
    if isinstance(v, list):
        return [normalize(x) for x in v]
    if isinstance(v, str):
        for old, new in TEXT_FIXES:
            v = v.replace(old, new)
        # zfls reformats the intrinsic manual pages for markdownlint
        m = INTRINSIC_DOC.match(v)
        if m:
            return f"<intrinsic manual page {m.group(1)}>"
    return v


def is_error(v) -> bool:
    return isinstance(v, dict) and "__error__" in v


def notifications(res: dict, method: str) -> list:
    return [n["params"] for n in res["notifications"] if n["method"] == method]


def first_difference(a, b, path="$"):
    """Return (json path, a value, b value) of the first difference."""
    if type(a) is not type(b):
        return path, a, b
    if isinstance(a, dict):
        for k in list(a) + [k for k in b if k not in a]:
            if k not in a or k not in b:
                missing = "<absent>"
                return f"{path}.{k}", a.get(k, missing), b.get(k, missing)
            d = first_difference(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_difference(x, y, f"{path}[{i}]")
            if d:
                return d
        if len(a) != len(b):
            return f"{path}.length", len(a), len(b)
        return None
    return None if a == b else (path, a, b)


def ref_key(r: dict):
    start = r["range"]["start"]
    return (r["uri"], start["line"], start["character"])


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fortls", default=str(REPO.parent / "fortls"))
    ap.add_argument("--zfls", default=str(REPO / "zig-out" / "bin" / EXE))
    ap.add_argument(
        "--root", default=None, help="corpus root (default: fortls tests)"
    )
    ap.add_argument("-k", default="", help="only paths containing this")
    ap.add_argument(
        "--max-diffs", type=int, default=20, help="diffs to print per file"
    )
    ap.add_argument("--requests", default=ALL_KINDS)
    ap.add_argument("--args", default="", help="extra server arguments")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    fortls_root = Path(args.fortls).resolve()
    if args.root:
        root = Path(args.root).resolve()
    else:
        root = fortls_root / "test" / "test_source"
    kinds = set(args.requests.split(","))
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([write_stubs(), str(fortls_root)])
    common = ["--incremental_sync", "--disable_autoupdate", *args.args.split()]
    fortls_cmd = [sys.executable, "-m", "fortls", *common]
    zfls_cmd = [str(Path(args.zfls).resolve()), *common]

    exts = {".f", ".f90", ".f08", ".f03", ".f95", ".f77", ".for", ".fpp", ".h"}
    files = sorted(
        p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in exts
    )
    total = total_diff = crashes = 0
    for path in files:
        if args.k and args.k not in str(path):
            continue
        stream, reqs = build_requests(path, root, kinds)
        ref = run_server(fortls_cmd, stream, env=env)
        got = run_server(zfls_cmd, stream)
        diffs = []
        if "diagnostics" in kinds:
            for method in (
                "textDocument/publishDiagnostics",
                "window/showMessage",
            ):
                a = normalize(notifications(ref, method))
                b = normalize(notifications(got, method))
                if a != b:
                    diffs.append((method, None, a, b))
        for rid, kind, params in reqs:
            a = normalize(ref["responses"].get(rid, "<missing>"))
            b = normalize(got["responses"].get(rid, "<missing>"))
            total += 1
            if kind == "references":
                # cross-file order follows workspace iteration order
                if isinstance(a, list) and isinstance(b, list):
                    a, b = sorted(a, key=ref_key), sorted(b, key=ref_key)
            if kind == "completion":
                # globals are listed in workspace iteration order, which is
                # hash-randomized in fortls; clients sort completions anyway
                if isinstance(a, list) and isinstance(b, list):
                    a, b = sorted(a, key=json.dumps), sorted(b, key=json.dumps)
            if is_error(a):
                # fortls crashed (Python exception): no reference behavior
                crashes += 1
                continue
            if a != b:
                diffs.append((kind, params.get("position"), a, b))
        total_diff += len(diffs)
        rel = path.relative_to(root)
        status = "DIFF" if diffs else "OK  "
        print(f"{status} {rel}: {len(reqs)} requests, {len(diffs)} diffs")
        for kind, pos, a, b in diffs[: args.max_diffs]:
            where, x, y = first_difference(a, b) or ("$", a, b)
            print(f"   [{kind}] at {pos}: first difference at {where}")
            print(f"      fortls: {json.dumps(x)[:400]}")
            print(f"      zfls  : {json.dumps(y)[:400]}")
    print(
        f"\n{total} requests compared, {total_diff} differences, "
        f"{crashes} requests where fortls raised an error"
    )
    return 1 if total_diff else 0


if __name__ == "__main__":
    sys.exit(main())
