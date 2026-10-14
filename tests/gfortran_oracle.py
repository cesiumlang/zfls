"""Cross-check zfls's symbol extraction against gfortran's parse tree.

Every Fortran file in the corpus that gfortran accepts is dumped with
``-fdump-fortran-original``. The user-declared scopes and entities found by
gfortran (modules, procedures, derived types and their components, type-bound
procedures, variables and parameters) are compared with the object tree zfls
prints with ``--debug_parser``. gfortran serves as an independent oracle for
the Fortran semantics zfls approximates with line-based parsing.

Usage:
    python tests/gfortran_oracle.py [--gfortran EXE] [--zfls EXE] [-v]
                                    [PATH ...]

PATH defaults to tests/fortran (the zfls fixtures). Directories are searched
recursively; files gfortran rejects are skipped.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
EXE = "zfls.exe" if os.name == "nt" else "zfls"
FORTRAN_EXTS = {".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp"}

SYMTREE = re.compile(r"^(\s*)symtree: '([^']*)'\s*\|\| symbol: '([^']*)'(.*)$")
PROC_NAME = re.compile(r"^(\s*)procedure name = (\S+)")
ATTRS = re.compile(r"^\s*attributes: \((.*)\)")
COMPONENT = re.compile(r"^\s*\((\w+) ")
BINDING = re.compile(r"^\s*PROCEDURE[^:]*:: (\w+)")
GENERIC_BINDING = re.compile(r"^\s*GENERIC[^:]*:: (\w+)")

# gfortran symbol attributes of entities zfls does not report
SKIP_ATTRS = {
    "ARTIFICIAL", "INTRINSIC-PROC", "USE-ASSOC", "MODULE", "PROGRAM",
    "IFSRC-IFBODY",
}

# Attributes of procedures declared in the file (as opposed to procedures
# that are only called)
DECLARED_PROC_ATTRS = {
    "IFSRC-DECL", "CONTAINED", "MODULE-PROC", "GENERIC", "DUMMY", "EXTERNAL",
}

# Known limitation (see main): dummy arguments of "MODULE PROCEDURE" bodies.

# Entity categories compared between the two trees
VAR, PROC, TYPE, SCOPE = "variable", "procedure", "type", "scope"
# Procedure pointer components: gfortran variable, zfls type-bound method
SAME_KIND = {(VAR, PROC)}
ZFLS_KINDS = {
    # -1: MODULE PROCEDURE body in a submodule (plain scope until linked)
    "-1": PROC, "1": SCOPE, "8": SCOPE, "2": PROC, "3": PROC, "4": TYPE,
    "5": PROC, "6": VAR, "7": PROC,
}


def find_gfortran() -> str | None:
    for cand in ("gfortran", r"C:\msys64\ucrt64\bin\gfortran.exe"):
        path = shutil.which(cand) or (cand if Path(cand).is_file() else None)
        if path:
            return path
    return None


def gfortran_entities(gfortran: str, src: Path, workdir: Path):
    """Return {fqsn: category} from gfortran's dump, or None on errors."""
    cmd = [
        gfortran, "-fsyntax-only", "-fdump-fortran-original",
        "-J", str(workdir), "-I", str(workdir),
    ]
    if src.suffix != src.suffix.lower() or src.suffix.lower() == ".fpp":
        cmd.append("-cpp")
    if src.suffix.lower() in (".f", ".for"):
        cmd.append("-ffixed-form")
    proc = subprocess.run(
        cmd + [str(src)], capture_output=True, text=True, errors="replace",
        cwd=workdir,
    )
    if proc.returncode != 0:
        return None
    lines = proc.stdout.splitlines()
    entities: dict[str, str] = {}
    dummies: set[str] = set()
    # submodule namespace -> its parent's
    parents: dict[str, str] = {}
    # stack of (indent, namespace path)
    stack: list[tuple[int, str]] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = PROC_NAME.match(line)
        if m:
            indent, name = len(m.group(1)), m.group(2).lower()
            while stack and stack[-1][0] >= indent:
                stack.pop()
            # submodules are named "ancestor.submodule"
            if "." in name and not stack:
                parent, name = name.rsplit(".", 1)
                parents[name] = parent.rsplit(".", 1)[-1]
            name = name.rsplit(".", 1)[-1]
            path = f"{stack[-1][1]}::{name}" if stack else name
            stack.append((indent, path))
            i += 1
            continue
        m = SYMTREE.match(line)
        if not m or not stack:
            i += 1
            continue
        name = m.group(3).lower()
        from_host = "from namespace" in m.group(4)
        # collect this symbol's detail lines
        block = []
        i += 1
        while i < len(lines) and not SYMTREE.match(lines[i]) \
                and not PROC_NAME.match(lines[i]) \
                and "Namespace:" not in lines[i]:
            block.append(lines[i])
            i += 1
        attrs = ""
        for b in block:
            am = ATTRS.match(b)
            if am:
                attrs = am.group(1)
                break
        # e.g. "USE-ASSOC(shapes)" -> "USE-ASSOC"
        tokens = {t.split("(")[0] for t in attrs.split()}
        ns = stack[-1][1]
        # Attributes gfortran 13 does not print, from what every version
        # does: generic interfaces list their procedures; the interface of a
        # separate module procedure is an external module procedure; a
        # submodule sees what its parent declares unless it contains it
        if any(b.strip().startswith("Generic interfaces:") for b in block):
            tokens.add("GENERIC")
        if {"MODULE-PROCEDURE", "EXTERNAL"} <= tokens \
                and "CONTAINED" not in tokens:
            tokens.add("IFSRC-IFBODY")
        if ns in parents and f"{parents[ns]}::{name}" in entities \
                and "CONTAINED" not in tokens:
            tokens.add("USED-IN-SUBMODULE")
        own_name = ns.rsplit("::", 1)[-1]
        skip = (
            from_host
            or name.startswith("_")
            or name == own_name
            or not tokens.isdisjoint(SKIP_ATTRS)
            # parent-module entities seen from a submodule
            or (
                "USED-IN-SUBMODULE" in tokens
                and "MODULE-PROCEDURE" not in tokens
            )
        )
        if skip:
            continue
        fq = f"{ns}::{name}"
        if "DERIVED" in tokens:
            entities[fq] = TYPE
            in_components = False
            for b in block:
                if b.strip().startswith("components:"):
                    in_components = True
                    continue
                if b.strip().startswith(("hash:", "Procedure bindings")):
                    in_components = False
                cm = COMPONENT.match(b) if in_components else None
                # the parent type of an extension is a component too
                if cm and f"(DERIVED {cm.group(1)})" in b.lower().replace(
                    "(derived", "(DERIVED"
                ):
                    cm = None
                if cm:
                    entities[f"{fq}::{cm.group(1).lower()}"] = VAR
                bm = BINDING.match(b) or GENERIC_BINDING.match(b)
                if bm:
                    entities[f"{fq}::{bm.group(1).lower()}"] = PROC
        elif "PROCEDURE" in tokens:
            if "ABSTRACT" in tokens:
                continue  # abstract interface
            if tokens.isdisjoint(DECLARED_PROC_ATTRS):
                continue  # only referenced (implicit external procedure)
            # structure constructors are generics named like their type
            entities.setdefault(fq, PROC)
        elif tokens & {"VARIABLE", "PARAMETER"}:
            entities[fq] = VAR
            if "DUMMY" in tokens:
                dummies.add(fq)
    return entities, dummies


