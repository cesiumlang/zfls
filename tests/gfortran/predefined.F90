! __LINE__, __FILE__, __DATE__ and __TIME__ of gfortran's preprocessor (#507)
module predefined
  implicit none
  integer :: lines(__LINE__)
  character(len=*), parameter :: here = __FILE__, day = __DATE__, now = __TIME__
end module predefined
