C     DEC's I/O statements, which ifx accepts: ENCODE, DECODE, TYPE,
C     ACCEPT, DEFINE FILE, FIND and the record mark of READ (u'r) (#504);
C     none names a variable
      PROGRAM DECIO
      IMPLICIT NONE
      INTEGER I, J, N, IOS, IREC
      REAL A(10), V
      CHARACTER*40 LINE
      I = 1
      J = 2
      IREC = 5
      ENCODE (40, 10, LINE) I, J
   10 FORMAT (2I5)
      DECODE (40, 10, LINE) N, J
      TYPE *, 'type to terminal', N
      ACCEPT *, V
      DEFINE FILE 3 (100, 10, U, IOS)
      READ (3'IREC) A(1)
      WRITE (3'IREC + 1) A(2)
      FIND (3'7)
      PRINT *, A(1), V
      END
