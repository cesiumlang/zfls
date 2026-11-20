! An INCLUDE line and a preprocessor-free include file (zfls #403): the
! names it declares are the including scope's
module include_m
  implicit none
  include 'include_decls.inc'
  integer :: after_include
contains
  subroutine use_them()
    include "include_local.inc"
    local_from_inc = from_inc + after_include
  end subroutine
end module include_m
