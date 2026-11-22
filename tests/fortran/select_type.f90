! The associate names of SELECT TYPE: the selector's rank and attributes,
! the guard's type, intrinsic or derived (#701)
module select_guards
  implicit none
  type :: base_t
    integer :: id = 0
  end type base_t
  type, extends(base_t) :: child_t
    real :: value = 0.0
  end type child_t
contains
  subroutine guards(items, one, ptrs, any)
    class(base_t), intent(in) :: items(:)
    class(base_t), intent(in), target :: one
    class(base_t), pointer :: ptrs(:, :)
    class(*), intent(in) :: any(:)
    select type (it => items)
    type is (base_t)
      print *, size(it)
    class is (child_t)
      print *, size(it)
    class default
      print *, size(it)
    end select
    select type (el => items(1))
    type is (child_t)
      print *, el%value
    end select
    select type (o => one)
    class is (child_t)
      print *, o%value
    end select
    select type (pp => ptrs)
    type is (child_t)
      print *, pp(1, 1)%value
    end select
    select type (items)
    type is (child_t)
      print *, items(1)%value
    class default
      print *, size(items)
    end select
    select type (x => any)
    type is (real(8))
      print *, x(1)
    type is (character(len=*))
      print *, x(2)
    end select
  end subroutine guards
end module select_guards
