## `repeat`

### **Name**

`repeat` - `[CHARACTER:PAD]` Repeated string concatenation

### **Synopsis**

```fortran
    result = repeat(string, ncopies)
```

```fortran
     character(len=len(string)*ncopies) function repeat(string, ncopies)

      character(len=*),intent(in)   :: string
      integer(kind=**),intent(in)   :: ncopies
```

### **Characteristics**

- a kind designated as ** may be any supported kind for the type
- `string` is a scalar _character_ type.
- `ncopies` is a scalar integer.
- the result is a new scalar of type _character_ of the same kind as
   the variable `string`.

### **Description**

  `repeat` concatenates copies of a string.

### **Options**

- `string`
  : The input string to repeat

- `ncopies`
  : Number of copies to make of `string`, greater than or equal to zero (0).

### **Result**

  A new string built up from `ncopies` copies of `string`.

### **Examples**

Sample program:

```fortran
program demo_repeat
implicit none
    write(*,'(a)') repeat("^v", 35)         ! line break
    write(*,'(a)') repeat("_", 70)          ! line break
    write(*,'(a)') repeat("1234567890", 7)  ! number line
    write(*,'(a)') repeat("         |", 7)  !
end program demo_repeat
```

Results:

```text
 > ^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v^v
 > ______________________________________________________________________
 > 1234567890123456789012345678901234567890123456789012345678901234567890
 >          |         |         |         |         |         |         |
```

### **Standard**

Fortran 95

### **See Also**

Functions that perform operations on character strings:

- **Elemental:**
  `adjustl`(3),
  `adjustr`(3),
  `index`(3),
  `scan`(3),
  `verify`(3)

- `Non-elemental:`
  `len_trim`(3),
  `len`(3),
  `repeat`,
  `trim`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
