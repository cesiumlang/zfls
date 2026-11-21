! $ in names, also first (ifx and LLVM Flang; gfortran's -fdollar-ok
! takes it after the first character): procedures, modules, programs,
! results, interface bodies (#508)
module dm
  interface random
    subroutine $$lib$random(f)
      real f
    end subroutine
  end interface
contains
  subroutine a$b()
  end subroutine
end module
module $mod$x
  implicit none
  integer :: $count = 0
contains
  subroutine $sub(x)
    real :: x
    $count = $count + 1
    x = real($count)
  end subroutine $sub
  function $fn() result($r)
    integer :: $r
    $r = 1
  end function
end module
program $prog
  use $mod$x
  call $sub(y)
end program
