C     FIXED-FORM LINES PAST COLUMN 72 (ZFLS #296): LLVM FLANG READS 72
C     COLUMNS BY DEFAULT; ZFLS AS MANY AS fixed_line_length SAYS
C     oracle-zfls-args: --fixed_line_length 72
      SUBROUTINE LONGL(A)
      IMPLICIT NONE
      REAL A
      INTEGER SHORT1, SHORT2                                            , PAST72
      SHORT1 = 1
      SHORT2 = 2
      A = SHORT1 + SHORT2
      END SUBROUTINE
