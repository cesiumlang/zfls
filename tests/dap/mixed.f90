! zfls dap's C++ exception filters (tests/dap_gdb_cpp.zig): a Fortran
! program that calls C++ (tests/dap/twice.cpp), linked with libstdc++
program mixed
  use iso_c_binding, only: c_int
  implicit none
  interface
    function twice(n) bind(c, name='twice') result(r)
      import :: c_int
      integer(c_int), value :: n
      integer(c_int) :: r
    end function
  end interface
  print '(i0)', twice(21)
end program
