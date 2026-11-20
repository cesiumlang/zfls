! zfls dap with Windows's Debugger Engine (tests/dap_windows.zig): the
! filter of Fortran runtime errors stops at LLVM Flang's ERROR STOP, not at
! its plain STOP, which call one function (_FortranAStopStatement) that
! tells them apart by an argument. `stops plain` ends by STOP.
program stops
  implicit none
  character(len=8) :: arg
  call get_command_argument(1, arg)
  if (arg == 'plain') stop 0
  error stop 3
end program
