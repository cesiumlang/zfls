## `fraction`

### **Name**

`fraction` - `[MODEL:COMPONENTS]` Fractional part of the model representation

### **Synopsis**

```fortran
    result = fraction(x)
```

```fortran
     elemental real(kind=KIND) function fraction(x)

      real(kind=KIND),intent(in) :: fraction
```

### **Characteristics**

- `x` is of type _real_
- The result has the same characteristics as the argument.

### **Description**

  `fraction` returns the fractional part of the model representation
  of `x`.

### **Options**

- `x`
  : The value to interrogate

### **Result**

The fractional part of the model representation of `x` is returned;
it is

```fortran
    x * real(radix(x))**(-exponent(x))
```

If `x` has the value zero, the result is zero.

If `x` is an IEEE NaN, the result is that NaN.

If `x` is an IEEE infinity, the result is an IEEE NaN.

### **Examples**

Sample program:

```fortran
program demo_fraction
implicit none
real :: x
   x = 178.1387e-4
   print *, fraction(x), x * real(radix(x))**(-exponent(x))
   x = 10.0
   print *, fraction(x)
   print *, fraction(x) * 2**4
end program demo_fraction
```

Results:

```text
 >   0.570043862      0.570043862
 >   0.625000000
 >    10.0000000
```

### **Standard**

Fortran 95

### **See Also**

`digits`(3),
`epsilon`(3),
`exponent`(3),
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

 _Fortran intrinsic descriptions_
