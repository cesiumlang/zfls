"""Long randomized editing sessions against zfls.

Drives one zfls process through thousands of seeded random edits on a
temporary copy of a Fortran workspace, with saves, close/reopen and requests
mixed in, the way an editor would. It fails on:

- a crash, hang (request timeout) or unclean exit, including the Debug
  build's allocator reports (leaks, double frees) on stderr;
- a request without a response, or with an error response;
- stale state: at the end, every edited file's symbols and diagnostics must
  equal those of a fresh zfls started on the final text (not checked with
  --preprocessor, whose `#define`s legitimately depend on history).

Run a Debug build (the default `zig build`) so safety checks are on. A
failure writes a reproduction directory (initial files, the exact message
stream sent) and prints its path.
"""

import argparse
import json
import queue
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FORTRAN_EXTS = {".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp",
                ".F", ".F90", ".h", ".inc"}
REQUEST_TIMEOUT = 120.0
ALLOCATOR_REPORTS = re.compile(
    r"panic|leaked|Double free|Invalid free|Segmentation fault|"
    r"error\(SafeAllocator\)",
    re.I,
)
# Non-ASCII text to splice in: multi-byte UTF-8, and surrogate pairs in
# UTF-16 (the emoji), to exercise position conversion.
UNICODE_BITS = ["é", "∑", "😀", "日本", "ß"]
WORD = re.compile(r"[A-Za-z_]\w*")
# Error responses that mirror an exception Python fortls raises
EXPECTED_ERRORS = {
    # references/highlight on an intrinsic: fortls's AttributeError on
    # the intrinsic object's missing FQSN
    "IntrinsicHasNoFQSN",
}


def utf16_len(s: str) -> int:
    return len(s.encode("utf-16-le")) // 2


def utf16_to_index(line: str, units: int) -> int:
    """The str index of UTF-16 offset `units` in `line`."""
    n = 0
    for i, ch in enumerate(line):
        if n >= units:
            return i
        n += 2 if ord(ch) > 0xFFFF else 1
    return len(line)


class Doc:
    """One open document's text, edited the way the client sends it."""

    def __init__(self, path: Path, text: str):
        self.path = path
        self.uri = path.as_uri()
        self.text = text
        self.version = 1

    def lines(self) -> list[str]:
        return self.text.split("\n")

    def offset(self, line: int, char: int) -> int:
        ls = self.lines()
        line = min(line, len(ls) - 1)
        base = sum(len(x) + 1 for x in ls[:line])
        return base + utf16_to_index(ls[line], char)

    def apply(self, rng: dict, new: str) -> None:
        s = self.offset(rng["start"]["line"], rng["start"]["character"])
        e = self.offset(rng["end"]["line"], rng["end"]["character"])
        self.text = self.text[:s] + new + self.text[e:]

    def position(self, line: int, index: int) -> dict:
        """The LSP position of str index `index` on `line`."""
        text = self.lines()[line]
        return {"line": line, "character": utf16_len(text[:index])}


