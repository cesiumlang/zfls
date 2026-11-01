## `dble`

### **Name**

`dble` - `[TYPE:CONVERSION]` Conversion to double precision real

### **Synopsis**

```fortran
    result = dble(a)
```

```fortran
     elemental doubleprecision function dble(a)

      doubleprecision :: dble
      TYPE(kind=KIND),intent(in) :: a
```

### **Characteristics**

- `a` may be _integer_, _real_, _complex_, or a BOZ-literal-constant
- the result is a doubleprecision _real_.

### **Description**

`dble` Converts `a` to double precision _real_ type.
It is equivalent to

```text
integer,parameter :: dp=kind(0.0d0)
real(a,kind=dp)
```

### **Options**

- `a`
  : a value to convert to a doubleprecision _real_.

### **Result**

The return value is of type _doubleprecision_. For _complex_ input,
the returned value has the magnitude and sign of the real component
of the input value.

### **Examples**

Sample program:

```fortran
program demo_dble
implicit none
real:: x = 2.18
integer :: i = 5
complex :: z = (2.3,1.14)
   print *, dble(x), dble(i), dble(z)
end program demo_dble
```

Results:

```text
  > 2.1800000667572021  5.0000000000000000   2.2999999523162842
```

### **Standard**

FORTRAN 77

### **See also**

- `aimag`(3) - Imaginary part of complex number
- `cmplx`(3) - Convert values to a complex type
- `int`(3) - Truncate towards zero and convert to integer
- `nint`(3) - Nearest whole number
- `out_of_range`(3) - Whether a value cannot be converted safely.
- `real`(3) - Convert to real type

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
