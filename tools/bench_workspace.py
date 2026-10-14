"""Compare zfls and Python fortls on a large Fortran workspace.

Copies the workspace to a temporary directory and drives each server
through the same LSP session, measuring:

- workspace initialization (`initialize`, which parses every file);
- opening the largest file until its diagnostics arrive;
- latency of hover, definition, references, completion and signature help
  at positions sampled across that file;
- incremental edits to that file, each followed by a hover, and saves,
  each followed by a request (a save re-links the workspace);
- peak memory of the server process (Windows and Linux).

    python tools/bench_workspace.py PATH/TO/json-fortran \\
        [--zfls zig-out/bin/zfls] [--fortls ../fortls] [--only zfls]

Build zfls in a release mode first (`zig build -Doptimize=ReleaseSafe`):
Debug builds are much slower.
"""

import argparse
import ctypes
import os
import re
import shutil
import statistics
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))
import differential  # noqa: E402
import stress_edit  # noqa: E402

FORTRAN_EXTS = {".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp"}
WORD = re.compile(r"\b[A-Za-z_]\w*\b")
REQUESTS = ("hover", "definition", "references", "completion", "signature")


def peak_memory(proc) -> int | None:
    """Peak resident memory of a running process, in bytes."""
    if sys.platform == "win32":
        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_ulong),
                ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]
        c = Counters()
        c.cb = ctypes.sizeof(c)
        psapi = ctypes.WinDLL("psapi")
        psapi.GetProcessMemoryInfo.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_ulong,
        ]
        ok = psapi.GetProcessMemoryInfo(
            ctypes.c_void_p(int(proc._handle)), ctypes.byref(c), c.cb
        )
        return c.PeakWorkingSetSize if ok else None
    status = Path(f"/proc/{proc.pid}/status")
    if status.exists():
        m = re.search(r"VmHWM:\s+(\d+) kB", status.read_text())
        return int(m.group(1)) * 1024 if m else None
    return None


def largest_file(root: Path) -> Path:
    files = [
        p for p in root.rglob("*")
        if p.is_file() and p.suffix.lower() in FORTRAN_EXTS
    ]
    return max(files, key=lambda p: p.stat().st_size)


