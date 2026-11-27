! zfls dap on an MPI program (tests/dap_mpi.zig, #988): each rank stops at
! its breakpoint, its own rank in its variables
program ranks
  use mpi
  implicit none
  integer :: ierr, rank, total
  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  total = rank + 10
  print '(a,i0,a,i0)', 'rank ', rank, ' total ', total ! stop here
  call MPI_Finalize(ierr)
end program ranks
