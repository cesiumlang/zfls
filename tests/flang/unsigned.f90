! oracle-flang-args: -funsigned
! UNSIGNED (gfortran 15 and later, LLVM Flang; #540): the type, its kinds,
! literals and intrinsics
module unsigned_types
  implicit none
  unsigned :: u
  unsigned(kind=8) :: big
  integer, parameter :: uk = selected_unsigned_kind(4)
  unsigned(uk) :: w
contains
  subroutine takeu(x)
    unsigned, intent(in) :: x
    print *, x
  end subroutine takeu
  unsigned function twice(x)
    unsigned, intent(in) :: x
    twice = x * 2u
  end function twice
  subroutine set()
    u = 4000000000u
    big = uint(7, 8)
    w = 3u_uk
    call takeu(twice(u))
  end subroutine set
end module unsigned_types
