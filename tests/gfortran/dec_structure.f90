! oracle-gfortran-args: -fdec-structure
! DEC's STRUCTURE, UNION and MAP, and RECORD: the fields of the maps are
! the structure's (gfortran's dump names the union UU$0, the maps MM$0
! and MM$1)
program dec_structure
  implicit none
  structure /point/
    real :: x, y
    union
      map
        integer :: i
      end map
      map
        real :: r
      end map
    end union
  end structure
  record /point/ p
  p.x = 1.0
  print *, p.x
end program dec_structure
