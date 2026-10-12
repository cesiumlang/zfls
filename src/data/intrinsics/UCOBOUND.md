## `ucobound`

### **Name**

`ucobound` - `[COLLECTIVE]` Upper codimension bounds of an array

### **Synopsis**

```fortran
    result = ucobound(coarray [,dim] [,kind] )
```

```fortran
```

### **Characteristics**

### **Description**

`ucobound` returns the upper cobounds of a coarray, or a single
upper cobound along the `dim` codimension.

### **Options**

- `array`
  : Shall be a coarray, of any type.

- `dim`
  : (Optional) Shall be a scalar _integer_.

- `kind`
  : (Optional) An _integer_ initialization expression indicating the kind
  parameter of the result.

### **Result**

The return value is of type _integer_ and of kind `kind`. If `kind` is absent,
the return value is of default integer kind. If `dim` is absent, the
result is an array of the lower cobounds of `coarray`. If `dim` is present,
the result is a scalar corresponding to the lower cobound of the array
along that codimension.

### **Standard**

Fortran 2008

### **See Also**

`lcobound`(3),
`lbound`(3),
`ubound`(3)