def zfls_entities(zfls: str, src: Path):
    """Return {fqsn: category} from the zfls object tree."""
    proc = subprocess.run(
        [zfls, "--debug_parser", "--debug_filepath", str(src)],
        capture_output=True, text=True, errors="replace",
    )
    out = proc.stdout
    if "Object Tree" not in out:
        return None, set()
    tree = out.split("Object Tree", 1)[1].split("Exportable Objects", 1)[0]
    entities: dict[str, str] = {}
    bodies: set[str] = set()
    rows = re.findall(r"^\s*(-?\d+): (\S+)$", tree, re.M)
    # block, select, do, where, if, associate and enum scopes
    constructs = {f for k, f in rows if 9 <= int(k) <= 15}
    for kind, fqsn in rows:
        if "#gen_int" in fqsn.lower():
            continue  # interface bodies (not listed by the oracle)
        if fqsn in constructs:
            continue
        # entities of construct scopes belong to the enclosing procedure
        # in gfortran
        parts = fqsn.split("::")
        kept = [
            p for i, p in enumerate(parts)
            if "::".join(parts[: i + 1]) not in constructs
        ]
        fqsn = "::".join(kept)
        if kind == "-1":
            bodies.add(fqsn)
        entities[fqsn] = ZFLS_KINDS.get(kind, "other")
    # scopes found by gfortran as namespaces, not entities
    return {k: v for k, v in entities.items() if "::" in k}, bodies


