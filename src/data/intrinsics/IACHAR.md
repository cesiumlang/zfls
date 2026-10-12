## `iachar`

### **Name**

`iachar` - `[CHARACTER:CONVERSION]` Return integer ASCII code of a character

### **Synopsis**

```fortran
    result = iachar(c [,kind])
```

```fortran
     elemental integer(kind=KIND) function iachar(c,kind)

      character(len=1),intent(in) :: c
      integer(kind=**),intent(in),optional :: KIND
```

### **Characteristics**

- `c` is a single character
- The return value is of type _integer_ and of kind `KIND`. If `KIND`
   is absent, the return value is of default integer kind.

 NOTE:
 : a kind designated as ** may be any supported kind for the type

### **Description**

  `iachar` returns the code for the ASCII character in the first
  character position of C.

### **Options**

- `c`
  : A character to determine the ASCII code of.
    A common extension is to allow strings but all but the first character
  is then ignored.

- `kind`
  : A constant initialization expression indicating the kind
  parameter of the result.

### **Result**

  the result is the position of the character `c` in the ASCII
  collating sequence. It is nonnegative and less than or equal to 127.

  By ASCII, it is meant that `c` is in the collating sequence defined
  by the codes specified in ISO/IEC 646:1991 (International Reference
  Version).

  The value of the result is processor dependent if `c` is not in the
  ASCII collating sequence.

  The results are consistent with the `lge`(3), `lgt`(3), `lle`(3),
  and `llt`(3) comparison functions. For example, if `lle(C, D)`
  is true, `iachar(C) <= iachar (D)` is true where `C` and `D`
  are any two characters representable by the processor.

### **Examples**

Sample program:

```fortran
program demo_iachar
implicit none
   ! basic usage
    ! just does a string one character long
    write(*,*)iachar('A')
    ! elemental: can do an array of letters
    write(*,*)iachar(['A','Z','a','z'])

   ! convert all characters to lowercase
    write(*,'(a)')lower('abcdefg ABCDEFG')
contains
!
pure elemental function lower(str) result (string)
! Changes a string to lowercase
character(*), intent(In)     :: str
character(len(str))          :: string
integer                      :: i
   string = str
   ! step thru each letter in the string in specified range
   do i = 1, len(str)
      select case (str(i:i))
      case ('A':'Z') ! change letter to miniscule
         string(i:i) = char(iachar(str(i:i))+32)
      case default
      end select
   end do
end function lower
!
end program demo_iachar
```

Results:

```text
 > 65
 > 65          90          97         122
 > abcdefg abcdefg
```

### **Standard**

  Fortran 95, with KIND argument - Fortran 2003

### **See Also**

`achar`(3),
`char`(3),
`ichar`(3)

  See `ichar`(3) in particular for a discussion of converting
  between numerical values and formatted string representations.

  Functions that perform operations on character strings, return lengths
  of arguments, and search for certain arguments:

- **Elemental:**
  `adjustl`(3), `adjustr`(3), `index`(3),
  `scan`(3), `verify`(3)

- **Nonelemental:**
  `len_trim`(3),
  `len`(3),
  `repeat`(3), `trim`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
