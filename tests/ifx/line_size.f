C     oracle-zfls-args: --fixed_line_length 72
C     ifx's !DEC$ FIXEDFORMLINESIZE:n, the line length of the fixed-form
C     lines after it (#511): WIDE, past column 72, is declared after
C     FIXEDFORMLINESIZE:132 only; CUT, past column 72 before it, is not
C     (ifx's 72 columns, which a command of ifx gives zfls)
      MODULE LINESIZE
      IMPLICIT NONE
      INTEGER NARROW                                                    ,CUT
CDEC$ FIXEDFORMLINESIZE:132
      INTEGER I                                                         ,WIDE
!DEC$ FIXEDFORMLINESIZE:72
      END MODULE LINESIZE
