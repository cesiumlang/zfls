## `minexponent`

### **Name**

`minexponent` - `[MODEL:NUMERIC]` Minimum exponent of a real kind

### **Synopsis**

```fortran
    result = minexponent(x)
```

```fortran
     elemental integer function minexponent(x)

      real(kind=**),intent(in) :: x
```

### **Characteristics**

- `x` is a _real_ scalar or array of any _real_ kind
- the result is a default _integer_ scalar

### **Description**

  `minexponent` returns the minimum exponent in the model of the
  type of `x`.

### **Options**

- `x`
  : A value used to select the kind of _real_ to return a value for.

### **Result**

  The value returned is the maximum exponent for the kind of the value
  queried

### **Examples**

Sample program:

```fortran
program demo_minexponent
use, intrinsic :: iso_fortran_env, only : real32, real64, real128
implicit none
real(kind=real32) :: x
real(kind=real64) :: y
    print *, minexponent(x), maxexponent(x)
    print *, minexponent(y), maxexponent(y)
end program demo_minexponent
```

Expected Results:

```text
  >     -125         128
  >    -1021        1024
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
