//! Fortran statements offered by completion, with their documentation.
//! Each table is sorted by name.

const Keyword = @import("schema.zig").Keyword;

pub const var_def = [_]Keyword{
    .{ .name = "CHARACTER", .args = "LEN=len" },
    .{ .name = "CLASS", .args = "name" },
    .{ .name = "COMPLEX", .args = "KIND=kind" },
    .{ .name = "DOUBLE COMPLEX" },
    .{ .name = "DOUBLE PRECISION" },
    .{ .name = "INTEGER", .args = "KIND=kind" },
    .{ .name = "LOGICAL", .args = "KIND=kind" },
    .{ .name = "REAL", .args = "KIND=kind" },
    .{ .name = "TYPE", .args = "KIND=kind" },
};

pub const int_stmnts = [_]Keyword{
    .{ .name = "ALLOCATE", .doc = "Dynamically creates storage for allocatable variables and pointer targets." },
    .{ .name = "BACKSPACE", .doc = "Positions a sequential file at the beginning of the preceding record, making it available for subsequent I/O processing." },
    .{ .name = "CALL", .doc = "Transfers control to a subroutine subprogram." },
    .{ .name = "CLOSE", .doc = "Disconnects a file from a unit." },
    .{ .name = "CONTINUE", .doc = "Primarily used to terminate a labelled DO construct when the construct would otherwise end improperly with either a GO TO, arithmetic IF, or other prohibited control statement." },
    .{ .name = "CYCLE", .doc = "Interrupts the current execution cycle of the innermost (or named) DO construct." },
    .{ .name = "DEALLOCATE", .doc = "Frees the storage allocated for allocatable variables and nonprocedure pointer targets (and causes the pointers to become disassociated)." },
    .{ .name = "ENDFILE", .doc = "For sequential files, writes an end-of-file record to the file and positions the file after this record (the terminal point)." },
    .{ .name = "ERROR STOP", .doc = "Initiates error termination of an image before the execution of an END statement of the main program." },
    .{ .name = "EVENT POST", .doc = "Allows an image to notify another image that it can proceed to work on tasks that use common resources." },
    .{ .name = "EVENT WAIT", .doc = "Allows an image to wait on events posted by other images." },
    .{ .name = "FAIL IMAGE", .doc = "Forces the failure of the current image of the program unit." },
    .{ .name = "FLUSH", .doc = "Causes data written to a file to become available to other processes or causes data written to a file outside of Fortran to be accessible to a READ statement." },
    .{ .name = "FORM TEAM", .args = "team_number,team_variable", .doc = "Defines team variables; creates one or more teams of images from the images on the current team." },
    .{ .name = "FORMAT", .doc = "Specifies the form of data being transferred and the data conversion (editing) required to achieve that form." },
    .{ .name = "INQUIRE", .doc = "Returns information on the status of specified properties of a file or logical unit." },
    .{ .name = "LOCK", .doc = "Causes a lock variable to become locked by an image." },
    .{ .name = "NAMELIST", .doc = "Associates a name with a list of variables. This group name can be referenced in some input/output operations." },
    .{ .name = "NULLIFY", .doc = "Disassociates a pointer from a target." },
    .{ .name = "OPEN", .doc = "Connects an external file to a unit, creates a new file and connects it to a unit, creates a preconnected file, or changes certain properties of a connection." },
    .{ .name = "PRINT", .doc = "Displays output on the screen." },
    .{ .name = "READ", .doc = "Transfers input data from external sequential, direct-access, or internal records." },
    .{ .name = "RETURN", .doc = "Return control to the calling program unit." },
    .{ .name = "REWIND", .doc = "Positions a sequential or direct access file at the beginning of the file (the initial point)." },
    .{ .name = "STOP", .doc = "Initiates normal termination of an image before the execution of an END statement of the main program." },
    .{ .name = "SYNC ALL", .args = "STAT=stat,ERRMSG=errmsg", .doc = "Performs a synchronization of all images in the current team." },
    .{ .name = "SYNC IMAGES", .args = "image_set,STAT=stat,ERRMSG=errmsg", .doc = "Performs a synchronization of the image with each of the other images in the image set." },
    .{ .name = "SYNC MEMORY", .args = "STAT=stat,ERRMSG=errmsg", .doc = "Ends one image segment and begins another. Each segment can then be ordered in some way with respect to segments on other images." },
    .{ .name = "SYNC TEAM", .args = "team_value,STAT=stat,ERRMSG=errmsg", .doc = "Performs a synchronization of all images on the specified team." },
    .{ .name = "UNLOCK", .doc = "Causes a lock variable to become unlocked by an image." },
    .{ .name = "WAIT", .doc = "Performs a wait operation for a specified pending asynchronous data transfer operation." },
    .{ .name = "WRITE", .doc = "Transfers output data to external sequential, direct-access, or internal records." },
};
