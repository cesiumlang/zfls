## `popcnt`

### **Name**

`popcnt` - `[BIT:COUNT]` Number of bits set

### **Synopsis**

```fortran
    result = popcnt(i)
```

```fortran
     elemental integer function popcnt(i)

      integer(kind=KIND), intent(in) :: i
```

### **Characteristics**

- `i` may be an _integer_ of any kind.
- The return value is an _integer_ of the default integer kind.

### **Description**

  `popcnt` returns the number of bits set to one in the binary
  representation of an _integer_.

### **Options**

- `i`
  : value to count set bits in

### **Result**

The number of bits set to one in `i`.

### **Examples**

Sample program:

```fortran
program demo_popcnt
use, intrinsic :: iso_fortran_env, only : integer_kinds, &
   & int8, int16, int32, int64
implicit none
character(len=*),parameter :: pretty='(b64,1x,i0)'
  ! basic usage
   print pretty, 127,     popcnt(127)
   print pretty, int(b"01010"), popcnt(int(b"01010"))

  ! any kind of an integer can be used
   print pretty, huge(0_int8),  popcnt(huge(0_int8))
   print pretty, huge(0_int16), popcnt(huge(0_int16))
   print pretty, huge(0_int32), popcnt(huge(0_int32))
   print pretty, huge(0_int64), popcnt(huge(0_int64))
end program demo_popcnt
```

Results:

Note that on most machines the first bit is the sign bit, and a zero is
used for positive values; but that this is system-dependent. These are
typical values, where the `huge`(3) function has set all but the first
bit to 1.

```text
 >                                                         1111111 7
 >                                                            1010 2
 >                                                         1111111 7
 >                                                 111111111111111 15
 >                                 1111111111111111111111111111111 31
 > 111111111111111111111111111111111111111111111111111111111111111 63
```

### **Standard**

Fortran 2008

### **See Also**

There are many procedures that operator or query values at the bit level:

`poppar`(3),
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
