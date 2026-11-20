C     A FIXED-FORM FILE WITH A FREE-FORM PART (ZFLS #410)
      MODULE FSFIX
      IMPLICIT NONE
      INTEGER FIXED_VAR
      CONTAINS
      SUBROUTINE FIRST(A)
      REAL A
      A = 1.0
      END SUBROUTINE
CDIR$ FREE
  subroutine second(b, &
                    c)
    real :: b, c
    integer :: free_local
    free_local = 1
    b = c
  end subroutine
!DIR$ FIXED
      SUBROUTINE THIRD(D)
      REAL D
C     ANOTHER COMMENT: REAL NOT_A_NAME
      D = 3.0
      END SUBROUTINE
      END MODULE
