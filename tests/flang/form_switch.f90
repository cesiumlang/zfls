! LLVM Flang's !dir$ fixed and !dir$ free (zfls #410): the lines after
! them are in that form; a C comment line in the fixed part names nothing,
! a continuation in column 6 continues its statement
module form_switch
  implicit none
  integer :: before_fixed
contains
!dir$ fixed
      SUBROUTINE OLD(X, Y)
C     A COMMENT LINE CALL NOWHERE(Q) LOOKS LIKE CODE
*     SO DOES THIS ONE: INTEGER NOT_DECLARED
      IMPLICIT NONE
      REAL X,
     &     Y
      INTEGER
     &   COUNTED
      COUNTED = 1
      X = X +
     &    Y
      END SUBROUTINE
!dir$ free
  subroutine new_again(z)
    real, intent(inout) :: z
    real :: after_free
    after_free = 2.0
    z = z * after_free
  end subroutine
end module form_switch
