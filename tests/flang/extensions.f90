! Extensions LLVM Flang accepts, and what it declares of them: type
! lengths (INTEGER*2, REAL*8, CHARACTER*8), DOUBLE COMPLEX, BYTE, old-style
! initial values (/3/), $ in names, COMMON, NAMELIST, EQUIVALENCE, Cray
! pointers, statement functions, ENTRY, PROCEDURE(), BLOCK DATA, external
! procedures, defined operators and assignment, a parameterized type with a
! procedure pointer component and a generic binding
module extensions
  implicit none
  integer*2 :: short_int
  real*8 :: dbl
  character*8 :: name8, name4*4
  double complex :: dc
  byte :: b1
  integer :: old_init /3/, arr(3) /1, 2, 3/
  integer :: a$b
  logical*1 :: tiny_flag
  common /blk/ c1, c2
  integer :: c1, c2
  namelist /nml/ short_int, dbl
  real :: e1, e2
  equivalence (e1, e2)
  interface operator(.plus.)
    module procedure plus
  end interface
  interface assignment(=)
    module procedure assign_it
  end interface
  type :: pt(k, n)
    integer, kind :: k = 4
    integer, len :: n = 2
    real(k) :: v(n)
    procedure(iface), pointer, nopass :: fp => null()
  contains
    generic :: g => tb
    procedure, nopass :: tb
  end type
  abstract interface
    subroutine iface()
    end subroutine
  end interface
contains
  integer function plus(x, y)
    integer, intent(in) :: x, y
    plus = x + y
  end function
  subroutine assign_it(x, y)
    integer, intent(out) :: x
    logical, intent(in) :: y
    x = merge(1, 0, y)
  end subroutine
  subroutine tb()
  end subroutine
  subroutine cray(n, bounded)
    integer, intent(in) :: n
    real :: bounded(1_8:int(n, kind=8))
    real :: target_arr(10)
    pointer (ptr, target_arr)
    integer :: i
    external :: ext_sub
    real, external :: ext_fun
    procedure(iface), pointer :: pp
    procedure() :: no_iface
    integer :: sf
    sf(i) = i * 2
    call ext_sub()
    call undeclared_sub()
    i = sf(3) + int(ext_fun())
    bounded = 0
  end subroutine
  subroutine with_entry(x)
    integer :: x
    x = 1
    entry other_entry(x)
    x = 2
  end subroutine
end module extensions

block data init_blk
  common /blk2/ q
  integer :: q
  data q /5/
end block data init_blk

subroutine ext_proc(y)
  real :: y
  y = 0
  undecl = 1
  call implicit_ext(undecl)
end subroutine ext_proc

integer function ext_fn()
  ext_fn = 1
end function ext_fn

program use_extensions
  use extensions
  implicit none
  integer :: z
  z = 1 .plus. 2
end program use_extensions
