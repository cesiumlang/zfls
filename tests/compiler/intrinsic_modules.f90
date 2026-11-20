program intrinsic_modules
  use iso_fortran_env, only: real64, output_unit
  use, intrinsic :: ieee_arithmetic, only: ieee_value, ieee_quiet_nan
  use iso_c_binding, only: c_int
  implicit none
  real(real64) :: x
  x = ieee_value(x, ieee_quiet_nan)
  x = x + undeclared_intrinsic
  write (output_unit, *) x, c_int
end program intrinsic_modules
