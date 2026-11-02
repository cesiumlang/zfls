"""zfls dap, the debug adapter over Windows's Debugger Engine, on a program
of the MSVC ABI with a PDB (tests/dap/hello.c, built by `zig cc`): a
breakpoint, the stack, the variables, stepping, an expression, the end.
The Fortran values (of ifx's programs) need ifx, which CI has not.

Usage: python tests/dap_windows.py --zfls <zfls.exe> [--zig <zig>]
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "dap" / "hello.c"


class Client:
    def __init__(self, cmd: list[str]):
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.seq = 1
        self.responses: dict[int, dict] = {}
        self.events: queue.Queue[dict] = queue.Queue()
        self.cond = threading.Condition()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self) -> None:
        out = self.proc.stdout
        while True:
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                c = out.read(1)
                if not c:
                    return
                header += c
            length = int(header.split(b"Content-Length:")[1].split(b"\r\n")[0])
            msg = json.loads(out.read(length))
            if msg["type"] == "response":
                with self.cond:
                    self.responses[msg["request_seq"]] = msg
                    self.cond.notify_all()
            elif msg["type"] == "event":
                self.events.put(msg)

    def request(self, command: str, args: dict | None = None) -> dict:
        seq = self.seq
        self.seq += 1
        body = json.dumps({"seq": seq, "type": "request", "command": command, "arguments": args or {}}).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()
        with self.cond:
            if not self.cond.wait_for(lambda: seq in self.responses, timeout=60):
                raise TimeoutError(command)
            r = self.responses.pop(seq)
        if not r["success"]:
            raise AssertionError(f"{command}: {r.get('message')}")
        return r.get("body") or {}

    def event(self, name: str) -> dict:
        while True:
            e = self.events.get(timeout=60)
            if e["event"] == name:
                return e


def check(cond: bool, what: str) -> None:
    if not cond:
        raise AssertionError(what)
    print(f"ok: {what}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--zfls", required=True)
    p.add_argument("--zig", default="zig")
    a = p.parse_args()
    if sys.platform != "win32":
        print("skipped: Windows only")
        return 0
    tmp = Path(tempfile.mkdtemp(prefix="zfls-dap-"))
    try:
        exe = tmp / "hello.exe"
        subprocess.run([a.zig, "cc", "-target", "x86_64-windows-msvc", "-g", "-O0", str(SOURCE), "-o", str(exe)], check=True, cwd=tmp)
        c = Client([a.zfls, "dap"])
        caps = c.request("initialize", {"adapterID": "fortran", "pathFormat": "path", "linesStartAt1": True})
        check(any(f["filter"] == "fortranRuntimeErrors" for f in caps.get("exceptionBreakpointFilters", [])), "the filter of Fortran runtime errors")
        c.request("launch", {"program": str(exe), "cwd": str(tmp), "console": "internalConsole", "sourceRoot": str(SOURCE.parent)})
        c.event("initialized")
        bps = c.request("setBreakpoints", {"source": {"path": str(SOURCE)}, "breakpoints": [{"line": 8}]})
        check(bps["breakpoints"][0]["verified"], "a verified breakpoint")
        c.request("setExceptionBreakpoints", {"filters": []})
        c.request("configurationDone")

        stopped = c.event("stopped")
        check(stopped["body"]["reason"] == "breakpoint", "stopped at the breakpoint")
        thread = stopped["body"]["threadId"]
        frames = c.request("stackTrace", {"threadId": thread})["stackFrames"]
        check("twice" in frames[0]["name"] and frames[0]["line"] == 8, f"in twice at line 8 ({frames[0]['name']}:{frames[0]['line']})")
        check("main" in frames[1]["name"], "called by main")
        scopes = c.request("scopes", {"frameId": frames[0]["id"]})["scopes"]
        local = c.request("variables", {"variablesReference": scopes[0]["variablesReference"]})["variables"]
        n = next(v for v in local if v["name"] == "n")
        check(n["value"] == "21", f"n = 21 ({n['value']})")

        c.request("next", {"threadId": thread})
        stopped = c.event("stopped")
        frames = c.request("stackTrace", {"threadId": thread})["stackFrames"]
        check(stopped["body"]["reason"] == "step" and frames[0]["line"] == 9, f"next: line 9 ({frames[0]['line']})")
        r = c.request("evaluate", {"expression": "doubled", "frameId": frames[0]["id"], "context": "watch"})
        check(r["result"] == "42", f"doubled = 42 ({r['result']})")

        c.request("stepOut", {"threadId": thread})
        stopped = c.event("stopped")
        frames = c.request("stackTrace", {"threadId": thread})["stackFrames"]
        check(stopped["body"]["reason"] == "step" and "main" in frames[0]["name"], f"stepOut: back in main ({frames[0]['name']})")

        c.request("continue", {"threadId": thread})
        exited = c.event("exited")
        check(exited["body"]["exitCode"] == 3, f"exit code 3 ({exited['body']['exitCode']})")
        c.event("terminated")
        c.request("disconnect", {"terminateDebuggee": True})
        c.proc.wait(timeout=30)
        print("zfls dap: all good")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
