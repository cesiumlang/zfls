## `sinpi`

### **Name**

`sinpi` - `[MATHEMATICS:TRIGONOMETRIC]` Circular sine function

### **Synopsis**

```fortran
    result = sinpi(x)
```

```fortran
     elemental real(kind=KIND) function sinpi(x)

      real(kind=KIND) :: x
```

### **Characteristics**

- `x` may be any _real_
- `KIND` may be any kind supported by the associated real type of `x`.
- The returned value will be of the same type and kind as the argument
    `x`.

### **Description**

  `sinpi` computes the circular sine of an angle given the size of the angle
  in half-revolutions.

  `sinpi(X)` is approximately equal to `sin(x*PI)`.

  The sine of an angle in a right-angled triangle is the ratio of the
  length of the side opposite the given angle divided by the length of
  the hypotenuse.

### **Options**

- `x`
  : The angle in half-revolutions to compute the sine of.

### **Result**

  The return value contains the processor-dependent approximation of
  the sine of `x`.

### **Examples**

Example. `sinpi(1.0)` has the value 0.0 (approximately).

Sample program:

```fortran
program demo_sinpi
implicit none
real    :: x
integer :: i
real,parameter :: PI=acos(-1.0)
   do i=0,8
      x=i*0.25
      write(*,*)'x=',x,' sinpi(x)=',
      & sinpi(x), 
      & sin(PI*x),
      & sinpi(x) - sin(PI*x)
   enddo
end program demo_sinpi
```

Results:

```text
 > x=  0.000000  sinpi(x)= 0.00000000      0.00000000      0.0000
 > x=  0.2500000 sinpi(x)= 0.707106769     0.707106769     0.0000
 > x=  0.5000000 sinpi(x)= 1.00000000      1.00000000      0.0000
 > x=  0.7500000 sinpi(x)= 0.707106769     0.707106769     0.0000
 > x=  1.000000  sinpi(x)= -8.74227766E-08 -8.74227766E-08 0.0000
 > x=  1.250000  sinpi(x)= -0.707106888    -0.707106888    0.0000
 > x=  1.500000  sinpi(x)= -1.00000000     -1.00000000     0.0000
 > x=  1.750000  sinpi(x)= -0.707106531    -0.707106531    0.0000
 > x=  2.000000  sinpi(x)= 1.74845553E-07  1.74845553E-07  0.0000
```

### **Standard**

Fortran 2023

### **See Also**

- `acos`(3), `acosd`(3), `acospi`(3),
- `asin`(3), `asind`(3),
- `atan2`(3), `atan2d`(3), `atan2pi`(3),
- `cos`(3), `cosd`(3), `cospi`(3),
- `tan`(3), `tand`(3), `tanpi`(3),
- `acosh`(3),
- `acosh`(3),
- `asinh`(3),
- `asinh`(3),
- `atanh`(3)
- `atanh`(3),

### **Resources**

- [Wikipedia:sine and cosine](https://en.wikipedia.org/wiki/Sine_and_cosine)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
