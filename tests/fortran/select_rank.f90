! The associate names of SELECT RANK: each block's rank, the selector's
! type and its ALLOCATABLE, POINTER and TARGET (#706)
module select_ranks
  implicit none
contains
  subroutine ranks(a, p, al, t)
    real, intent(in) :: a(..)
    real, pointer :: p(..)
    real, allocatable :: al(..)
    real, target :: t(..)
    select rank (r => a)
    rank (0)
      print *, r
    rank (2)
      print *, r(1, 1)
    rank (*)
      print *, r(1)
    rank default
      print *, rank(r)
    end select
    select rank (p)
    rank (1)
      print *, p(1)
    end select
    select rank (q => al)
    rank (3)
      print *, q(1, 1, 1)
    end select
    select rank (u => t)
    rank (1)
      print *, u(1)
    end select
  end subroutine ranks
end module select_ranks
