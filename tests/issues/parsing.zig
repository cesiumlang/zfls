//! Upstream issues about parsing and preprocessing.

const std = @import("std");
const h = @import("harness.zig");

test "#532 identifiers that start like BLOCK are not BLOCK constructs" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\  implicit none
        \\
        \\contains
        \\
        \\  subroutine real_vector_to_blocked_vector(vector, block_size, blocked_vector)
        \\    real, intent(in) :: vector(:)
        \\    integer, intent(in) :: block_size
        \\    real, intent(out) :: blocked_vector(:, :)
        \\    integer :: max_block_index, bloc
        \\    integer :: vindex_initial, vindex_final
        \\
        \\    bloc = 1
        \\    max_block_index = block_size
        \\    vindex_initial = 1
        \\    vindex_final = block_size
        \\
        \\    blocked_vector(1:max_block_index, bloc) = vector(vindex_initial:vindex_final)
        \\  end subroutine real_vector_to_blocked_vector
        \\
        \\  integer function index_from_block_and_block_index()
        \\    index_from_block_and_block_index = 1
        \\  end function index_from_block_and_block_index
        \\
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(532, .known_failure, w.expectNoDiagnostics("t.f90"));
}

test "#292 a label or a variable named block" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module test_rename_block
        \\    implicit none
        \\contains
        \\
        \\    subroutine block_test01()
        \\        integer :: i
        \\        block: do i = 1, 1
        \\            write(*, *) "use label with name block : ", i
        \\        end do block
        \\    end subroutine block_test01
        \\
        \\    subroutine block_test02()
        \\        integer :: block
        \\        do block = 1, 1
        \\            write(*, *) "use index name block :", block
        \\        end do
        \\    end subroutine block_test02
        \\
        \\end module test_rename_block
        \\
        \\program driver
        \\    use test_rename_block
        \\    implicit none
        \\    call block_test01()
        \\    call block_test02()
        \\end program driver
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(292, .known_failure, w.expectNoDiagnostics("t.f90"));
}

test "#411 a semicolon in a fixed-form comment does not start code" {
    const w = try h.Workspace.init(&.{.{
        .name = "invalid_comment.f",
        .text =
        \\c ; do not treat this as code
        \\      subroutine foo
        \\      end subroutine foo
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(411, .known_failure, w.expectNoDiagnostics("invalid_comment.f"));
}

test "#486 a function-like macro with an empty argument list" {
    const w = try h.Workspace.init(&.{
        .{ .name = "main.F90", .text =
        \\program X
        \\    use A
        \\    call B()
        \\end program
        \\
        },
        .{ .name = "a.F90", .text =
        \\#define ok() if(ie/=0) then; return; end if;
        \\
        \\module A
        \\    implicit none
        \\contains
        \\    subroutine B
        \\    integer :: ie
        \\    ie = 1
        \\    ok()
        \\    end subroutine
        \\end module
        \\
        },
    }, .{});
    defer w.deinit();
    const syms = try w.workspaceSymbols("a");
    var found = false;
    for (syms) |s| if (std.ascii.eqlIgnoreCase(s, "a")) {
        found = true;
    };
    try h.check(486, .fixed, blk: {
        if (!found) break :blk h.unmet("module A is not found among the workspace symbols", .{});
        break :blk w.expectNoDiagnostics("a.F90");
    });
}

test "#236 a continued line that runs into an include directive" {
    const w = try h.Workspace.init(&.{
        .{ .name = "hellomain.F90", .text =
        \\program hello
        \\
        \\   call hello1(1)
        \\   call hello2(1)
        \\
        \\end program
        \\
        },
        .{ .name = "hellosub.F90", .text =
        \\subroutine hello1 &
        \\   (i)
        \\   integer :: i
        \\   print *, 'Hello World 1!', i
        \\end subroutine
        \\
        \\subroutine hello2 &
        \\#include "hellobody.inc"
        \\
        },
        .{ .name = "hellobody.inc", .text =
        \\   (i)
        \\   integer :: i
        \\   print *, 'Hello World 2!', i
        \\end subroutine
        \\
        },
    }, .{});
    defer w.deinit();
    // the server must survive (the report is about a crash), and still know
    // the first subroutine
    const syms = try w.documentSymbols("hellosub.F90");
    var found = false;
    for (syms) |s| if (std.mem.eql(u8, s, "hello1")) {
        found = true;
    };
    try h.check(236, .fixed, h.expect(found, "hello1 is not among the {d} symbols of hellosub.F90", .{syms.len}));
}

test "#433 an ASSOCIATE name that refers to itself" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\PROGRAM main
        \\   IMPLICIT NONE
        \\   integer :: i
        \\   integer :: y(10) = [(i, i = 1, 10)]
        \\
        \\   ASSOCIATE (y => y(3))
        \\      print *,y
        \\   END ASSOCIATE
        \\END PROGRAM main
        \\
        ,
    }}, .{});
    defer w.deinit();
    // hovering must answer (it recursed without bound upstream)
    _ = try w.hover("t.f90", w.pos("t.f90", "y => y(3)", 0, 0));
    _ = try w.hover("t.f90", w.pos("t.f90", "print *,y", 0, 8));
    try h.check(433, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#495 hover and definition inside a file that is #included into a module" {
    const w = try h.Workspace.init(&.{
        .{ .name = "hello.F90", .text =
        \\module hello
        \\    implicit none
        \\    integer :: global_variable
        \\contains
        \\#include "file.f90"
        \\end module hello
        \\
        },
        .{ .name = "file.f90", .text =
        \\subroutine uses_global()
        \\    global_variable = 1
        \\end subroutine uses_global
        \\
        },
    }, .{});
    defer w.deinit();
    const def = try w.definition("file.f90", w.pos("file.f90", "global_variable", 0, 2));
    try h.check(495, .known_failure, blk: {
        const l = def orelse break :blk h.unmet("global_variable is not found from the included file", .{});
        break :blk h.expect(std.mem.endsWith(u8, l.uri, "hello.F90"), "definition is in {s}", .{l.uri});
    });
}
