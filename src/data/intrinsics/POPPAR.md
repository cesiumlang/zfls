## `poppar`

### **Name**

`poppar` - `[BIT:COUNT]` Parity of the number of bits set

### **Synopsis**

```fortran
    result = poppar(i)
```

```fortran
     elemental integer function poppar(i)

      integer(kind=KIND), intent(in) :: i
```

### **Characteristics**

- `i` is an _integer_ of any kind
- the return value is a default kind _integer_

### **Description**

  `poppar` returns the parity of an integer's binary representation
  (i.e., the parity of the number of bits set).

  The parity is expressed as

- `0` (zero) if `i` has an even number of bits set to `1`.
- `1` (one) if the number of bits set to one `1` is odd,

### **Options**

- `i`
  : The value to query for its bit parity

### **Result**

  The return value is equal to `0` if `i` has an even number of bits
  set and `1` if an odd number of bits are set.

### **Examples**

Sample program:

```fortran
program demo_poppar
use, intrinsic :: iso_fortran_env, only : integer_kinds, &
   & int8, int16, int32, int64
implicit none
character(len=*),parameter :: pretty='(b64,1x,i0)'
   ! basic usage
   print pretty, 127,     poppar(127)
   print pretty, 128,     poppar(128)
   print pretty, int(b"01010"), poppar(int(b"01010"))

   ! any kind of an integer can be used
   print pretty, huge(0_int8),  poppar(huge(0_int8))
   print pretty, huge(0_int16), poppar(huge(0_int16))
   print pretty, huge(0_int32), poppar(huge(0_int32))
   print pretty, huge(0_int64), poppar(huge(0_int64))
end program demo_poppar
```

Results:

```text
 >                                                          1111111 1
 >                                                         10000000 1
 >                                                             1010 0
 >                                  1111111111111111111111111111111 1
 >                                                          1111111 1
 >                                                  111111111111111 1
 >                                  1111111111111111111111111111111 1
 >  111111111111111111111111111111111111111111111111111111111111111 1
```

### **Standard**

Fortran 2008

### **See Also**

There are many procedures that operator or query values at the bit level:

`popcnt`(3),
`leadz`(3),
`trailz`(3)
`atomic_and`(3),
`atomic_fetch_and`(3),
`atomic_fetch_or`(3),
`atomic_fetch_xor`(3),
`atomic_or`(3),
`atomic_xor`(3),
`bge`(3),
`bgt`(3),
`bit_size`(3),
`ble`(3),
`blt`(3),
`btest`(3),
`dshiftl`(3),
`dshiftr`(3),
`iall`(3),
`iand`(3),
`iany`(3),
`ibclr`(3),
`ibits`(3),
`ibset`(3),
`ieor`(3),
`ior`(3),
`iparity`(3),
`ishftc`(3),
`ishft`(3),
`maskl`(3),
`maskr`(3),
`merge_bits`(3),
`mvbits`(3),
`not`(3),
`shifta`(3),
`shiftl`(3),
`shiftr`(3),
`storage_size`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
