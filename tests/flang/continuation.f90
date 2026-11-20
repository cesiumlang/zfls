! Free-form continuation as LLVM Flang reads it: a name split across lines,
! comments and blank lines inside a statement, statements after ;, and
! a line longer than 132 columns
module continuation
  implicit none
  integer :: first, &
             ! a comment inside the statement

             second
  real :: spl&
         &it_name
  integer :: a; integer :: b; real :: &
    c
  character(len=*), parameter :: text = "a ! not a comment, & not continued"
  integer :: long_line_1, long_line_2, long_line_3, long_line_4, long_line_5, long_line_6, long_line_7, long_line_8, long_line_9, past_132
end module continuation
