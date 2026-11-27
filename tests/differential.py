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

from differential_known import (
    ENTITY_LENGTH,
    LITERAL_HOVER,
    SEMICOLON_STRINGS,
    ZFLS_ONLY_INTRINSICS,
    adjacent_references,
    after_non_code_line,
    dollar_name_references,
    in_string_with_bang,
    on_keyword_or_operator,
    associate_bound,
    associate_names,
    conditional_attributes,
    first_difference,
    forget_associate_types,
    generic_specific_definition,
    ignore_associate_attributes,
    ignore_associate_functions,
    ignore_conditional_attributes,
    ignore_param_strings,
    ignore_slice_dimensions,
    ignore_type_params,
    implicit_result_refs,
    in_constructor_or_group,
    is_error,
    items_within,
    macro_names,
    normalize,
    notifications,
    on_assignment,
    on_construct_name_or_label,
    on_implicit_variable,
    on_enumerator_statement,
    on_import_statement,
    on_include_directive,
    on_keyword_argument,
    on_name_in,
    colon_generics,
    on_include_line,
    on_macro,
    on_parenthesized_kind,
    on_use_rename_original,
    on_user_operator,
    on_zfls_only_intrinsic,
    own_file_definition,
    ref_key,
    select_bound,
    separate_procedure_refs,
    two_forms_item,
    untyped_by_fortls,
    use_alias_refs,
    use_rename_extras,
    zfls_only_intrinsics,
    zfls_only_item,
)

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

