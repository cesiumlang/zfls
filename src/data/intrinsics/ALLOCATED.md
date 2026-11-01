## `allocated`

### **Name**

`allocated` - `[ARRAY:INQUIRY]` Allocation status of an allocatable entity

### **Synopsis**

```fortran
    result = allocated(array|scalar)
```

```fortran
     logical function allocated(array,scalar)

      type(TYPE(kind=**)),allocatable,optional :: array(..)
      type(TYPE(kind=**)),allocatable,optional :: scalar
```

### **Characteristics**

- a kind designated as ** may be any supported kind for the type
- `array` may be any allocatable array object of any type.
- `scalar` may be any allocatable scalar of any type.
- the result is a default logical scalar

### **Description**

  `allocated` checks the allocation status of both arrays
  and scalars.

 At least one and only one of `array` or `scalar` must be specified.

### **Options**

- `entity`
  : the _allocatable_ object to test.

### **Result**

  If the argument is allocated then the result is `.true.`; otherwise,
  it returns `.false.`.

### **Examples**

Sample program:

```fortran
   program demo_allocated
   use,intrinsic :: iso_fortran_env, only : dp=>real64,sp=>real32
   implicit none
   real(kind=sp), allocatable :: x(:)
   character(len=256) :: message
   integer :: istat
   
     ! basics
      if( allocated(x)) then
          write(*,*)'already allocated ????'
          write(*,*)'SIZE(X)=',size(x)
      else
          write(*,*)'not allocated so allocate it'
          allocate(x(10))
      endif
   
      ! how to test if already allocated, and deallocate if allocated
      if ( allocated(x) ) then
         write(*,*)'<warning> already allocated!'
         deallocate(x,STAT=istat, ERRMSG=message )
         if(istat.ne.0)then
            write(*,*)trim(message)
            stop
         endif
      endif
   
      ! only if not allocated, allocate
      if ( .not. allocated(x) ) allocate(x(20))
      write(*,*)'size of x() is now 10 or 20? It is ',size(x)
   
     ! a little surprise is that there is no call to deallocate
     ! in the INTENTOUT(3) procedure but X will be deallocated
     ! after this call!
      call intentout(x)
      write(*,*)merge('x is allocated  ','x is deallocated',allocated(x))
   
      contains
   
      subroutine intentout(arr)
      ! note that if arr has intent(out) and is allocatable,
      ! arr is deallocated on entry
      real(kind=sp),intent(out),allocatable :: arr(:)
          write(*,'(a)') &
          'note ARR might be allocated in calling program but because', &
          'of intent(out) it will be deallocated on entry to this', &
          'procedure automatically'
      end subroutine intentout
   
   end program demo_allocated
```

Results:

```text
 > not allocated so allocate it
 > <warning> already allocated!
 > size of x() is now 10 or 20? It is 20
 > note ARR might be allocated in calling program but because
 > of intent(out) it will be deallocated on entry to this
 > procedure automatically

```

### **Standard**

  Fortran 95. allocatable scalar entities were added in Fortran 2003.

### **See Also**

`move_alloc`(3)

 _Fortran intrinsic descriptions (license: MIT) \@urbanjost_
