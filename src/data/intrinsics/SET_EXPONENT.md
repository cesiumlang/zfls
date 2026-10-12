## `set_exponent`

### **Name**

`set_exponent` - `[MODEL:COMPONENTS]` real value with specified exponent

### **Synopsis**

```fortran
    result = set_exponent(x, i)
```

```fortran
     elemental real(kind=KIND) function set_exponent(x,i)

      real(kind=KIND),intent(in) :: x
      integer(kind=**),intent(in) :: i
```

### **Characteristics**

- `x` is type _real_
- `i` is type _integer_
- a kind designated as ** may be any supported kind for the type

- The return value is of the same type and kind as `x`.

### **Description**

  `set_exponent` returns the real number whose fractional part is
  that of `x` and whose exponent part is `i`.

### **Options**

- `x`
  : Shall be of type _real_.

- `i`
  : Shall be of type _integer_.

### **Result**

  The return value is of the same type and kind as `x`. The real number
  whose fractional part is that of `x` and whose exponent part
  if `i` is returned; it is `fraction(x) * real(radix(x))**i`.

  If `x` has the value zero, the result has the same value as `x`.

  If `x` is an IEEE infinity, the result is an IEEE NaN.

  If `x` is an IEEE NaN, the result is the same NaN.

### **Examples**

Sample program:

```fortran
program demo_setexp
implicit none
real :: x = 178.1387e-4
integer :: i = 17
   print *, set_exponent(x, i), fraction(x) * real(radix(x))**i
end program demo_setexp
```

Results:

```text
  >   74716.7891       74716.7891
```

### **Standard**

Fortran 95

### **See Also**

`digits`(3),
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
`spacing`(3),
`tiny`(3)

 _Fortran intrinsic descriptions_
