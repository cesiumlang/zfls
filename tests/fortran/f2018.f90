! oracle-gfortran-args: -fcoarray=single
! oracle-gfortran-min: 16
! oracle-ifx-args: /Qcoarray:single
! Fortran 2018 features that gfortran 16, Flang and ifx accept (gfortran 15
! and older read neither CRITICAL nor END TEAM with STAT=, nor coarray
! associations)
module f2018
  use iso_fortran_env, only: team_type
  implicit none
contains
  ! CHANGE TEAM, with a coarray association, and CRITICAL with a sync-stat
  ! list, are constructs (#720, #722)
  subroutine teams(n)
    integer, intent(in) :: n
    type(team_type) :: t
    integer :: k, st
    real, save :: y[*]
    character(len=40) :: msg
    form team (n, t)
    change team (t)
      k = team_number()
    end team
    named: change team (t, x[*] => y, stat=st, errmsg=msg)
      x = 1.0
    end team (stat=st) named
    critical (stat=st)
      y = y + 1.0
    end critical
    guarded: critical (stat=st, errmsg=msg)
      y = 2.0
    end critical guarded
    print *, k
  end subroutine teams

  subroutine after()
    print *, 'after'
  end subroutine after

  ! IMPORT in a BLOCK construct and in contained procedures (#724)
  subroutine imports()
    integer, parameter :: wp = kind(1.0d0)
    real(wp) :: x = 0.0_wp
    block
      import, only: wp
      real(wp) :: y
      y = 1.0_wp
    end block
    print *, x
    call inner()
  contains
    subroutine inner()
      import, none
      print *, 'inner'
    end subroutine inner
  end subroutine imports

  ! QUIET= of STOP and ERROR STOP (#732)
  subroutine stops(shh)
    logical, intent(in) :: shh
    if (shh) stop 2, quiet=shh
    if (.not. shh) error stop "x", quiet=.false.
  end subroutine stops
end module f2018
