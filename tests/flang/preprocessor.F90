! LLVM Flang's preprocessor (-cpp, an upper-case suffix): macros in
! declarations, a function-like macro, #if with defined(), an #include,
! and the macros Flang predefines (__flang__)
#include "pp_decls.h"
#define DECLARE(name) integer :: name
#define WP 8
#if defined(WP) && WP == 8
#define HAVE_WP
#endif
module preprocessor
  implicit none
  real(WP) :: wide
  DECLARE(from_macro)
#ifdef HAVE_WP
  integer :: when_wp
#else
  integer :: without_wp
#endif
#ifdef __flang__
  integer :: in_flang
#else
  integer :: not_flang
#endif
  PP_DECL_INT :: from_header
end module preprocessor
