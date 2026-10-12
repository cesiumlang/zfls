## `digits`

### **Name**

`digits` - `[MODEL:NUMERIC]` Significant digits in the numeric model

### **Synopsis**

```fortran
    result = digits(x)
```

```fortran
     integer function digits(x)

      TYPE(kind=KIND),intent(in) :: x(..)
```

### **Characteristics**

- `x` an _integer_ or _real_ scalar or array

- The return value is an _integer_ of default kind.

### **Description**

  `digits` returns the number of significant digits of the internal
  model representation of `x`. For example, on a system using a 32-bit
  floating point representation, a default real number would likely
  return 24.

### **Options**

- `x`
  : a value of the type and kind to query

### **Result**

  The number of significant digits in a variable of the type and kind
  of `x`.

### **Examples**

Sample program:

```fortran
program demo_digits
implicit none
character(len=*),parameter :: all='(*(g0:,1x))'
integer                    :: i = 12345
real                       :: x = 3.143
doubleprecision            :: y = 2.33d0
   print all, 'default integer:        ', digits(i)
   print all, 'default real:           ', digits(x)
   print all, 'default doubleprecision:', digits(y)
end program demo_digits
```

Results:

```text
 > default integer:         31
 > default real:            24
 > default doubleprecision: 53
```

### **Standard**

Fortran 95

### **See Also**

`epsilon`(3),
`exponent`(3),
`fraction`(3),
`huge`(3),
`maxexponent`(3),
`minexponent`(3),
`nearest`(3),
`precision`(3),
`radix`(3),
`range`(3),
`rrspacing`(3),
`scale`(3),
`set_exponent`(3),
`spacing`(3),
`tiny`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
