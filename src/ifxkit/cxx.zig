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

//! What the static part of MSVC's C and C++ runtimes (`msvcrt.lib`,
//! `msvcprt.lib`) gives LLVM Flang's runtime (`flang_rt.runtime.dynamic.lib`,
//! C++ built against MSVC's `/MD` runtime and standard library), beyond
//! src/ifxkit/shim.zig, and that no DLL of Windows's exports: the sized
//! `operator delete`, `type_info`'s table of virtual functions, two
//! algorithms of the standard library, and the old name `access`. Part of
//! the kit's startup object (`zfls_ifx_shim.obj`).

extern fn free(p: ?*anyopaque) callconv(.c) void;
extern fn _access(path: [*:0]const u8, mode: c_int) callconv(.c) c_int;

comptime {
    // `void operator delete(void *, size_t)`
    @export(&deleteSized, .{ .name = "??3@YAXPEAX_K@Z" });
    // `const type_info::`vftable'`
    @export(&type_info_vftable, .{ .name = "??_7type_info@@6B@" });
    // `__declspec(dllimport) int access(const char *, int)`'s pointer
    @export(&imp_access, .{ .name = "__imp_access" });
}

fn deleteSized(p: ?*anyopaque, size: usize) callconv(.c) void {
    _ = size;
    free(p);
}

/// `type_info`'s one virtual function, its deleting destructor
/// (`this`, flags): the runtime deletes no `type_info`, and its objects are
/// the compiler's constants, never freed
fn typeInfoDestructor(self: ?*anyopaque, flags: c_uint) callconv(.c) ?*anyopaque {
    _ = flags;
    return self;
}

const type_info_vftable = [1]*const fn (?*anyopaque, c_uint) callconv(.c) ?*anyopaque{typeInfoDestructor};

fn access(path: [*:0]const u8, mode: c_int) callconv(.c) c_int {
    return _access(path, mode);
}

const imp_access: *const fn ([*:0]const u8, c_int) callconv(.c) c_int = access;

/// `std::reverse` of bytes, in place: `[first, last)`
export fn __std_reverse_trivially_swappable_1(first: [*]u8, last: [*]u8) callconv(.c) void {
    var a = first;
    var b = last;
    while (@intFromPtr(a) < @intFromPtr(b)) {
        b -= 1;
        const t = a[0];
        a[0] = b[0];
        b[0] = t;
        a += 1;
    }
}

/// `std::find` of the byte `value` in `[first, last)`: where it is, else
/// `last`
export fn __std_find_trivial_1(first: [*]const u8, last: [*]const u8, value: u8) callconv(.c) [*]const u8 {
    var p = first;
    while (p != last) : (p += 1) {
        if (p[0] == value) return p;
    }
    return last;
}