def function_results(zfls_map: dict[str, str]) -> set[str]:
    """zfls lists a function's implicit result variable as a child."""
    out = set()
    for fq in zfls_map:
        parts = fq.split("::")
        if len(parts) >= 2 and parts[-1] == parts[-2]:
            out.add(fq)
    return out


def collect(paths: list[Path]) -> list[Path]:
    files = []
    for p in paths:
        if p.is_dir():
            files += sorted(
                f for f in p.rglob("*") if f.suffix.lower() in FORTRAN_EXTS
            )
        elif p.is_file():
            files.append(p)
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gfortran", default=None)
    ap.add_argument("--zfls", default=str(REPO / "zig-out" / "bin" / EXE))
    ap.add_argument("-v", action="store_true", help="list skipped files")
    ap.add_argument("paths", nargs="*", type=Path)
    args = ap.parse_args()

    gfortran = args.gfortran or find_gfortran()
    if not gfortran:
        print("gfortran not found; skipping")
        return 0
    files = collect(args.paths or [HERE / "fortran"])
    checked = mismatched = 0
    with tempfile.TemporaryDirectory(prefix="zfls_gfortran_") as tmp:
        workdir = Path(tmp)
        for src in files:
            res = gfortran_entities(gfortran, src.resolve(), workdir)
            if res is None:
                if args.v:
                    print(f"SKIP {src} (rejected by gfortran)")
                continue
            ref, dummies = res
            got, bodies = zfls_entities(args.zfls, src.resolve())
            if got is None:
                print(f"FAIL {src}: zfls produced no object tree")
                mismatched += 1
                continue
            for fq in function_results(got):
                got.pop(fq)
            # Arguments of "MODULE PROCEDURE name" bodies come from the
            # interface in the ancestor module; zfls only attaches them when
            # linking a workspace, which --debug_parser does not do.
            for fq in [d for d in dummies if d.rsplit("::", 1)[0] in bodies]:
                ref.pop(fq)
            checked += 1
            missing = sorted(set(ref) - set(got))
            extra = sorted(set(got) - set(ref))
            kinds = sorted(
                k for k in set(ref) & set(got)
                if ref[k] != got[k] and (ref[k], got[k]) not in SAME_KIND
            )
            if missing or extra or kinds:
                mismatched += 1
                print(f"FAIL {src}")
                for k in missing:
                    print(f"   missing in zfls: {k} ({ref[k]})")
                for k in extra:
                    print(f"   only in zfls:    {k} ({got[k]})")
                for k in kinds:
                    print(f"   kind differs:    {k} gfortran={ref[k]} "
                          f"zfls={got[k]}")
            else:
                print(f"OK   {src}: {len(ref)} entities")
    print(f"\n{checked} files checked, {mismatched} with differences")
    return 1 if mismatched else 0


if __name__ == "__main__":
    sys.exit(main())