class Server:
    """A zfls process with a reader thread collecting its messages."""

    def __init__(self, cmd: list[str], log_path: Path):
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.log = open(log_path, "wb")
        self.messages: queue.Queue = queue.Queue()
        self.responses: dict[int, dict] = {}
        self.diagnostics: dict[str, list] = {}
        self.stderr = b""
        self.next_id = 100
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read(self) -> None:
        out = self.proc.stdout
        while True:
            length = None
            while True:
                line = out.readline()
                if not line:
                    self.messages.put(None)
                    return
                line = line.strip()
                if not line:
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1])
            if length is None:
                continue
            self.messages.put(json.loads(out.read(length)))

    def _read_err(self) -> None:
        self.stderr = self.proc.stderr.read()

    def send(self, method: str, params, rid=None) -> None:
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if rid is not None:
            body["id"] = rid
        data = json.dumps(body, separators=(",", ":")).encode()
        frame = b"Content-Length: %d\r\n\r\n" % len(data) + data
        self.log.write(frame)
        self.proc.stdin.write(frame)
        self.proc.stdin.flush()

    def _take(self, timeout: float) -> dict | None:
        msg = self.messages.get(timeout=timeout)
        if msg is None:
            raise ConnectionError("server closed its output")
        if msg.get("method") == "textDocument/publishDiagnostics":
            p = msg["params"]
            self.diagnostics[p["uri"]] = p["diagnostics"]
        elif "id" in msg and ("result" in msg or "error" in msg):
            self.responses[msg["id"]] = msg
        return msg

    def request(self, method: str, params) -> dict:
        self.next_id += 1
        rid = self.next_id
        self.send(method, params, rid)
        deadline = time.monotonic() + REQUEST_TIMEOUT
        while rid not in self.responses:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"no response to {method} #{rid}")
            try:
                self._take(left)
            except queue.Empty:
                continue
        return self.responses.pop(rid)

    def sync(self) -> None:
        """Waits until everything sent so far has been handled."""
        self.request("textDocument/documentSymbol",
                     {"textDocument": {"uri": "file:///sync.f90"}})

    def close(self) -> int:
        self.request("shutdown", None)
        self.send("exit", None)
        self.proc.stdin.close()
        try:
            code = self.proc.wait(timeout=REQUEST_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            raise TimeoutError("server did not exit")
        while True:
            try:
                if self._take(1.0) is None:
                    break
            except (queue.Empty, ConnectionError):
                break
        time.sleep(0.2)
        self.log.close()
        return code


def server_cmd(args) -> list[str]:
    sync = ["--incremental_sync"] if args.incremental else []
    return [args.zfls] + sync + args.zfls_arg


def uses_preprocessor(path: Path) -> bool:
    text = path.read_text(encoding="utf-8", errors="replace")
    return any(x.lstrip().startswith("#") for x in text.split("\n"))


def source_files(root: Path, preprocessor: bool) -> list[Path]:
    """The Fortran files under `root`; without `preprocessor`, those with
    no directives (every parse adds its `#define`s to one table that later
    parses see, as in fortls, so a session's history changes what a fresh
    start would preprocess)."""
    return sorted(
        p for p in root.rglob("*")
        if p.is_file() and p.suffix in FORTRAN_EXTS
        and (preprocessor or not uses_preprocessor(p))
    )


def corpus_lines(files: list[Path]) -> list[str]:
    out = []
    for p in files:
        text = p.read_text(encoding="utf-8", errors="replace")
        out += [x for x in text.split("\n") if x.strip()]
    return out


class Session:
    def __init__(self, args, seed: int, src: Path, work: Path):
        self.rng = random.Random(seed)
        self.args = args
        self.work = work
        self.corpus = corpus_lines(source_files(src, args.preprocessor))
        self.files = source_files(work, args.preprocessor)
        self.open: dict[Path, Doc] = {}
        # every file opened, in order: a closed file stays in the workspace
        # (re-read from disk), even one the config excludes
        self.ever_opened: list[Path] = []
        self.ops: list[str] = []
        self.errors: list[str] = []
        self.expected_errors = 0
        self.requests = 0
        self.server = Server(server_cmd(args), work.parent / "stream.bin")

    # -- edits ------------------------------------------------------------

    def rand_pos(self, doc: Doc) -> dict:
        ls = doc.lines()
        line = self.rng.randrange(len(ls))
        return doc.position(line, self.rng.randint(0, len(ls[line])))

    def change(self, doc: Doc, rng: dict | None, new: str) -> None:
        if rng is None:
            doc.text = new
        else:
            doc.apply(rng, new)
        doc.version += 1
        if self.args.incremental and rng is not None:
            change = {"range": rng, "text": new}
        else:
            change = {"text": doc.text}
        self.server.send("textDocument/didChange", {
            "textDocument": {"uri": doc.uri, "version": doc.version},
            "contentChanges": [change],
        })

    def snippet(self) -> str:
        n = self.rng.choice([1, 1, 1, 2, 3, 5, 8])
        start = self.rng.randrange(len(self.corpus))
        lines = self.corpus[start:start + n]
        if self.rng.random() < 0.1:
            bit = self.rng.choice(UNICODE_BITS)
            lines = lines + [f"  ! {bit} comment {bit}"]
        return "\n".join(lines) + "\n"

    def op_insert_lines(self, doc: Doc) -> None:
        line = self.rng.randrange(len(doc.lines()))
        pos = {"line": line, "character": 0}
        self.change(doc, {"start": pos, "end": pos}, self.snippet())

    def op_delete_lines(self, doc: Doc) -> None:
        n = len(doc.lines())
        a = self.rng.randrange(n)
        b = min(n - 1, a + self.rng.choice([1, 1, 2, 4, 10]))
        self.change(doc, {"start": {"line": a, "character": 0},
                          "end": {"line": b, "character": 0}}, "")

    def op_replace_lines(self, doc: Doc) -> None:
        n = len(doc.lines())
        a = self.rng.randrange(n)
        b = min(n - 1, a + self.rng.choice([1, 2, 3]))
        self.change(doc, {"start": {"line": a, "character": 0},
                          "end": {"line": b, "character": 0}},
                    self.snippet())

    def op_type(self, doc: Doc) -> None:
        """Small in-line edits, like typing or deleting characters."""
        start = self.rand_pos(doc)
        if self.rng.random() < 0.5:
            words = WORD.findall(self.rng.choice(self.corpus)) or ["x"]
            text = self.rng.choice(words + ["(", ")", ",", " ", "%", "&",
                                            "::", "=", "'", "!"]
                                   + UNICODE_BITS)
            self.change(doc, {"start": start, "end": start}, text)
        else:
            ls = doc.lines()
            line = start["line"]
            i = utf16_to_index(ls[line], start["character"])
            j = min(len(ls[line]), i + self.rng.randint(1, 6))
            end = doc.position(line, j)
            self.change(doc, {"start": start, "end": end}, "")

    def op_replace_all(self, doc: Doc) -> None:
        other = self.rng.choice(self.files)
        text = other.read_text(encoding="utf-8", errors="replace")
        self.change(doc, None, text)

    def op_save(self, doc: Doc) -> None:
        self.server.sync()
        doc.path.write_text(doc.text, encoding="utf-8", newline="")
        self.server.send("textDocument/didSave",
                         {"textDocument": {"uri": doc.uri}})

    def op_close(self, doc: Doc) -> None:
        self.server.send("textDocument/didClose",
                         {"textDocument": {"uri": doc.uri}})
        del self.open[doc.path]

    def open_doc(self, path: Path) -> None:
        self.server.sync()
        text = path.read_text(encoding="utf-8", errors="replace")
        doc = Doc(path, text)
        self.open[path] = doc
        if path not in self.ever_opened:
            self.ever_opened.append(path)
        self.ops.append(f"open {path.relative_to(self.work).as_posix()}")
        self.server.send("textDocument/didOpen", {"textDocument": {
            "uri": doc.uri, "languageId": "fortran", "version": 1,
            "text": text,
        }})

    # -- requests ---------------------------------------------------------

    def op_request(self, doc: Doc) -> None:
        pos = self.rand_pos(doc)
        td = {"uri": doc.uri}
        at = {"textDocument": td, "position": pos}
        method, params = self.rng.choice([
            ("textDocument/hover", at),
            ("textDocument/completion", at),
            ("textDocument/definition", at),
            ("textDocument/references", at),
            ("textDocument/implementation", at),
            ("textDocument/signatureHelp", at),
            ("textDocument/documentHighlight", at),
            ("textDocument/rename", {**at, "newName": "zz_renamed"}),
            ("textDocument/documentSymbol", {"textDocument": td}),
            ("workspace/symbol", {"query": self.rng.choice("abcmst")}),
        ])
        self.requests += 1
        resp = self.server.request(method, params)
        if "error" in resp:
            if resp["error"].get("message") in EXPECTED_ERRORS:
                self.expected_errors += 1
            else:
                self.errors.append(f"{method} {json.dumps(params)} -> "
                                   f"{json.dumps(resp['error'])}")

    # -- driver -----------------------------------------------------------

    def run(self) -> None:
        s = self.server
        s.request("initialize", {"rootUri": self.work.as_uri(),
                                 "rootPath": str(self.work),
                                 "capabilities": {}})
        s.send("initialized", {})
        for p in self.rng.sample(self.files, min(4, len(self.files))):
            self.open_doc(p)
        weights = [
            (self.op_insert_lines, 20), (self.op_delete_lines, 15),
            (self.op_replace_lines, 10), (self.op_type, 30),
            (self.op_replace_all, 1), (self.op_save, 6),
            (self.op_request, 25),
        ]
        fns, ws = zip(*weights)
        for step in range(self.args.steps):
            if not self.open or self.rng.random() < 0.01:
                closed = [p for p in self.files if p not in self.open]
                if closed:
                    self.open_doc(self.rng.choice(closed))
                    continue
            doc = self.open[self.rng.choice(sorted(self.open))]
            if self.rng.random() < 0.005 and len(self.open) > 1:
                fn = self.op_close
            else:
                fn = self.rng.choices(fns, ws)[0]
            self.ops.append(f"{step}: {fn.__name__} {doc.path.name}")
            fn(doc)
        # make every open document's final text the saved one; the second
        # round republishes diagnostics now that all the others are final
        for _ in range(2):
            for doc in list(self.open.values()):
                self.op_save(doc)
        s.sync()

    def final_state(self) -> dict:
        """Symbols and diagnostics of every open document."""
        out = {}
        for doc in self.open.values():
            sym = self.server.request("textDocument/documentSymbol",
                                      {"textDocument": {"uri": doc.uri}})
            out[doc.path.relative_to(self.work).as_posix()] = {
                "symbols": sym.get("result"),
                "diagnostics": self.server.diagnostics.get(doc.uri),
            }
        return out


def fresh_state(args, work: Path, docs: list[Path],
                closed: list[Path]) -> dict:
    """The state of `docs` in a new server on the final text, after `closed`
    were opened and closed again as in the session."""
    log = work.parent / "fresh_stream.bin"
    s = Server(server_cmd(args), log)
    s.request("initialize", {"rootUri": work.as_uri(),
                             "rootPath": str(work), "capabilities": {}})
    s.send("initialized", {})
    out = {}
    for p in closed + docs:
        s.send("textDocument/didOpen", {"textDocument": {
            "uri": p.as_uri(), "languageId": "fortran", "version": 1,
            "text": p.read_text(encoding="utf-8", errors="replace"),
        }})
    for p in closed:
        s.send("textDocument/didClose",
               {"textDocument": {"uri": p.as_uri()}})
    # republish each one's diagnostics now that all are open, as the
    # session's final saves do
    for p in docs:
        s.send("textDocument/didSave", {"textDocument": {"uri": p.as_uri()}})
    s.sync()
    for p in docs:
        sym = s.request("textDocument/documentSymbol",
                        {"textDocument": {"uri": p.as_uri()}})
        out[p.relative_to(work).as_posix()] = {
            "symbols": sym.get("result"),
            "diagnostics": s.diagnostics.get(p.as_uri()),
        }
    s.close()
    return out


def normalize(state: dict) -> dict:
    """Drops what may differ between equally right answers: the "Possible
    object" hint of a diagnostic names the first of several candidates in
    workspace order, which edits change."""
    for entry in state.values():
        for d in entry.get("diagnostics") or []:
            for r in d.get("relatedInformation") or []:
                if r.get("message") == "Possible object":
                    r.pop("location", None)
    return state


def first_difference(a, b, path="$"):
    if type(a) is not type(b):
        return f"{path}: {a!r} != {b!r}"
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}.{k}: missing on one side"
            d = first_difference(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}: length {len(a)} != {len(b)}"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_difference(x, y, f"{path}[{i}]")
            if d:
                return d
        return None
    return None if a == b else f"{path}: {a!r} != {b!r}"


