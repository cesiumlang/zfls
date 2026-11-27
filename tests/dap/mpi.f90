! zfls dap on an MPI program (tests/dap_mpi.zig, #988): each rank stops at
! its breakpoint, its own rank in its variables
program ranks
  use mpi
  implicit none
  integer :: ierr, rank, total, ranks_n
  character(len=64) :: pmi_fd, pmi_port
  ! what the launcher gave the rank, for the test's log
  call get_environment_variable('PMI_FD', pmi_fd)
  call get_environment_variable('PMI_PORT', pmi_port)
  call execute_command_line('ls -l /proc/$PPID/fd')
  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Comm_size(MPI_COMM_WORLD, ranks_n, ierr)
  print '(a,i0,a,i0,4a)', 'rank ', rank, ' of ', ranks_n, ' PMI_FD ', trim(pmi_fd), ' PMI_PORT ', trim(pmi_port)
  flush(6)
  total = rank + 10
  print '(a,i0,a,i0)', 'rank ', rank, ' total ', total ! stop here
  call MPI_Finalize(ierr)
end program ranks
