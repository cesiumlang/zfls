! The names IEEE_ARITHMETIC, IEEE_EXCEPTIONS and ISO_C_BINDING have since
! Fortran 2018 and 2023, which LLVM Flang has (#730)
program ieee
  use ieee_arithmetic
  use ieee_exceptions, only: ieee_modes_type, ieee_get_modes, ieee_set_modes
  implicit none
  real :: x = 1.0, y = 2.0
  real(8) :: d = 1d0
  integer :: i
  logical :: l
  type(ieee_modes_type) :: modes
  type(ieee_class_type) :: c
  call ieee_get_modes(modes)
  call ieee_set_modes(modes)
  x = ieee_fma(x, y, x)
  d = ieee_fma(d, d, d)
  x = ieee_next_up(x) + ieee_next_down(y)
  x = ieee_max_num(x, y) + ieee_min_num(x, y) + ieee_max_num_mag(x, y) + ieee_min_num_mag(x, y)
  x = ieee_real(i) + ieee_real(d, kind(x))
  i = ieee_int(x, ieee_nearest) + ieee_int(d, ieee_up, kind(i))
  l = ieee_quiet_eq(x, y) .or. ieee_quiet_ne(x, y) .or. ieee_quiet_lt(x, y) .or. ieee_quiet_le(x, y)
  l = ieee_quiet_gt(x, y) .or. ieee_quiet_ge(x, y) .or. ieee_signbit(x)
  l = ieee_signaling_eq(x, y) .or. ieee_signaling_ne(x, y) .or. ieee_signaling_lt(x, y)
  l = ieee_signaling_le(x, y) .or. ieee_signaling_gt(x, y) .or. ieee_signaling_ge(x, y)
  l = ieee_support_subnormal(x)
  c = ieee_positive_subnormal
  c = ieee_negative_subnormal
  call ieee_get_underflow_mode(l)
  call ieee_set_underflow_mode(l)
  l = ieee_support_underflow_control(x)
  print *, x, d, i, l
end program

subroutine ieee23()
  use ieee_arithmetic
  use iso_c_binding
  implicit none
  real :: x = 1.0, y = 2.0
  character(len=:, kind=c_char), allocatable :: s
  character(len=:), pointer :: fs
  type(c_ptr) :: p = c_null_ptr
  x = ieee_max(x, y) + ieee_min(x, y) + ieee_max_mag(x, y) + ieee_min_mag(x, y)
  s = f_c_string('abc')
  s = f_c_string('abc', .true.)
  call c_f_strpointer(p, fs, 3)
  print *, x, s
end subroutine
