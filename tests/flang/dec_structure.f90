! DEC STRUCTURE and RECORD, as LLVM Flang accepts them: a structure is a
! derived type, a record a variable of it, a nested structure declares a
! type and a field. UNION and MAP are not implemented in Flang 23, and its
! parser reads a field as `p.x` only where the record's STRUCTURE is in the
! same scope: of a structure of the host, a field is `p%x`
module dec_structure
  implicit none
  structure /point/
    real :: x, y
    integer :: tag
  end structure
  structure /segment/
    record /point/ from, to
    character*8 :: label
  end structure
  record /point/ origin
contains
  subroutine move(s)
    record /segment/ s
    record /point/ p, q(2)
    p%x = 1.0
    q(1) = p
    s%from = q(1)
    s%to%x = s%from%x + origin%x
  end subroutine
  subroutine local_structure()
    structure /pair/
      integer :: first, second
    end structure
    record /pair/ pr
    pr.first = 1
    pr.second = pr.first + 1
  end subroutine
end module dec_structure

program use_dec
  implicit none
  structure /pt/
    real :: x
    structure /inner/ nested
      integer :: k
    end structure
  end structure
  record /pt/ p
  p.x = 1.0
  p.nested.k = 2
  print *, p.x, p%nested%k
end program use_dec
