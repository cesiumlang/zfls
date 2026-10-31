"""Run the fortls language-server test suite against the zfls executable.

The fortls tests talk to the server purely through JSON-RPC over stdio, so
they can be replayed against zfls unchanged. This runner needs no third-party
packages: `pytest`, `json5` and `packaging` are replaced by minimal stubs.

Usage:
    python tests/fortls_parity.py [--fortls PATH] [--zfls EXE] [-k SUBSTR] [-v]
"""

from __future__ import annotations

import argparse
import importlib
import inspect
import os
import shutil
import sys
import tempfile
import traceback
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

# Test modules exercising the server over JSON-RPC (others test Python
# internals of fortls directly).
SERVER_TEST_MODULES = [
    "test_server",
    "test_server_completion",
    "test_server_definitions",
    "test_server_diagnostics",
    "test_server_documentation",
    "test_server_hover",
    "test_server_implementation",
    "test_server_init",
    "test_server_messages",
    "test_server_references",
    "test_server_rename",
    "test_server_signature_help",
    "test_preproc",
]


class Skip(Exception):
    pass


def intrinsic_hover_replacement(mod):
    """`test_server_hover::test_intrinsics` compares the hover text with
    fortls's intrinsic docs; zfls ships them reformatted for markdownlint
    (src/data/intrinsics/*.md), so compare with those instead."""

    def test():
        test_dir = mod.test_dir
        string = mod.write_rpc_request(
            1, "initialize", {"rootPath": str(test_dir / "hover")}
        )
        file_path = test_dir / "hover" / "functions.f90"
        string += mod.hover_req(file_path, 39, 23)
        errcode, results = mod.run_request(string, fortls_args=["-n", "1"])
        assert errcode == 0
        doc = REPO / "src" / "data" / "intrinsics" / "SIZE.md"
        expected = "\n-----\n" + doc.read_text(encoding="utf-8")
        mod.validate_hover(results, [expected])

    return test


# Tests whose expectations zfls deliberately does not match verbatim, with a
# replacement test implementing the zfls expectation.
KNOWN_DEVIATIONS = {
    "test_server_hover::test_intrinsics": intrinsic_hover_replacement,
}


def install_stubs():
    """Minimal stand-ins for pytest, json5 and packaging."""
    pytest = types.ModuleType("pytest")

    class _Mark:
        @staticmethod
        def parametrize(names, values):
            def deco(fn):
                fn._params = getattr(fn, "_params", []) + [(names, values)]
                return fn

            return deco

    pytest.mark = _Mark()

    def fixture(*args, **_kwargs):
        def deco(fn):
            fn._is_fixture = True
            return fn

        if args and callable(args[0]):
            return deco(args[0])
        return deco

    pytest.fixture = fixture

    def skip(msg=""):
        raise Skip(msg)

    pytest.skip = skip
    sys.modules["pytest"] = pytest

    import json

    json5 = types.ModuleType("json5")
    json5.load = json.load
    json5.loads = json.loads
    json5.dumps = json.dumps
    sys.modules["json5"] = json5

    packaging = types.ModuleType("packaging")
    version = types.ModuleType("packaging.version")

    class _V:
        def __init__(self, s):
            self.s = s
            self.is_prerelease = True

        def __gt__(self, _other):
            return False

    version.parse = lambda s: _V(s)
    packaging.version = version
    sys.modules["packaging"] = packaging
    sys.modules["packaging.version"] = version

    fversion = types.ModuleType("fortls.version")
    fversion.__version__ = "0.0.0"
    sys.modules["fortls.version"] = fversion


