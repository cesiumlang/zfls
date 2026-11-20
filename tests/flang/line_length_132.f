C     FIXED-FORM LINES OF 132 COLUMNS: FLANG'S -ffixed-line-length=132,
C     ZFLS'S fixed_line_length
C     oracle-flang-args: -ffixed-line-length=132
C     oracle-zfls-args: --fixed_line_length 132
      SUBROUTINE LONG132(A)
      IMPLICIT NONE
      REAL A
      INTEGER SHORT1, SHORT2                                            , PAST72
      SHORT1 = 1
      SHORT2 = 2
      PAST72 = 3
      A = SHORT1 + SHORT2 + PAST72
      END SUBROUTINE
