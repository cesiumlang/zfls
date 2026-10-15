//! Fortran attribute keywords offered by completion, by the context they
//! apply in. Each table is sorted by name.

const Keyword = @import("schema.zig").Keyword;

pub const var_def = [_]Keyword{
    .{ .name = "ALLOCATABLE", .doc = "Specifies that an object is allocatable." },
    .{ .name = "ASYNCHRONOUS", .doc = "Specifies that a variable can be used for asynchronous input and output." },
    .{ .name = "BIND", .doc = "Specifies that an object is interoperable with C and has external linkage." },
    .{ .name = "CODIMENSION", .doc = "Specifies that an entity is a coarray, and specifies its corank and cobounds, if any." },
    .{ .name = "CONTIGUOUS", .doc = "Specifies that the target of a pointer or an assumed-sized array is contiguous." },
    .{ .name = "DIMENSION(:)", .doc = "Specifies that an object is an array, and defines the shape of the array." },
    .{ .name = "EXTERNAL", .doc = "Allows an external procedure, a dummy procedure, a procedure pointer, or a block data subprogram to be used as an actual argument." },
    .{ .name = "INTRINSIC", .doc = "Allows the specific name of an intrinsic procedure to be used as an actual argument." },
    .{ .name = "POINTER", .doc = "Specifies that an object or a procedure is a pointer (a dynamic variable)." },
    .{ .name = "PROTECTED", .doc = "Specifies limitations on the use of module entities." },
    .{ .name = "TARGET", .doc = "Specifies that an object can become the target of a pointer (it can be pointed to)." },
    .{ .name = "VOLATILE", .doc = "Specifies that the value of an object is entirely unpredictable, based on information local to the current program unit. It prevents objects from being optimized during compilation." },
};

pub const arg = [_]Keyword{
    .{ .name = "INTENT(IN)", .doc = "Specifies that the dummy argument will be used only to provide data to the procedure." },
    .{ .name = "INTENT(INOUT)", .doc = "Specifies that the dummy argument can both provide data to the procedure and return data to the calling program." },
    .{ .name = "INTENT(OUT)", .doc = "Specifies that the dummy argument will be used to pass data from the procedure back to the calling program." },
    .{ .name = "OPTIONAL", .doc = "Permits dummy arguments to be omitted in a procedure reference." },
    .{ .name = "SAVE", .doc = "Causes the values and definition of objects to be retained after execution of a RETURN or END statement in a subprogram." },
    .{ .name = "VALUE", .doc = "Specifies a type of argument association for a dummy argument." },
};

pub const type_mem = [_]Keyword{
    .{ .name = "DEFERRED", .doc = "Indicates that the procedure is deferred. Deferred bindings must only be specified for derived-type definitions with the ABSTRACT attribute." },
    .{ .name = "NON_OVERRIDABLE", .doc = "Determines whether a binding can be overridden in an extended type. You must not specify NON_OVERRIDABLE for a binding with the DEFERRED attribute." },
    .{ .name = "NOPASS", .doc = "Indicate that the procedure has no passed-object dummy argument." },
    .{ .name = "PASS", .args = "arg_name", .doc = "Indicates that the procedure has no passed-object dummy argument." },
};

pub const vis = [_]Keyword{
    .{ .name = "PRIVATE" },
    .{ .name = "PUBLIC" },
};

pub const param = [_]Keyword{
    .{ .name = "PARAMETER" },
};
