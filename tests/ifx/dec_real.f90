! Intel's !DEC$ REAL:8 and !DEC$ INTEGER:8, which set the default kinds of
! the next program unit only (#512): R(8) and I(8) in the module, R(4) and
! I(4) in the program after it
!DEC$ REAL:8
!DEC$ INTEGER:8
module dec_real
  implicit none
  real :: inmod
  integer :: nmod
end module dec_real

program dec_real_main
  use dec_real
  implicit none
  real :: inprog
  integer :: nprog
  inprog = inmod
  nprog = nmod
  print *, inprog, nprog
end program dec_real_main
