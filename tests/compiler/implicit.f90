program implicit_typing
  n = 3
  x = 2.0 * n
  call external_sub(x)
  call takes_real(1)
contains
  subroutine takes_real(r)
    real, intent(in) :: r
    print *, r
  end subroutine takes_real
end program implicit_typing
