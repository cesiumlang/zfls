## `kind`

### **Name**

`kind` - `[KIND:INQUIRY]` Query kind of an entity

### **Synopsis**

```fortran
    result = kind(x)
```

```fortran
     integer function kind(x)

      type(TYPE(kind=**)),intent(in) :: x(..)
```

### **Characteristics**

- `x` may be of any intrinsic type. It may be a scalar or an array.
- the result is a default _integer_ scalar

### **Description**

   `kind(x)`(3) returns the kind value of the entity `x`.

### **Options**

- `x`
  : Value to query the kind of.

### **Result**

  The return value indicates the kind of the argument `x`.

  Note that kinds are processor-dependent.

### **Examples**

Sample program:

```fortran
program demo_kind
implicit none
integer,parameter :: dc = kind(' ')
integer,parameter :: dl = kind(.true.)

   print *, "The default character kind is ", dc
   print *, "The default logical kind is ", dl

end program demo_kind
```

Results:

```text
  > The default character kind is            1
  > The default logical kind is            4
```

### **Standard**

Fortran 95

### **See also**

- `allocated`(3) - Status of an allocatable entity
- `is_contiguous`(3) - test if object is contiguous
- `lbound`(3) - Lower dimension bounds of an array
- `rank`(3) - Rank of a data object
- `shape`(3) - Determine the shape of an array
- `size`(3) - Determine the size of an array
- `ubound`(3) - Upper dimension bounds of an array
- `bit_size`(3) - Bit size inquiry function
- `storage_size`(3) - Storage size in bits

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
