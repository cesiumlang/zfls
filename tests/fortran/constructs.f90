! Executable constructs that open scopes: block, associate, select type,
! select case, where, do and if
module constructs
  implicit none
  type :: base_t
    integer :: id = 0
  end type base_t
  type, extends(base_t) :: child_t
    real :: value = 0.0
  end type child_t
contains
  subroutine run(items, n, mask_out)
    integer, intent(in) :: n
    class(base_t), intent(in) :: items(n)
    logical, intent(out) :: mask_out(n)
    real :: buffer(n)
    integer :: i, total

    total = 0
    buffer = 0.0
    do i = 1, n
      select type (it => items(i))
      type is (child_t)
        buffer(i) = it%value
      class default
        buffer(i) = real(it%id)
      end select
    end do

    associate (first => items(1)%id, count => size(items))
      total = first + count
    end associate

    block
      integer :: local_tmp
      local_tmp = total * 2
      total = local_tmp
    end block

    where (buffer > 0.0)
      mask_out = .true.
    elsewhere
      mask_out = .false.
    end where

    select case (total)
    case (0)
      total = -1
    case (1:10)
      total = total + 1
    case default
      total = 0
    end select

    named: if (total > 100) then
      total = 100
    end if named
  end subroutine run
end module constructs
