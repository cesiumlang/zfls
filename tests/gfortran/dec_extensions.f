C     oracle-gfortran-args: -fdec
C     DEC's TYPE statement (#504) and intrinsics gfortran shares with ifx
C     with -fdec (#505; not IZEXT nor JZEXT, which gfortran 16.1 has not):
C     none is a variable or a type
      PROGRAM DECEXT
      IMPLICIT NONE
      INTEGER*2 H
      INTEGER I
      REAL X
      H = 4
      I = IIABS(H) + JIABS(I) + IIAND(H, H)
      X = 1.0
      TYPE *, I, X
      END
