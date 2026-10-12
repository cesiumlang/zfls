## `event_query`

### **Name**

`event_query` - `[COLLECTIVE]` Query whether a coarray event has occurred

### **Synopsis**

```fortran
    call event_query(event, count [,stat] )
```

```fortran
```

### **Characteristics**

### **Description**

`event_query` assigns the number of events to `count` which have been
posted to the `event` variable and not yet been removed by calling
`event_wait`. When `stat` is present and the invocation was successful, it
is assigned the value `0`. If it is present and the invocation has failed,
it is assigned a positive value and `count` is assigned the value `-1`.

### **Options**

- `event`
  : (intent(in)) Scalar of type `event_type`, defined in
  `iso_fortran_env`; shall not be coindexed.

- `count`
  : (intent(out))Scalar integer with at least the precision of default
  _integer_.

- `stat`
  : (OPTIONAL) Scalar default-kind _integer_ variable.

### **Examples**

Sample program:

```fortran
program demo_event_query
use iso_fortran_env
implicit none
type(event_type) :: event_value_has_been_set[*]
integer :: cnt
   if (this_image() == 1) then
      call event_query(event_value_has_been_set, cnt)
      if (cnt > 0) write(*,*) "Value has been set"
   elseif (this_image() == 2) then
      event post(event_value_has_been_set[1])
   endif
end program demo_event_query
```

### **Standard**

TS 18508

### **See also**

- `co_broadcast`(3) - Copy a value to all images the current set of images
- `co_lbound`(3) - Lower codimension bounds of an array
- `co_max`(3) - Maximal value on the current set of images
- `co_min`(3) - Minimal value on the current set of images
- `co_reduce`(3) - Reduction of values on the current set of images
- `co_sum`(3) - Sum of values on the current set of images
- `co_ubound`(3) - Upper codimension bounds of an array
- `event_query`(3) - Query whether a coarray event has occurred
- `image_index`(3) - Cosubscript to image index conversion
- `lcobound`(3) - Lower codimension bounds of an array
- `num_images`(3) - Number of images
- `this_image`(3) - Cosubscript index of this image
- `ucobound`(3) - Upper codimension bounds of an array

 _Fortran intrinsic descriptions_
