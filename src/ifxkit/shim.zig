// SPDX-License-Identifier: MIT-0
//
// This file, unlike the rest of zfls (MIT), is under MIT No Attribution:
// it is linked into the programs that the ifx kit builds, and those need
// not carry zfls's notice.
//
// Copyright (c) 2026 Randy Eckman
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.

//! What MSVC's startup library gives an ifx `/MD` program, so that ifx
//! needs no Visual Studio (with ifx's lld-link and the import libraries of
//! build/ifxkit.zig): the entry point over the Universal CRT, `_fltused`,
//! the stack probe `__chkstk`, and the `/GS` stack cookie that Intel's
//! `for_main.obj` checks. It imports only from the UCRT.

/// The C runtime's marker that floating point is used
export var _fltused: c_int = 0x9875;

/// The `/GS` stack cookie, set from the time stamp counter at startup
export var __security_cookie: u64 = 0x00002B992DDFA232;

extern fn _set_app_type(app_type: c_int) callconv(.c) void;
extern fn _configure_narrow_argv(mode: c_int) callconv(.c) c_int;
extern fn _initialize_narrow_environment() callconv(.c) c_int;
extern fn __p___argc() callconv(.c) *c_int;
extern fn __p___argv() callconv(.c) *[*:null]?[*:0]u8;
extern fn __p__environ() callconv(.c) *[*:null]?[*:0]u8;
extern fn exit(status: c_int) callconv(.c) noreturn;
/// The program's `main`, from Intel's runtime (`for_main.obj`)
extern fn main(argc: c_int, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) callconv(.c) c_int;

/// The console program's entry point
export fn mainCRTStartup() callconv(.c) noreturn {
    initCookie();
    _set_app_type(1); // _crt_console_app
    _ = _configure_narrow_argv(1); // _crt_argv_unexpanded_arguments
    _ = _initialize_narrow_environment();
    exit(main(__p___argc().*, __p___argv().*, __p__environ().*));
}

fn initCookie() void {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    const tsc = (@as(u64, hi) << 32) | lo;
    const cookie = (tsc ^ @intFromPtr(&lo)) & 0x0000_FFFF_FFFF_FFFF;
    __security_cookie = if (cookie == 0) 0x00002B992DDFA232 else cookie;
}

/// `__security_check_cookie(cookie)`: returns when RCX is the cookie, else
/// ends the process (`__fastfail(FAST_FAIL_STACK_COOKIE_CHECK_FAILURE)`).
/// Only the flags change, as callers expect.
export fn __security_check_cookie() callconv(.naked) void {
    asm volatile (
        \\cmpq __security_cookie(%%rip), %%rcx
        \\jne 1f
        \\retq
        \\1:
        \\movl $2, %%ecx
        \\int $0x29
    );
}

/// MSVC's x64 stack probe: touches each page of the RAX bytes about to be
/// allocated below RSP; RSP and every register but the flags unchanged
export fn __chkstk() callconv(.naked) void {
    asm volatile (
        \\pushq %%rcx
        \\pushq %%rax
        \\leaq 24(%%rsp), %%rcx
        \\cmpq $0x1000, %%rax
        \\jb 2f
        \\1:
        \\subq $0x1000, %%rcx
        \\orq $0, (%%rcx)
        \\subq $0x1000, %%rax
        \\cmpq $0x1000, %%rax
        \\ja 1b
        \\2:
        \\subq %%rax, %%rcx
        \\orq $0, (%%rcx)
        \\popq %%rax
        \\popq %%rcx
        \\retq
    );
}
