## `dim`

### **Name**

`dim` - `[NUMERIC]` Positive difference of X - Y

### **Synopsis**

```fortran
    result = dim(x, y)
```

```fortran
     elemental TYPE(kind=KIND) function dim(x, y )

      TYPE(kind=KIND),intent(in) :: x, y
```

### **Characteristics**

- `x` and `y` may be any _real_ or _integer_ but of the same type
  and kind
- the result is of the same type and kind as the arguments

### **Description**

  `dim` returns the maximum of `x - y` and zero.
  That is, it returns the difference `x - y` if the result is positive;
  otherwise it returns zero. It is equivalent to

```fortran
  max(0,x-y)
```

### **Options**

- `x`
  : the subtrahend, i.e. the number being subtracted from.

- `y`
  : the minuend; i.e. the number being subtracted

### **Result**

Returns the difference `x - y` or zero, whichever is larger.

### **Examples**

Sample program:

```fortran
program demo_dim
use, intrinsic :: iso_fortran_env, only : real64
implicit none
integer           :: i
real(kind=real64) :: x

   ! basic usage
    i = dim(4, 15)
    x = dim(4.321_real64, 1.111_real64)
    print *, i
    print *, x

   ! elemental
    print *, dim([1,2,3],2)
    print *, dim([1,2,3],[3,2,1])
    print *, dim(-10,[0,-10,-20])

end program demo_dim
```

Results:

```text
 >            0
 >    3.21000000000000
 >            0           0           1
 >            0           0           2
 >            0           0          10
```

### **Standard**

FORTRAN 77

### **See Also**

- `abs`(3) - Absolute value
- `aint`(3) - Truncate toward zero to a whole number
- `anint`(3) - Real nearest whole number
- `ceiling`(3) - Integer ceiling function
- `conjg`(3) - Complex conjugate of a complex value
- `dim` - Positive difference of X - Y
- `dprod`(3) - Double precision real product
- `floor`(3) - Function to return largest integral value
- `max`(3) - Maximum value of an argument list
- `min`(3) - Minimum value of an argument list
- `mod`(3) - Remainder function
- `sign`(3) - Sign copying function

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
