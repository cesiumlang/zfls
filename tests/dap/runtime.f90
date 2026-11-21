! zfls dap with gdb and lldb-dap (tests/dap_gfortran.zig): gfortran's
! runtime errors and stops, by the program's argument, and a CHARACTER of
! kind 4
program runtime
  implicit none
  character(len=8) :: arg
  character(kind=4, len=5) :: wide
  integer :: u, ios
  integer, allocatable :: small(:)
  wide = 4_'h' // char(235, kind=4) // 4_'llo'
  call get_command_argument(1, arg)
  select case (arg)
  case ('open')
    open (newunit=u, file='no/such/file', status='old') ! the I/O error
  case ('iostat')
    open (newunit=u, file='no/such/file', status='old', iostat=ios)
  case ('seed')
    allocate (small(1))
    small = 1
    call random_seed(put=small) ! raised inside libgfortran
  case ('text')
    error stop 'text'
  case ('quiet')
    error stop 4, quiet=.true.
  case default
    print *, len(wide) ! stop here: wide
  end select
end program runtime
