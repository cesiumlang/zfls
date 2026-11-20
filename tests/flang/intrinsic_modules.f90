! LLVM Flang's intrinsic modules, used with ONLY lists and renames: the
! names a USE brings are not this file's (each module itself is compared as
! zfls reads its module file, zfls #468)
module intrinsic_modules
  use iso_fortran_env, only: int64, real128, compiler_version, logical8 => logical64
  use iso_c_binding, only: c_int, c_ptr, c_null_ptr, c_f_pointer
  use ieee_arithmetic, only: ieee_value, ieee_quiet_nan, ieee_is_nan
  use ieee_exceptions, only: ieee_set_halting_mode, ieee_overflow
  use, intrinsic :: ieee_features
  implicit none
  integer(int64) :: big
  integer(c_int) :: from_c
  type(c_ptr) :: handle = c_null_ptr
contains
  logical function is_bad(x)
    real(8), intent(in) :: x
    is_bad = ieee_is_nan(x)
  end function
end module intrinsic_modules
