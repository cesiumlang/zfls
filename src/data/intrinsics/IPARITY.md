## `iparity`

### **Name**

`iparity` - `[BIT:LOGICAL]` Bitwise exclusive OR of array elements

### **Synopsis**

```fortran
    result = iparity( array [,mask] ) | iparity( array, dim [,mask] )
```

```fortran
     integer(kind=KIND) function iparity(array, dim, mask )

      integer(kind=KIND),intent(in) :: array(..)
      logical(kind=**),intent(in),optional :: dim
      logical(kind=**),intent(in),optional :: mask(..)
```

- `array` - An _integer_ array.
- `dim` - an _integer_ scalar from 1 to the rank of `array`
- `mask` - _logical_ conformable with `array`.

### **Description**

`iparity` reduces with bitwise _xor_ (exclusive _or_) the elements
of `array` along dimension `dim` if the corresponding element in
`mask` is `.true.`.

### **Options**

- `array`
  : an array of _integer_ values

- `dim`
  : a value from 1 to the rank of `array`.

- `mask`
  : a _logical_ mask either a scalar or an array of the same shape
  as `array`.

### **Result**

The result is of the same type as `array`.

If `dim` is absent, a scalar with the bitwise _xor_ of all elements in `array`
is returned. Otherwise, an array of rank `n-1`, where `n` equals the
rank of `array`, and a shape similar to that of `array` with dimension `dim`
dropped is returned.

  Case (i)
  : The result of `IPARITY (ARRAY)` has a value equal to the
    bitwise exclusive OR of all the elements of ARRAY. If
    ARRAY has size zero the result has the value zero.

  Case (ii)
  : The result of `IPARITY (ARRAY, MASK=MASK)` has a value
    equal to that of

```fortran
       IPARITY (PACK (ARRAY, MASK)).
```

  Case (iii)
  : The result of `IPARITY (ARRAY, DIM=DIM [, MASK=MASK])`
    has a value equal to that of `IPARITY (ARRAY [, MASK=MASK])`
    if ARRAY has rank one.

```text
Otherwise, an array of values reduced along the dimension
DIM is returned.
```

### **Examples**

Sample program:

```fortran
program demo_iparity
implicit none
integer, dimension(2) :: a
  a(1) = int(b'00100100')
  a(2) = int(b'01101010')
  print '(b8.8)', iparity(a)
end program demo_iparity
```

Results:

```text
 > 01001110
```

### **Standard**

Fortran 2008

### **See Also**

`iany`(3),
`iall`(3),
`ieor`(3),
`parity`(3)

 _Fortran intrinsic descriptions_
