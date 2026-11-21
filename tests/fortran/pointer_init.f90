! Pointers initialized with a target or null(): each its own declaration,
! not its target's (#700)
module pointer_init
  implicit none
  real, target :: t(3)
  real, pointer :: p(:) => t
  real, pointer :: q => null()
  integer, target :: t2(2, 2)
  integer, pointer :: r(:, :) => t2, s => null()
end module pointer_init