def run_function(mod, fn):
    """Call a test function, resolving fixtures and parametrization."""
    params = getattr(fn, "_params", None)
    cases = [{}]
    if params:
        cases = []
        for names, values in params:
            names = [n.strip() for n in names.split(",")]
            for v in values:
                if len(names) == 1:
                    cases.append({names[0]: v})
                else:
                    cases.append(dict(zip(names, v)))
    results = []
    for case in cases:
        kwargs = dict(case)
        cleanups = []
        label = fn.__name__ + (f"[{case}]" if case else "")
        try:
            for pname in inspect.signature(fn).parameters:
                if pname in kwargs:
                    continue
                if pname == "tmp_path":
                    d = Path(tempfile.mkdtemp(prefix="zfls_"))
                    kwargs[pname] = d
                    cleanups.append(
                        lambda d=d: shutil.rmtree(d, ignore_errors=True)
                    )
                    continue
                fx = getattr(mod, pname, None)
                if fx is None or not getattr(fx, "_is_fixture", False):
                    raise RuntimeError(f"unknown fixture {pname}")
                gen = fx()
                if inspect.isgenerator(gen):
                    kwargs[pname] = next(gen)
                    cleanups.append(lambda g=gen: next(g, None))
                else:
                    kwargs[pname] = gen
            fn(**kwargs)
            results.append((label, "PASS", ""))
        except Skip as e:
            results.append((label, "SKIP", str(e)))
        except Exception:
            results.append((label, "FAIL", traceback.format_exc()))
        finally:
            for c in reversed(cleanups):
                try:
                    c()
                except Exception:
                    pass
    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    exe = "zfls.exe" if os.name == "nt" else "zfls"
    ap.add_argument(
        "--fortls", default=str(REPO.parent / "fortls"),
        help="fortls repository",
    )
    ap.add_argument("--zfls", default=str(REPO / "zig-out" / "bin" / exe))
    ap.add_argument("-k", default="", help="only tests containing this")
    ap.add_argument("-v", action="store_true", help="print failure details")
    ap.add_argument("-x", action="store_true", help="stop at first failure")
    args = ap.parse_args()

    fortls_root = Path(args.fortls).resolve()
    test_dir = fortls_root / "test"
    zfls = str(Path(args.zfls).resolve())
    if not Path(zfls).is_file():
        print(f"zfls executable not found: {zfls}")
        return 2

    install_stubs()
    sys.path.insert(0, str(test_dir))
    sys.path.insert(0, str(fortls_root))

    # fortls's test helpers, importable only once test_dir is on sys.path
    setup_tests = importlib.import_module("setup_tests")

    def run_request(request, fortls_args=None):
        import shlex
        import subprocess
        from io import StringIO

        command = [zfls, "--incremental_sync"]
        if fortls_args:
            for i in fortls_args:
                command.extend(shlex.split(i, posix=False))
        pid = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        out, _ = pid.communicate(input=request.encode(), timeout=120)
        results = setup_tests.read_rpc_messages(StringIO(out.decode()))
        parsed = []
        for result in results:
            if "result" in result:
                r = result["result"]
                # zfls offers the keyword arguments of the call a completion
                # is in (hansec #133); fortls's expected lists do not have them
                if isinstance(r, list):
                    r = [
                        x for x in r
                        if not (isinstance(x, dict) and str(x.get("label", "")).endswith("=") and "filterText" in x)
                    ]
                parsed.append(r)
            elif "params" in result:
                params = result["params"]
                # zfls adds a code and source to each diagnostic (fortls
                # #438); fortls's expected diagnostics have neither
                if isinstance(params, dict):
                    for d in params.get("diagnostics", []):
                        d.pop("code", None)
                        d.pop("source", None)
                parsed.append(params)
            else:
                raise RuntimeError(f"unexpected message: {result}")
        return pid.poll(), parsed

    setup_tests.run_request = run_request

    totals = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    failures = []
    for modname in SERVER_TEST_MODULES:
        mod = importlib.import_module(modname)
        mod.run_request = run_request
        for name, fn in inspect.getmembers(mod, inspect.isfunction):
            if not name.startswith("test_") or fn.__module__ != modname:
                continue
            if args.k and args.k not in f"{modname}::{name}":
                continue
            replacement = KNOWN_DEVIATIONS.get(f"{modname}::{name}")
            if replacement is not None:
                fn = replacement(mod)
                fn.__name__ = name + "[zfls]"
            for label, status, info in run_function(mod, fn):
                totals[status] += 1
                print(f"{status} {modname}::{label}")
                if status == "FAIL":
                    failures.append((f"{modname}::{label}", info))
                    if args.v:
                        print(info)
                    if args.x:
                        break
    print(
        f"\n{totals['PASS']} passed, {totals['FAIL']} failed, "
        f"{totals['SKIP']} skipped"
    )
    return 1 if totals["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
