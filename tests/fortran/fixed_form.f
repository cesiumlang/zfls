C     Fixed-form source with continuation lines and labelled DO loops
      SUBROUTINE SAXPY(N, A, X, INCX, Y,
     &                 INCY)
      IMPLICIT NONE
      INTEGER N, INCX, INCY
      REAL A, X(*), Y(*)
      INTEGER I, IX, IY
C     Unit stride shortcut
      IF (N .LE. 0) RETURN
      IX = 1
      IY = 1
      DO 10 I = 1, N
         Y(IY) = Y(IY) + A*X(IX)
         IX = IX + INCX
         IY = IY + INCY
   10 CONTINUE
      RETURN
      END

      DOUBLE PRECISION FUNCTION DNRM(N, X)
      IMPLICIT NONE
      INTEGER N
      DOUBLE PRECISION X(N)
      DOUBLE PRECISION SUMSQ
      INTEGER J
      SUMSQ = 0.0D0
      DO 20 J = 1, N
         SUMSQ = SUMSQ + X(J)**2
   20 CONTINUE
      DNRM = SQRT(SUMSQ)
      END
