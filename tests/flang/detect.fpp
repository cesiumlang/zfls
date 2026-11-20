! A free-form file of suffix .fpp, whose form zfls detects (LLVM Flang
! reads .fpp as fixed form unless told: the oracle gives it zfls's form)
module detected
  implicit none
  integer :: free_form_var
#ifdef NOT_DEFINED
  integer :: not_declared
#endif
end module detected
