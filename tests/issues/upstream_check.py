"""Run the fixtures of tests/issues/*.zig through Python fortls and through
zfls, side by side, using their debug command line options.

    python tests/issues/upstream_check.py --zfls zig-out/bin/zfls [--fortls ../fortls] [ISSUE ...]

The fixtures are read from the Zig test sources. This is how the "fortls"
column of README.md was checked (fortls commit 0392beb); the third-party
packages fortls imports are replaced by the stubs of tests/differential.py.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "tests"))
import differential  # noqa: E402  (for the stubs of fortls's third-party imports)

STUBS = differential.write_stubs()
ENV = dict(os.environ, PYTHONPATH=STUBS + os.pathsep + r"C:\scratch\git\fortls")
ZFLS = str(REPO / "zig-out" / "bin" / "zfls.exe")


def fixtures():
    """issue number -> {file name: text} parsed from the Zig test sources"""
    out = {}
    for src in sorted((REPO / "tests" / "issues").glob("*.zig")):
        lines = src.read_text(encoding="utf-8").split("\n")
        issue = None
        i = 0
        while i < len(lines):
            m = re.match(r'test "#(\d+)', lines[i])
            if m:
                issue = int(m.group(1))
                out[issue] = {}
            m = re.search(r'\.name = "([^"]+)"', lines[i]) if issue else None
            if m:
                name = m.group(1)
                # the text starts on this line or one of the next two
                j = i
                while j < i + 3 and ".text" not in lines[j]:
                    j += 1
                inline = re.search(r'\.text = "((?:[^"\\]|\\.)*)"', lines[j])
                if inline:
                    out[issue][name] = inline.group(1).replace("\\n", "\n")
                else:
                    k = j + 1
                    text = []
                    while lines[k].lstrip().startswith("\\\\"):
                        text.append(lines[k].lstrip()[2:])
                        k += 1
                    out[issue][name] = "\n".join(text) + "\n"
            i += 1
    return out


def pos(text, needle, nth, plus):
    idx = -1
    for _ in range(nth + 1):
        idx = text.index(needle, idx + 1)
    before = text[:idx]
    line = before.count("\n")
    col = idx - (before.rfind("\n") + 1) + plus
    return line + 1, col + 1  # the CLI takes 1-based lines and columns


def run(exe, cwd, args):
    cmd = ([sys.executable, "-m", "fortls"] if exe == "py" else [ZFLS]) + args
    r = subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    tb = r.stderr[r.stderr.rfind('Traceback'):][-400:] if 'Traceback' in r.stderr else ''
    return (r.stdout if r.stdout.strip() else r.stderr[-600:]) + (chr(10) + tb if tb else '')


def section(out):
    """The part of the debug output after the last separator line pair"""
    parts = re.split(r"=+\n", out)
    return [p for p in parts if p.strip()][-1].strip() if parts else out


def main(only):
    global ENV, ZFLS
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--zfls", required=True, help="the zfls executable")
    ap.add_argument("--fortls", default=str(REPO.parent / "fortls"), help="a fortls checkout")
    ap.add_argument("issues", nargs="*", type=int, help="issue numbers (default: all)")
    args = ap.parse_args()
    ZFLS = str(Path(args.zfls).resolve())
    ENV = dict(os.environ, PYTHONPATH=STUBS + os.pathsep + args.fortls)
    only = set(args.issues)
    fx = fixtures()
    # (issue, file, request kind, needle, nth, plus, extra args)
    cases = [
        (406, "t.f90", "diag", None, 0, 0, []),
        (534, "t.f", "hover", "PARAM1", 1, 1, []),
        (481, "src/main.F90", "hover", "from_vec = 1", 0, 1, []),
        (481, "src/main.F90", "def", "finclude", 0, 1, []),
        (568, "user_fails.f90", "diag", None, 0, 0, []),
        (519, "t.f90", "diag", None, 0, 0, []),
        (489, "t.f", "diag", None, 0, 0, ["--max_line_length", "72", "--max_comment_line_length", "-1"]),
        (264, "t.f", "diag", None, 0, 0, []),
        (470, "t.f90", "diag", None, 0, 0, []),
        (172, "t.f90", "diag", None, 0, 0, []),
        (72, "t.f90", "diag", None, 0, 0, []),
        (485, "t.f90", "diag", None, 0, 0, []),
        (532, "t.f90", "diag", None, 0, 0, []),
        (292, "t.f90", "diag", None, 0, 0, []),
        (411, "invalid_comment.f", "diag", None, 0, 0, []),
        (433, "t.f90", "diag", None, 0, 0, []),
        (486, "a.F90", "diag", None, 0, 0, []),
        (483, "ext.f90", "hover", "call dgesv", 0, 6, []),
        (281, "t.f90", "hover", "b()", 0, 0, []),
        (237, "t.f90", "hover", "call sub_no_doc", 0, 6, []),
        (124, "t.f90", "hover", "real(sp)", 0, 5, []),
        (118, "t.f", "hover", "fff(1.2", 0, 1, []),
        (108, "t.f90", "hover", "ARRAY (3)", 0, 1, []),
        (203, "t.f90", "hover", "print *, n", 0, 9, []),
        (23, "t.f90", "impl", "sub1", 0, 1, []),
        (87, "t.f90", "sig", "arr(2, 3), 1", 0, 11, []),
        (433, "t.f90", "hover", "y => y(3)", 0, 0, []),
        (433, "t.f90", "hover", "print *,y", 0, 8, []),
        (486, "main.F90", "wsym", "a", 0, 0, []),
        (236, "hellosub.F90", "parser", None, 0, 0, []),
        (536, "main.F90", "wsym", "foo_mod", 0, 0, ["--pp_defs", '{"HAVE_FOO":"1"}']),
        (498, "src/a.F90", "def", "sample.inc", 0, 2, []),
        (495, "file.f90", "def", "global_variable", 0, 2, []),
        (322, "t.f90", "rename", "myfun(x)", 0, 0, []),
        (86, "t.f90", "rename", "some)", 0, 0, []),
        (52, "t.f90", "rename", "localname = 4", 0, 0, []),
    ]
    for issue, fname, kind, needle, nth, plus, extra in cases:
        if only and issue not in only:
            continue
        d = Path(tempfile.mkdtemp(prefix=f"issue{issue}_"))
        for name, text in fx[issue].items():
            p = d / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8", newline="\n")
        base = ["--debug_rootpath", ".", "--debug_filepath", fname]
        if kind == "diag":
            args = base + ["--debug_diagnostics"] + extra
        elif kind == "wsym":
            args = base + ["--debug_workspace_symbols", needle] + extra
        elif kind == "parser":
            args = base + ["--debug_parser"] + extra
        else:
            line, col = pos(fx[issue][fname], needle, nth, plus)
            args = base + [f"--debug_line", str(line), "--debug_char", str(col)]
            args += {
                "hover": ["--debug_hover"],
                "impl": ["--debug_implementation"],
                "def": ["--debug_definition"],
                "sig": ["--debug_signature"],
                "rename": ["--debug_rename", "other"],
            }[kind]
        print("=" * 70)
        print(f"#{issue} {kind} {fname}")
        for exe in ("py", "zfls"):
            out = run(exe, d, args)
            print(f"  [{exe}] " + section(out).replace("\n", "\n         ")[:700])
        shutil.rmtree(d, ignore_errors=True)


main(None)
