! zfls dap's attach (tests/dap_gdb_attach.zig): the program waits for a
! number on its input, for the debugger to attach first
program attach
  implicit none
  integer :: n, k, total
  read(*, *) n
  total = 0
  do k = 1, n
    total = total + k ! stop here
  end do
  print '(a,i0)', 'total ', total
end program