def run_seed(args, seed: int, src: Path) -> list[str]:
    tmp = Path(tempfile.mkdtemp(prefix=f"zfls_stress_{seed}_"))
    work = tmp / "ws"
    shutil.copytree(src, work)
    shutil.copytree(src, tmp / "initial")
    problems: list[str] = []
    sess = Session(args, seed, src, work)
    started = time.monotonic()
    try:
        sess.run()
        session_state = sess.final_state()
        code = sess.server.close()
        if code != 0:
            problems.append(f"exit code {code}")
    except (TimeoutError, ConnectionError, BrokenPipeError, OSError) as e:
        session_state = None
        if sess.server.proc.poll() is None:
            sess.server.proc.kill()
        code = sess.server.proc.wait()
        problems.append(f"{type(e).__name__}: {e} (exit code {code:#x})")
        time.sleep(0.2)
    stderr = sess.server.stderr.decode(errors="replace")
    if ALLOCATOR_REPORTS.search(stderr):
        problems.append("stderr: " + stderr.strip()[-3000:])
    problems += [f"error response: {e}" for e in sess.errors[:10]]
    if (session_state is not None and not args.preprocessor
            and not ALLOCATOR_REPORTS.search(stderr)):
        closed = [p for p in sess.ever_opened if p not in sess.open]
        fresh = normalize(fresh_state(args, work, sorted(sess.open), closed))
        session_state = normalize(session_state)
        for name in sorted(session_state):
            d = first_difference(session_state[name], fresh[name],
                                 f"{name}")
            if d:
                problems.append(f"stale state vs fresh server: {d}")
    elapsed = time.monotonic() - started
    status = "FAIL" if problems else "ok"
    print(f"seed {seed}: {status}  {len(sess.ops)} edits/ops, "
          f"{sess.requests} requests ({sess.expected_errors} fortls-style "
          f"errors), {elapsed:.0f}s")
    if problems:
        (tmp / "ops.txt").write_text("\n".join(sess.ops), encoding="utf-8")
        (tmp / "stderr.txt").write_text(stderr, encoding="utf-8")
        for p in problems:
            print("   ", p[:2000])
        print(f"    last ops: {sess.ops[-5:]}")
        print(f"    reproduction: {tmp} (initial/, stream.bin, ops.txt)")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
    return problems


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--zfls", default=str(HERE.parent / "zig-out" / "bin"
                                          / "zfls"))
    ap.add_argument("--source", type=Path,
                    default=HERE.parent.parent / "fortls" / "test"
                    / "test_source",
                    help="workspace to copy (default: fortls's test_source,"
                    " else tests/fortran)")
    ap.add_argument("--fortls", type=Path,
                    help="fortls checkout; uses its test/test_source")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--steps", type=int, default=2000)
    ap.add_argument("--incremental", action=argparse.BooleanOptionalAction,
                    default=True,
                    help="send range edits (--incremental_sync)")
    ap.add_argument("--preprocessor", action="store_true",
                    help="also edit files with preprocessor directives; "
                    "checks crashes and errors only, not stale state")
    ap.add_argument("--zfls-arg", action="append", default=[],
                    help="extra zfls argument (repeatable)")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    if args.fortls:
        args.source = args.fortls / "test" / "test_source"
    src = args.source if args.source.is_dir() else HERE / "fortran"
    print(f"workspace: {src}; zfls: {args.zfls}; "
          f"{'incremental' if args.incremental else 'full'} sync")
    failed = 0
    for seed in range(args.first_seed, args.first_seed + args.seeds):
        failed += bool(run_seed(args, seed, src))
    print(f"{args.seeds - failed}/{args.seeds} sessions passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