def positions(text: str, count: int) -> list[tuple[str, dict]]:
    """Request kinds and positions spread evenly over the file."""
    lines = text.split("\n")
    words = []
    for ln, line in enumerate(lines):
        code = line.split("!", 1)[0]
        for m in WORD.finditer(code):
            words.append((ln, m.start() + 1, m.end()))
    calls = [
        (ln, m.end()) for ln, line in enumerate(lines)
        for m in re.finditer(r"\w\(", line.split("!", 1)[0])
    ]
    out = []
    step = max(1, len(words) // count)
    for i, (ln, inside, end) in enumerate(words[::step][:count]):
        kind = REQUESTS[i % 4]
        col = end if kind == "completion" else inside
        out.append((kind, {"line": ln, "character": col}))
    step = max(1, len(calls) // max(1, count // 4))
    for ln, col in calls[::step][:count // 4]:
        out.append(("signature", {"line": ln, "character": col}))
    return out


METHODS = {
    "hover": "textDocument/hover",
    "definition": "textDocument/definition",
    "references": "textDocument/references",
    "completion": "textDocument/completion",
    "signature": "textDocument/signatureHelp",
}


def timed(server, method, params) -> float:
    start = time.perf_counter()
    server.request(method, params)
    return time.perf_counter() - start


def run(name: str, cmd: list[str], src: Path, args) -> dict:
    tmp = Path(tempfile.mkdtemp(prefix=f"bench_{name}_"))
    work = tmp / "ws"
    shutil.copytree(src, work, ignore=shutil.ignore_patterns(".git"))
    big = largest_file(work)
    uri = big.as_uri()
    text = big.read_text(encoding="utf-8", errors="replace")
    result: dict = {"file": big.relative_to(work).as_posix(),
                    "lines": text.count("\n") + 1}
    server = stress_edit.Server(cmd + ["--incremental_sync"],
                                tmp / "stream.bin")
    try:
        start = time.perf_counter()
        server.request("initialize", {"rootUri": work.as_uri(),
                                      "rootPath": str(work),
                                      "capabilities": {}})
        result["init"] = time.perf_counter() - start
        server.send("initialized", {})

        start = time.perf_counter()
        server.send("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "fortran", "version": 1,
            "text": text,
        }})
        server.sync()
        result["open"] = time.perf_counter() - start

        lat: dict[str, list[float]] = {k: [] for k in REQUESTS}
        td = {"uri": uri}
        for kind, pos in positions(text, args.requests):
            params = {"textDocument": td, "position": pos}
            if kind == "references":
                params["context"] = {"includeDeclaration": True}
            lat[kind].append(timed(server, METHODS[kind], params))
        result["requests"] = lat

        # edits: a declaration after each of the first `implicit none`s
        # of procedures, then a hover there
        lines = text.split("\n")
        targets = [
            i for i, line in enumerate(lines)
            if line.strip().lower() == "implicit none"
        ][1:args.edits + 1]
        edit_times = []
        version = 1
        for n, ln in enumerate(targets):
            line = ln + 1 + n  # earlier insertions moved it down
            version += 1
            start = time.perf_counter()
            server.send("textDocument/didChange", {
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{
                    "range": {"start": {"line": line, "character": 0},
                              "end": {"line": line, "character": 0}},
                    "text": f"    integer :: zz_bench_{n}\n",
                }],
            })
            server.request("textDocument/hover", {
                "textDocument": td,
                "position": {"line": line, "character": 16},
            })
            edit_times.append(time.perf_counter() - start)
        result["edit"] = edit_times

        save_times = []
        for _ in range(args.saves):
            start = time.perf_counter()
            server.send("textDocument/didSave", {"textDocument": td})
            server.sync()
            save_times.append(time.perf_counter() - start)
        result["save"] = save_times
        result["memory"] = peak_memory(server.proc)
        server.close()
    finally:
        if server.proc.poll() is None:
            server.proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    return result


def ms(x: float) -> str:
    return f"{x * 1000:8.1f} ms"


def summary(values: list[float]) -> str:
    if not values:
        return "n/a"
    s = sorted(values)
    p95 = s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]
    return (f"median {ms(statistics.median(s))}  p95 {ms(p95)}  "
            f"max {ms(s[-1])}  (n={len(s)})")


def report(name: str, r: dict) -> None:
    print(f"\n== {name}: {r['file']} ({r['lines']} lines)")
    print(f"  initialize       {ms(r['init'])}")
    print(f"  open             {ms(r['open'])}")
    for kind, values in r["requests"].items():
        print(f"  {kind:<16} {summary(values)}")
    print(f"  edit + hover     {summary(r['edit'])}")
    print(f"  save + request   {summary(r['save'])}")
    mem = r["memory"]
    print(f"  peak memory      "
          f"{f'{mem / 2**20:8.1f} MiB' if mem else 'n/a'}")


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("workspace", type=Path)
    ap.add_argument("--zfls", default=str(REPO / "zig-out" / "bin" / "zfls"))
    ap.add_argument("--fortls", type=Path, default=REPO.parent / "fortls",
                    help="fortls checkout, run from source")
    ap.add_argument("--only", choices=["zfls", "fortls"])
    ap.add_argument("--requests", type=int, default=200,
                    help="sampled requests (default 200)")
    ap.add_argument("--edits", type=int, default=20)
    ap.add_argument("--saves", type=int, default=5)
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    src = args.workspace.resolve()
    if args.only != "fortls":
        report("zfls", run("zfls", [str(Path(args.zfls).resolve())], src,
                           args))
    if args.only != "zfls":
        os.environ["PYTHONPATH"] = os.pathsep.join(
            [differential.write_stubs(), str(args.fortls.resolve())]
        )
        cmd = [sys.executable, "-m", "fortls", "--disable_autoupdate"]
        report("fortls", run("fortls", cmd, src, args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
