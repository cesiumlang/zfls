//! For the tests that cannot run under valgrind (.github/workflows/memcheck.yml
//! sets ZFLS_VALGRIND): too slow there, or asking for more address space
//! than valgrind gives.

const std = @import("std");

/// Skips the test when run under valgrind
pub fn skip() error{SkipZigTest}!void {
    if (std.testing.environ.contains(std.testing.allocator, "ZFLS_VALGRIND") catch false) return error.SkipZigTest;
}
