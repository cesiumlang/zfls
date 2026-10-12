## `lgt`

### **Name**

`lgt` - `[CHARACTER:COMPARE]` ASCII Lexical greater than

### **Synopsis**

```fortran
     result = lgt(string_a, string_b)
```

```fortran
      elemental logical function lgt(string_a, string_b)

       character(len=*),intent(in) :: string_a
       character(len=*),intent(in) :: string_b
```

### **Characteristics**

- `string_a` is default _character_ or an ASCII character string
- `string_b` is the same type and kind as `string_a`
- the result is a default logical

### **Description**

  `lgt` determines whether one string is lexically greater than
  another string, where the two strings are interpreted as containing
  ASCII character codes. If the String `a` and String `b` are not
  the same length, the shorter is compared as if spaces were appended
  to it to form a value that has the same length as the longer.

  In general, the lexical comparison intrinsics `lge`, `lgt`, `lle`,
  and `llt` differ from the corresponding intrinsic operators _`.ge.`,
  `.gt.`, `.le.`, and `.lt.`_, in that the latter use the processor's character
  ordering (which is not ASCII on some targets), whereas the former
  always use the ASCII ordering.

### **Options**

- `string_a`
  : string to be tested

- `string_b`
  : string to compare to `string_a`

### **Result**

  Returns `.true.` if `string_a` \> `string_b`, and `.false.` otherwise,
  based on the ASCII ordering.

  If both input arguments are null strings, `.false.` is returned.

  If either string contains a character not in the ASCII character set,
  the result is processor dependent.

### **Examples**

Sample program:

```fortran
program demo_lgt
implicit none
integer :: i
   print *,'the ASCII collating sequence for printable characters'
   write(*,'(1x,19a)')(char(i),i=32,126)

   write(*,*) lgt('abc','ABC')          ! [T] lowercase is > uppercase
   write(*,*) lgt('abc','abc  ')        ! [F] trailing spaces

   ! If both strings are of zero length the result is false.
   write(*,*) lgt('','')                ! [F]
   write(*,*) lgt('','a')               ! [F] the null string is padded
   write(*,*) lgt('a','')               ! [T]
   write(*,*) lgt('abc',['abc','123'])  ! [F T]  scalar and array
   write(*,*) lgt(['cba', '123'],'abc') ! [T F]
   write(*,*) lgt(['abc','123'],['cba','123']) ! [F F]  both arrays
end program demo_lgt
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
 >  F
 >  F
 >  F
 >  T
 >  F T
 >  T F
 >  F F
```

### **Standard**

FORTRAN 77

### **See Also**

 `lge`(3),
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
