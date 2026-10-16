## `lge`

### **Name**

`lge` - `[CHARACTER:COMPARE]` ASCII Lexical greater than or equal

### **Synopsis**

```fortran
    result = lge(string_a, string_b)
```

```fortran
     elemental logical function lge(string_a, string_b)

      character(len=*),intent(in) :: string_a
      character(len=*),intent(in) :: string_b
```

### **Characteristics**

- `string_a` is default _character_ or an ASCII character string
- `string_b` is the same type and kind as `string_a`
- the result is a default logical

### **Description**

  `lge` determines whether one string is lexically greater than
  or equal to another string, where the two strings are interpreted as
  containing ASCII character codes. If `string_a` and `string_b`
  are not the same length, the shorter is compared as if spaces were
  appended to it to form a value that has the same length as the longer.

  The lexical comparison intrinsics `lge`, `lgt`(3), `lle`(3),
  and `llt`(3) differ from the corresponding intrinsic operators
  _`.ge.`, `.gt.`, `.le.`, and `.lt.`_, in that the latter use the processor's
  character ordering (which is not ASCII on some targets), whereas the
  former always use the ASCII ordering.

### **Options**

- `string_a`
  : string to be tested

- `string_b`
  : string to compare to `string_a`

### **Result**

  Returns `.true.` if `string_a` \>= `string_b`, and `.false.` otherwise,
  based on the ASCII collating sequence.

  If both input arguments are null strings, `.true.` is always returned.

  If either string contains a character not in the ASCII character set,
  the result is processor dependent.

### **Examples**

Sample program:

```fortran
program demo_lge
implicit none
integer :: i
   print *,'the ASCII collating sequence for printable characters'
   write(*,'(1x,19a)')(char(i),i=32,126) ! ASCII order
   write(*,*) lge('abc','ABC')           ! [T] lowercase is > uppercase
   write(*,*) lge('abc','abc  ')         ! [T] trailing spaces
   ! If both strings are of zero length the result is true
   write(*,*) lge('','')                 ! [T]
   write(*,*) lge('','a')                ! [F] the null string is padded
   write(*,*) lge('a','')                ! [T]
   ! elemental
   write(*,*) lge('abc',['abc','123'])   ! [T T]  scalar and array
   write(*,*) lge(['cba', '123'],'abc')  ! [T F]
   write(*,*) lge(['abc','123'],['cba','123']) ! [F T]  both arrays
end program demo_lge
```

Results:

```text
 >  the ASCII collating sequence for printable characters
 >   !"#$%&'()*+,-./012
 >  3456789:;<=>?@ABCDE
 >  FGHIJKLMNOPQRSTUVWX
 >  YZ[\]^_`abcdefghijk
 >  lmnopqrstuvwxyz{|}~
 >  T
 >  T
 >  T
 >  F
 >  T
 >  T T
 >  T F
 >  F T
```

### **Standard**

FORTRAN 77

### **See Also**

  `lgt`(3),
  `lle`(3),
  `llt`(3)

Functions that perform operations on character strings, return lengths
of arguments, and search for certain arguments:

- **Elemental:**
  `adjustl`(3),
  `adjustr`(3),
  `index`(3),

`scan`(3),
`verify`(3)

- **Nonelemental:**
  `len_trim`(3),
  `len`(3),
  `repeat`(3),
  `trim`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
