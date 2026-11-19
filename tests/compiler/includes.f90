program includes
  implicit none
  include 'consts.inc'
  integer :: k
  k = included_n
  k = k + undeclared_includes
  print *, k
end program includes
