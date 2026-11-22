! oracle-gfortran-min: 14
! (gfortran 13.3's dump of a PDT template differs: the file is skipped there)
! Variables of parameterized derived types: their instances are scopes of
! their own in the compilers' dumps (gfortran's `PDTmatrix_8`, Flang's
! `instantiation of`, ifx's `matrix#8&3`) that zfls has no scopes for
module pdts
  implicit none
  type :: matrix(k, n)
    integer, kind :: k = 4
    integer, len :: n = 2
    real(k) :: data(n, n)
    integer :: tag
  end type matrix
  type, extends(matrix) :: tagged(m)
    integer, len :: m = 1
    character(len=m) :: label
  end type tagged
  type(matrix(8, 2)), save :: shared
contains
  subroutine use_it(d, dm)
    integer, intent(in) :: d
    type(matrix(4, *)), intent(in) :: dm
    type(matrix(8, 3)) :: a
    type(matrix(4, :)), allocatable :: b
    type(tagged(8, 3, 5)) :: c
    type(matrix(n=d)) :: e
    a%tag = 1
    allocate (matrix(4, d) :: b)
    b%tag = 2
    c%label = 'x'
    e%tag = c%tag
    shared%tag = dm%tag
    print *, a%tag, b%tag, e%tag
  end subroutine use_it

  function make(d) result(r)
    integer, intent(in) :: d
    type(matrix(4, d)) :: r
    r%tag = d
  end function make
end module pdts
