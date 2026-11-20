C     DEBUG LINES READ AS CODE: FLANG'S -fd-lines-as-code, ZFLS'S d_lines
C     oracle-flang-args: -fd-lines-as-code
C     oracle-zfls-args: --d_lines code
      SUBROUTINE DCODE(N)
      IMPLICIT NONE
      INTEGER N
D     INTEGER DEBUG_ONLY
      INTEGER ALWAYS
D     DEBUG_ONLY = N
      ALWAYS = N
      END SUBROUTINE
