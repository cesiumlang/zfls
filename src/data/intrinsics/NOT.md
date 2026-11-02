## `not`

### **Name**

`not` - `[BIT:LOGICAL]` Logical negation; flips all bits in an integer

### **Synopsis**

```fortran
    result = not(i)
```

```fortran
    elemental integer(kind=KIND) function not(i)

     integer(kind=KIND), intent(in) :: i
```

### **Characteristics**

- `i` may be an _integer_ of any valid kind
- The returned _integer_ is of the same kind as the argument `i`.

### **Description**

  `not` returns the bitwise Boolean inverse of `i`. This is also
  known as the "Bitwise complement" or "Logical negation" of the value.

  If an input bit is a one, that position is a zero on output. Conversely,
  any input bit that is zero is a one on output.

  This is called a bitwise Boolean inversion of integers. That is, `NOT(3f)`
  flips all the bits of its integer argument (changing 0s to 1s and 1s
  to 0s).

  `NOT(3)` alongside other bitwise functions like `IAND(3)`, `IOR(3)`, or
  `ISHFT(3)` allows for complex bit manipulation.

### **Options**

- `i`
  : The value to flip the bits of.

### **Result**

  The result has the value obtained by complementing `i` bit-by-bit
  according to the following truth table:

```text
   >    I   |  NOT(I)
   >    ----#----------
   >    1   |   0
   >    0   |   1
```

  That is, every input bit is flipped.

### **Examples**

Sample program

```fortran
program demo_not
implicit none
integer :: i
  ! basics
   i=-13741
   print *,'the input value',i,'represented in bits is'
   write(*,'(1x,b32.32,1x,i0)') i, i
   i=not(i)
   print *,'on output it is',i
   write(*,'(1x,b32.32,1x,i0)') i, i
   print *, " on a two's complement machine flip the bits and add 1"
   print *, " to get the value with the sign changed, for example."
   print *, 1234, not(1234)+1
   print *, -1234, not(-1234)+1
   print *, " of course 'x=-x' works just fine and more generally."
   !
   call bitmask_example()
contains

subroutine bitmask_example() ! Creating a Bitmask with NOT() and IAND()

! A real-world use case for NOT() is combining it  with IAND() (bitwise
! AND) to clear specific bits in a bitmask. In modern Fortran there
! procedures like IBCLR(3f) to do such operations.

integer :: flags, mask, cleared_flags

   ! Binary: 00001111 (in decimal: 15)
   flags = 15 
    
   ! We want to clear the 3rd bit (binary: 00000100, decimal: 4)
   mask = 4    

   ! NOT(mask) turns 00000100 into 11111011
   ! IAND then preserves everything EXCEPT the 3rd bit
   cleared_flags = IAND(flags, NOT(mask))

   print *, "Resulting value: ", cleared_flags ! Outputs: 11 (binary: 00001011)
end subroutine bitmask_example

end program demo_not
```

Results:

```text
  > the input value      -13741 represented in bits is
  > 11111111111111111100101001010011 -13741
  > on output it is       13740
  > 00000000000000000011010110101100 13740
  >  on a two's complement machine flip the bits and add 1
  >  to get the value with the sign changed, for example.
  >        1234       -1234
  >       -1234        1234
  >  of course 'x=-x' works just fine and more generally.
  >  Resulting value: 11
```

### **Standard**

Fortran 95

### **See Also**

`iand`(3),
`ior`(3),
`ieor`(3),
`ibits`(3),
`ibset`(3),

`ibclr`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
