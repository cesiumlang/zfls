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
from urllib.parse import unquote

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

# Runs fortls with its workspace loaded in descending path order. fortls lets
# the file parsed last own a global name several files define; this hands it
# to the file with the lowest path, which is the one zfls picks (README,
# "Differences from fortls"), instead of one that depends on directory
# listing and set iteration order.
ORDERED_LAUNCHER = '''import runpy
from fortls.langserver import LangServer

_source_files = LangServer._get_source_files


def _ordered(self):
    return sorted(_source_files(self), reverse=True)


LangServer._get_source_files = _ordered
runpy.run_module("fortls", run_name="__main__", alter_sys=True)
'''

STUBS = {
    "fortls_ordered.py": ORDERED_LAUNCHER,
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
PARAM_VALUE = re.compile(r"(PARAMETER[^\n:]*:: \w+ = [^\n(\[]*)[(\[][^\n]*")
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
    # An unchanged full-text change makes fortls parse the file again, which
    # gives its own definitions of names other files also define precedence,
    # as zfls does for code in that file
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = None
    if text is not None:
        stream += rpc(None, "textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 2},
            "contentChanges": [{"text": text}],
        })
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
        # fortls cuts the value of a parameter at its first parenthesis or
        # bracket; zfls shows it whole (upstream issue 124)
        v = PARAM_VALUE.sub(r"\1", v)
        # zfls reformats the intrinsic manual pages for markdownlint
        m = INTRINSIC_DOC.match(v)
        if m:
            return f"<intrinsic manual page {m.group(1)}>"
    return v


INCLUDE_DIRECTIVE = re.compile(r"\s*#\s*include\s*[\"<]", re.I)
USE_LINE = re.compile(r"\s*use\b", re.I)


def on_use_rename_original(lines: list, line: int, char: int) -> bool:
    """Whether (line, char) is on the original name of a rename on a USE
    statement, `use m, local => ORIGINAL`."""
    if not 0 <= line < len(lines) or not USE_LINE.match(lines[line]):
        return False
    text = lines[line]
    start = char
    while start > 0 and (text[start - 1].isalnum() or text[start - 1] == "_"):
        start -= 1
    return text[:start].rstrip().endswith("=>")


def use_rename_extras(lines: list, a, b) -> bool:
    """Whether references `b` are `a` plus locations on the original names
    of USE renames only."""
    if not isinstance(a, list) or not isinstance(b, list) or len(b) <= len(a):
        return False
    rest = list(b)
    for loc in a:
        if loc not in rest:
            return False
        rest.remove(loc)
    for loc in rest:
        start = loc.get("range", {}).get("start", {})
        if not on_use_rename_original(lines, start.get("line", -1), start.get("character", 0)):
            return False
    return True


def on_include_directive(path: Path, position) -> bool:
    """Whether the position is on a preprocessor `#include` line of the file."""
    if not position:
        return False
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    line = position.get("line", -1)
    return 0 <= line < len(lines) and bool(INCLUDE_DIRECTIVE.match(lines[line]))


ASSOC_BOUND = re.compile(r"\b(\w+)\s*=>\s*\w+\s*\(", re.I)


def associate_names(source: str) -> set:
    """Lowercase names bound by `name => array(...)` (ASSOCIATE or pointer
    assignment) in a source file."""
    return {m.group(1).lower() for m in ASSOC_BOUND.finditer(source)}


def ignore_slice_dimensions(v, names: set):
    """fortls gives an ASSOCIATE name bound to an element or a section the
    dimensions of the whole array; zfls gives it those of the section
    (upstream issue 108). Compare the dimensions of such names as equal."""
    if isinstance(v, dict):
        return {k: ignore_slice_dimensions(x, names) for k, x in v.items()}
    if isinstance(v, list):
        return [ignore_slice_dimensions(x, names) for x in v]
    if isinstance(v, str) and names:
        def repl(m):
            return m.group(0) if m.group(3).lower() not in names else m.group(2) + m.group(3)

        return re.sub(r"(, )?DIMENSION\([^)\n]*\)( :: )(\w+)", repl, v)
    return v


def is_error(v) -> bool:
    return isinstance(v, dict) and "__error__" in v


def notifications(res: dict, method: str) -> list:
    return [n["params"] for n in res["notifications"] if n["method"] == method]


def own_file_definition(ref, got, own: str) -> bool:
    """Whether zfls found the definition in the requesting file (path
    suffix `own`) where fortls found one in another file."""
    if not (isinstance(ref, dict) and isinstance(got, dict)):
        return False
    ref_uri = unquote(ref.get("uri", ""))
    got_uri = unquote(got.get("uri", ""))
    return got_uri.endswith(own) and not ref_uri.endswith(own)


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
    # fortls iterates sets of directory names; fix string hashing so runs on
    # one machine are reproducible (ORDERED_LAUNCHER fixes the load order)
    env["PYTHONHASHSEED"] = "0"
    common = ["--incremental_sync", "--disable_autoupdate", *args.args.split()]
    fortls_cmd = [sys.executable, "-m", "fortls_ordered", *common]
    zfls_cmd = [str(Path(args.zfls).resolve()), *common]

    exts = {".f", ".f90", ".f08", ".f03", ".f95", ".f77", ".for", ".fpp", ".h"}
    files = sorted(
        p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in exts
    )
    total = total_diff = crashes = own_file = 0
    for path in files:
        if args.k and args.k not in str(path):
            continue
        stream, reqs = build_requests(path, root, kinds)
        own = "/" + path.relative_to(root).as_posix()
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
        source = path.read_text(encoding="utf-8", errors="replace")
        assoc = associate_names(source)
        src_lines = source.splitlines()
        for rid, kind, params in reqs:
            a = normalize(ref["responses"].get(rid, "<missing>"))
            b = normalize(got["responses"].get(rid, "<missing>"))
            if assoc and kind in ("hover", "completion"):
                a = ignore_slice_dimensions(a, assoc)
                b = ignore_slice_dimensions(b, assoc)
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
            if (
                kind == "definition"
                and a is None
                and isinstance(b, dict)
                and on_include_directive(path, params.get("position"))
            ):
                # go to definition on a `#include` opens the included file
                # (upstream issue 498); fortls has no answer
                continue
            pos = params.get("position") or {}
            if (
                kind in ("hover", "definition", "references")
                and a is None
                and on_use_rename_original(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # the original name of a USE rename is the module's entity
                # (hansec #137); fortls has no answer there
                continue
            if kind == "references" and use_rename_extras(src_lines, a, b):
                # references also find the original name on USE rename lines
                # (hansec #137), which fortls misses
                continue
            if kind == "definition" and own_file_definition(a, b, own):
                # a global name defined in several files: zfls answers with
                # the requesting file's own definition (README, "Differences")
                own_file += 1
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
        f"{crashes} requests where fortls raised an error, "
        f"{own_file} definitions in the requesting file where fortls "
        "picks another file's"
    )
    return 1 if total_diff else 0


if __name__ == "__main__":
    sys.exit(main())
