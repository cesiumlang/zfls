      PROGRAM LEGACY
      DO 10 I = 1, 3
         X = I * 2.0
   10 CONTINUE
      CALL EXTSUB(X)
      CALL TAKESR(1)
      CONTAINS
      SUBROUTINE TAKESR(R)
      REAL R
      PRINT *, R
      END SUBROUTINE
      END
