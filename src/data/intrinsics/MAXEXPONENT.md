## `maxexponent`

### **Name**

`maxexponent` - `[MODEL:NUMERIC]` Maximum exponent of a real kind

### **Synopsis**

```fortran
    result = maxexponent(x)
```

```fortran
     elemental integer function maxexponent(x)

      real(kind=**),intent(in) :: x
```

### **Characteristics**

- `x` is a _real_ scalar or array of any _real_ kind
- the result is a default _integer_ scalar

### **Description**

  `maxexponent` returns the maximum exponent in the model of the
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
program demo_maxexponent
use, intrinsic :: iso_fortran_env, only : real32,real64,real128
implicit none
character(len=*),parameter :: g='(*(g0,1x))'
   print  g,  minexponent(0.0_real32),   maxexponent(0.0_real32)
   print  g,  minexponent(0.0_real64),   maxexponent(0.0_real64)
   print  g,  minexponent(0.0_real128),  maxexponent(0.0_real128)
end program demo_maxexponent
```

Results:

```text
  >  -125 128
  >  -1021 1024
  >  -16381 16384
```

### **Standard**

Fortran 95

### **See Also**

`digits`(3),
`epsilon`(3),
`exponent`(3),
`fraction`(3),
`huge`(3),
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