# The places build_requests asks about: names, numbers, logical literals and
# character literals
WORD = re.compile(
    r"[a-z_][\w$]*|\d+(\.\d*)?|\.(true|false)\.|'[^']*'|\"[^\"]*\"", re.I
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


def declared_word(lines: list, line: int, char: int):
    """The name (lowercase) that ends at the position when it is in the
    entity list of a declaration (after `::`, or in the old form after the
    type), not an initialization, else None."""
    if not (0 <= line < len(lines)):
        return None
    code = lines[line].split("!")[0][:char]
    if "::" not in code and not DECL_START.match(code):
        return None
    depth = 0
    for c in reversed(code.split("::")[-1]):
        if c in ")]":
            depth += 1
        elif c in "([":
            depth -= 1
        elif depth == 0 and c == ",":
            break
        elif depth == 0 and c == "=":
            return None
    m = re.search(r"[A-Za-z_][A-Za-z0-9_]*$", code)
    return m.group(0).lower() if m else None


DECL_START = re.compile(
    r"\s*(integer|real|complex|logical|character|double(\s*)precision|double(\s*)complex|external|type(\s*)\(|class(\s*)\(|procedure(\s*)\().*[\s,)*]\w*$",
    re.I,
)


def main() -> int:
    args = parse_args()
    fortls_root = Path(args.fortls).resolve()
    ZFLS_ONLY_INTRINSICS.update(zfls_only_intrinsics(fortls_root))
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
    # hover on a derived type lists its components (#268); fortls's does not
    zfls_cmd = [
        str(Path(args.zfls).resolve()), *common, "--disable_index_cache",
        "--hover_no_type_components",
        # fortls reports an INTENT outside the argument list (#879)
        "--lint_dialect", "gfortran",
    ]

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
        bound = associate_bound(source)
        bound_names = bound | select_bound(source)
        src_lines = source.splitlines()
        cond_attrs = conditional_attributes(source)
        macros = macro_names(path, source)
        entity_lengths = bool(ENTITY_LENGTH.search(source))
        semicolon_strings = bool(SEMICOLON_STRINGS.search(source))
        generics_colons = colon_generics(source)
        for rid, kind, params in reqs:
            a = normalize(ref["responses"].get(rid, "<missing>"))
            b = normalize(got["responses"].get(rid, "<missing>"))
            if cond_attrs and kind in ("hover", "completion"):
                a = ignore_conditional_attributes(a, cond_attrs)
                b = ignore_conditional_attributes(b, cond_attrs)
            if entity_lengths and kind in ("hover", "completion"):
                a, b = ignore_type_params(a), ignore_type_params(b)
            if semicolon_strings and kind in ("hover", "completion"):
                a, b = ignore_param_strings(a), ignore_param_strings(b)
            if assoc and kind in ("hover", "completion"):
                a = ignore_slice_dimensions(a, assoc)
                b = ignore_slice_dimensions(b, assoc)
            if bound_names and kind in ("hover", "completion"):
                a = ignore_associate_attributes(a, bound_names)
                b = ignore_associate_attributes(b, bound_names)
                a = ignore_associate_functions(a, bound_names)
                b = ignore_associate_functions(b, bound_names)
            if bound and kind in ("hover", "completion"):
                untyped = untyped_by_fortls(a, bound)
                if untyped:
                    a = forget_associate_types(a, untyped)
                    b = forget_associate_types(b, untyped)
            total += 1
            if kind == "references":
                # cross-file order follows workspace iteration order
                if isinstance(a, list) and isinstance(b, list):
                    a, b = sorted(a, key=ref_key), sorted(b, key=ref_key)
            if kind == "completion" and isinstance(b, list):
                # zfls offers the keyword arguments of the call the position
                # is in (hansec #133) and names of modules not used yet
                # (hansec #62); fortls does not
                own_items = [x for x in b if zfls_only_item(x)]
                b = [x for x in b if not zfls_only_item(x)]
                if a is None and not b and own_items:
                    # only zfls's own items (after `end`, its end statement)
                    b = None
            if kind == "completion":
                # an intrinsic with two forms completes to one of them
                # (#245); fortls's snippet mixes them
                a = [x for x in a if not two_forms_item(x)] if isinstance(a, list) else a
                b = [x for x in b if not two_forms_item(x)] if isinstance(b, list) else b
            if kind == "completion":
                # globals are listed in workspace iteration order, which is
                # hash-randomized in fortls; clients sort completions anyway
                if isinstance(a, list) and isinstance(b, list):
                    a, b = sorted(a, key=json.dumps), sorted(b, key=json.dumps)
            if kind == "completion":
                # in the entity list of a declaration zfls offers the dummy
                # arguments not declared yet, and not the name being
                # declared (#270)
                p = params.get("position") or {}
                word = declared_word(src_lines, p.get("line", -1), p.get("character", 0))
                if word and isinstance(a, list):
                    a = [x for x in a if str(x.get("label", "")).lower() != word]
                if isinstance(b, list):
                    b = [x for x in b if x.get("detail") != "argument not declared" and (not word or str(x.get("label", "")).lower() != word)]
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
            if kind == "hover" and on_include_line(path, params.get("position")):
                # hover on an included file's name shows that file, nothing
                # when it is not found (#240); fortls has no answer or one
                # for a character literal
                continue
            if (
                kind == "definition"
                and isinstance(a, dict)
                and isinstance(b, dict)
                and a.get("uri") == b.get("uri")
                and (b.get("range") or {}).get("start") == {"line": 0, "character": 0}
                and on_include_line(path, params.get("position"))
            ):
                # go to definition on an INCLUDE line opens the included
                # file at its first line; fortls gives the line of the
                # INCLUDE statement in the including file (#224)
                continue
            pos = params.get("position") or {}
            if (
                (kind in ("definition", "references") or (kind == "hover" and a is None))
                and on_macro(src_lines, macros, pos.get("line", -1), pos.get("character", 0))
            ):
                # a macro: its #define, its places, and hover on a
                # directive's line (#265)
                continue
            if (
                kind in ("hover", "definition", "references")
                and a is None
                and on_use_rename_original(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # the original name of a USE rename is the module's entity
                # (hansec #137); fortls has no answer there
                continue
            if (
                kind in ("definition", "references", "rename")
                and a is None
                and on_construct_name_or_label(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # construct names and statement labels (fortls #424)
                continue
            if (
                kind in ("definition", "references", "rename")
                and a is None
                and on_implicit_variable(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # an implicitly typed variable: its first use is its
                # definition (#849); fortls has no answer
                continue
            if (
                kind in ("hover", "definition", "references", "completion")
                and not a
                and on_enumerator_statement(src_lines, pos.get("line", -1))
            ):
                # the enumerators of an ENUM, which fortls does not read
                continue
            if (
                kind in ("hover", "definition", "references")
                and a is None
                and on_parenthesized_kind(src_lines, pos.get("line", -1))
            ):
                # a kind in parentheses, `INTEGER((4)) x` (#690), whose
                # names fortls does not read
                continue
            if (
                kind == "completion"
                and on_import_statement(src_lines, pos.get("line", -1))
                and items_within(a, b)
            ):
                # an IMPORT statement: zfls offers every name the host sees
                # (#486), fortls only those its IMPORT statements name
                continue
            if (
                kind == "hover"
                and a is not None
                and b is None
                and on_keyword_or_operator(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # a type keyword or an operator is no call of the intrinsic
                # of that name (zfls #845)
                continue
            if kind == "references" and adjacent_references(a, b, src_lines):
                # names right behind a name, `i*i` (zfls #844), which fortls
                # misses
                continue
            if kind == "references" and dollar_name_references(a, b, src_lines, pos.get("line", -1), pos.get("character", 0)):
                # a name with a `$`, which fortls cannot search for
                continue
            if (
                kind == "completion"
                and a is None
                and b == []
                and in_string_with_bang(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # inside a string that holds a `!` (zfls #842): fortls reads
                # the `!` as a comment
                continue
            if (
                kind in ("hover", "definition", "completion", "signature")
                and not a
                and after_non_code_line(src_lines, pos.get("line", -1))
            ):
                # a statement continued across a directive or comment line
                # (zfls #259); fortls sees only its part after that line
                continue
            if kind == "hover" and a is None and any(m in json.dumps(b) for m in ("Implicitly typed (not declared)", "Fortran keyword", "OpenMP directive", "OpenACC directive")):
                # the implicit type of a name that is not declared (hansec
                # #201); fortls has no hover there
                continue
            if kind == "hover" and "Literal constant" in json.dumps(b) and (a is None or LITERAL_HOVER.fullmatch(a.get("contents", {}).get("value", ""))):
                # the type of a literal, with its kind (fortls #125); fortls
                # shows none, or the type without its kind
                continue
            if (
                kind in ("hover", "definition", "references")
                and not a
                and on_user_operator(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # user-defined operators (hansec #95)
                continue
            if (
                kind in ("hover", "definition", "references")
                and not a
                and on_assignment(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # defined assignment (hansec #95)
                continue
            if (
                kind in ("hover", "signature")
                and a is None
                and on_zfls_only_intrinsic(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # the intrinsics fortls's table lacks: specific names
                # (`DSQRT`) and newer generic ones (`REDUCE`)
                continue
            if kind in ("hover", "definition", "references") and on_keyword_argument(src_lines, pos.get("line", -1), pos.get("character", 0)):
                # the keyword of a keyword argument is the dummy argument
                # (zfls #952); fortls takes a name of the caller, or none
                continue
            if kind == "hover" and a is None and on_name_in(src_lines, generics_colons, pos.get("line", -1), pos.get("character", 0)):
                # a generic whose MODULE PROCEDURE list starts with `::`,
                # which fortls reads as no specifics (zfls #963)
                continue
            if (
                kind == "signature"
                and a is None
                and isinstance(b, dict)
                and in_constructor_or_group(src_lines, pos.get("line", -1), pos.get("character", 0))
            ):
                # inside an array constructor or parentheses, the call
                # around them (hansec #60); fortls answers null
                continue
            if kind == "signature" and a is None and isinstance(b, dict) and "activeSignature" in b:
                # signature help on a generic interface: a signature per
                # procedure (fortls #6); fortls has none
                continue
            if kind == "definition" and generic_specific_definition(src_lines, a, b):
                continue
            if kind == "references" and use_rename_extras(src_lines, a, b):
                # references also find the original name on USE rename lines
                # (hansec #137), which fortls misses
                continue
            if kind == "references" and separate_procedure_refs(a, b):
                # references to a separate module procedure include its
                # interface and implementation (hansec issue 168)
                continue
            if kind == "references" and implicit_result_refs(a, b):
                # a function without RESULT and its result variable are
                # one name (zfls #228)
                continue
            if kind == "references" and use_alias_refs(a, b):
                # references follow names that USE statements rename
                # (zfls #233)
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
