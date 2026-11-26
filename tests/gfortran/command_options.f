C     oracle-gfortran-args: -ffixed-line-length-132 -fd-lines-as-code
C     oracle-zfls-args: --compiler_args ["-ffixed-line-length-132","-fd-lines-as-code"]
C     The fixed-form line length and debug lines of the command's options
C     (#542): WIDE, past column 72, is declared with
C     -ffixed-line-length-132, DEBUG on a D line with -fd-lines-as-code
      MODULE OPTIONS
      IMPLICIT NONE
      INTEGER I                                                         ,WIDE
D     INTEGER DEBUG
      END MODULE OPTIONS
