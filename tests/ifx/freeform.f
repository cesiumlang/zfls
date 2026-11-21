C     ifx's !DEC$ FREEFORM and !DEC$ NOFREEFORM, which switch the form of
C     the lines after them (#506)
      MODULE SWITCHED
      IMPLICIT NONE
      INTEGER FIXED1,
     &        FIXED2
!DEC$ FREEFORM
  integer :: free1, &
             free2
!DEC$ NOFREEFORM
      REAL AGAIN
      END MODULE SWITCHED
