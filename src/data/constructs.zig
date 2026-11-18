//! Constructs and program units completion offers at the start of a
//! statement, as snippets (#264). `\t` stands for one level of
//! indentation; the end statement repeats the name's placeholder.

/// Where a construct can begin
pub const Place = enum {
    /// outside every program unit
    unit,
    /// outside every program unit, after CONTAINS, in an interface block
    procedure,
    /// in a specification part (of a module, a program, a procedure)
    spec,
    /// in an executable part
    exec,
    /// inside the construct `within`: a block of it (ELSE, CASE)
    part,
};

/// The construct a `part` belongs to
pub const Within = enum { none, if_, select_case, select_type, select_rank, where };

pub const Construct = struct {
    /// The words that begin it, as completion matches them
    name: []const u8,
    place: Place,
    within: Within = .none,
    /// The text inserted for a client with snippets
    snippet: []const u8,
    /// What completion shows beside the name
    detail: []const u8,
};

pub const all = [_]Construct{
    .{ .name = "PROGRAM", .place = .unit, .snippet = "PROGRAM ${1:name}\n\tIMPLICIT NONE\n\t$0\nEND PROGRAM ${1:name}", .detail = "PROGRAM ... END PROGRAM" },
    .{ .name = "MODULE", .place = .unit, .snippet = "MODULE ${1:name}\n\tIMPLICIT NONE\n\t$2\nCONTAINS\n\t$0\nEND MODULE ${1:name}", .detail = "MODULE ... END MODULE" },
    .{ .name = "SUBMODULE", .place = .unit, .snippet = "SUBMODULE (${1:parent}) ${2:name}\n\tIMPLICIT NONE\nCONTAINS\n\t$0\nEND SUBMODULE ${2:name}", .detail = "SUBMODULE ... END SUBMODULE" },
    .{ .name = "SUBROUTINE", .place = .procedure, .snippet = "SUBROUTINE ${1:name}($2)\n\t$0\nEND SUBROUTINE ${1:name}", .detail = "SUBROUTINE ... END SUBROUTINE" },
    .{ .name = "FUNCTION", .place = .procedure, .snippet = "FUNCTION ${1:name}($2) RESULT(${3:res})\n\t$0\nEND FUNCTION ${1:name}", .detail = "FUNCTION ... END FUNCTION" },
    .{ .name = "TYPE", .place = .spec, .snippet = "TYPE :: ${1:name}\n\t$0\nEND TYPE ${1:name}", .detail = "TYPE ... END TYPE" },
    .{ .name = "INTERFACE", .place = .spec, .snippet = "INTERFACE ${1:name}\n\t$0\nEND INTERFACE ${1:name}", .detail = "INTERFACE ... END INTERFACE" },
    .{ .name = "ABSTRACT INTERFACE", .place = .spec, .snippet = "ABSTRACT INTERFACE\n\t$0\nEND INTERFACE", .detail = "ABSTRACT INTERFACE ... END INTERFACE" },
    .{ .name = "ENUM", .place = .spec, .snippet = "ENUM, BIND(C)\n\tENUMERATOR :: ${1:name}$0\nEND ENUM", .detail = "ENUM, BIND(C) ... END ENUM" },
    .{ .name = "IF", .place = .exec, .snippet = "IF (${1:condition}) THEN\n\t$0\nEND IF", .detail = "IF (...) THEN ... END IF" },
    .{ .name = "DO", .place = .exec, .snippet = "DO ${1:i} = ${2:1}, ${3:n}\n\t$0\nEND DO", .detail = "DO ... END DO" },
    .{ .name = "DO WHILE", .place = .exec, .snippet = "DO WHILE (${1:condition})\n\t$0\nEND DO", .detail = "DO WHILE (...) ... END DO" },
    .{ .name = "DO CONCURRENT", .place = .exec, .snippet = "DO CONCURRENT (${1:i} = ${2:1}:${3:n})\n\t$0\nEND DO", .detail = "DO CONCURRENT (...) ... END DO" },
    .{ .name = "SELECT CASE", .place = .exec, .snippet = "SELECT CASE (${1:expr})\nCASE (${2:value})\n\t$3\nCASE DEFAULT\n\t$0\nEND SELECT", .detail = "SELECT CASE (...) ... END SELECT" },
    .{ .name = "SELECT TYPE", .place = .exec, .snippet = "SELECT TYPE (${1:obj})\nTYPE IS (${2:type_name})\n\t$3\nCLASS DEFAULT\n\t$0\nEND SELECT", .detail = "SELECT TYPE (...) ... END SELECT" },
    .{ .name = "SELECT RANK", .place = .exec, .snippet = "SELECT RANK (${1:array})\nRANK (${2:0})\n\t$3\nRANK DEFAULT\n\t$0\nEND SELECT", .detail = "SELECT RANK (...) ... END SELECT" },
    .{ .name = "ASSOCIATE", .place = .exec, .snippet = "ASSOCIATE (${1:name} => ${2:expr})\n\t$0\nEND ASSOCIATE", .detail = "ASSOCIATE (...) ... END ASSOCIATE" },
    .{ .name = "BLOCK", .place = .exec, .snippet = "BLOCK\n\t$0\nEND BLOCK", .detail = "BLOCK ... END BLOCK" },
    .{ .name = "WHERE", .place = .exec, .snippet = "WHERE (${1:mask})\n\t$0\nEND WHERE", .detail = "WHERE (...) ... END WHERE" },
    .{ .name = "FORALL", .place = .exec, .snippet = "FORALL (${1:i} = ${2:1}:${3:n})\n\t$0\nEND FORALL", .detail = "FORALL (...) ... END FORALL" },
    .{ .name = "CRITICAL", .place = .exec, .snippet = "CRITICAL\n\t$0\nEND CRITICAL", .detail = "CRITICAL ... END CRITICAL" },
    .{ .name = "ELSE IF", .place = .part, .within = .if_, .snippet = "ELSE IF (${1:condition}) THEN", .detail = "ELSE IF (...) THEN" },
    .{ .name = "ELSE", .place = .part, .within = .if_, .snippet = "ELSE", .detail = "ELSE" },
    .{ .name = "CASE", .place = .part, .within = .select_case, .snippet = "CASE (${1:value})", .detail = "CASE (...)" },
    .{ .name = "CASE DEFAULT", .place = .part, .within = .select_case, .snippet = "CASE DEFAULT", .detail = "CASE DEFAULT" },
    .{ .name = "TYPE IS", .place = .part, .within = .select_type, .snippet = "TYPE IS (${1:type_name})", .detail = "TYPE IS (...)" },
    .{ .name = "CLASS IS", .place = .part, .within = .select_type, .snippet = "CLASS IS (${1:class_name})", .detail = "CLASS IS (...)" },
    .{ .name = "CLASS DEFAULT", .place = .part, .within = .select_type, .snippet = "CLASS DEFAULT", .detail = "CLASS DEFAULT" },
    .{ .name = "RANK", .place = .part, .within = .select_rank, .snippet = "RANK (${1:0})", .detail = "RANK (...)" },
    .{ .name = "RANK DEFAULT", .place = .part, .within = .select_rank, .snippet = "RANK DEFAULT", .detail = "RANK DEFAULT" },
    .{ .name = "ELSEWHERE", .place = .part, .within = .where, .snippet = "ELSEWHERE", .detail = "ELSEWHERE" },
};
