# Diagnostics and dialects

## Diagnostics

Each diagnostic has a code (shown by editors, e.g. in the VS Code Problems panel): `line-too-long`, `comment-too-long`, `statement-without-scope`, `multiple-contains`, `unexpected-end`, `mismatched-end`, `unclosed-scope`, `invalid-parent`, `procedure-before-contains`, `declared-twice`, `masks-parent`, `import-outside-interface`, `import-excludes-name`, `module-not-found`, `use-after-implicit`, `deferred-not-implemented`, `intent-not-in-arguments`, `argument-not-declared`, `not-imported`, `object-not-found`, `undeclared-name`, `unused-name`, `circular-use`, `argument-mismatch`, `argument-kind`, `intent-in-assigned`, `include-not-found`, `preprocessor-condition`, `use-name-not-found`, `argument-not-definable`, `argument-too-short`, `argument-storage-short`, `constant-assigned`, `label-defined-twice`, `label-not-found`, `case-value-overlap`, `exit-outside-loop`, `cycle-outside-loop`, `parameter-without-value`, `duplicate-dummy`, `bad-kind`, `subscript-count`, `unknown-component`, `allocate-object`, `allocate-shape`, `assignment-type`, `condition-type` and `intrinsic-arguments`.

- zfls publishes its diagnostics of a document when it is opened, when it is saved, and while it is edited: once its text has not changed for `diagnostics_change_delay` milliseconds (300 by default), so that a burst of typing costs one check, of the last text. 0 publishes with each change, a negative value only when the document is opened and saved. Other open documents that use a changed module follow when it is saved. A result of the compiler or a linter for a changed text is published with zfls's diagnostics of that text, not before them.
- A client that pulls diagnostics (its `textDocument.diagnostic` capability, as VS Code's has) asks for zfls's own when it shows a document (`textDocument/diagnostic`), and with `workspace_diagnostics` for every file (`workspace/diagnostic`); zfls then publishes none of them, and `diagnostics_change_delay` does not apply. A report the client already has comes back `unchanged`, computed again only after a change in the workspace; `interFileDependencies` tells the client that a change of a module changes the reports of the files that use it. The compiler's and the linters' diagnostics, which come later from their threads, are still published. After a change of the settings zfls asks the client to pull again (`workspace/diagnostic/refresh`). Turning `workspace_diagnostics` on for such a client takes a restart.
- `diagnostic_severity` (option or configuration file) sets the severity of a code, or hides it: `{"masks-parent": "off", "declared-twice": "warning"}`; the severities are `off`, `error`, `warning`, `information` and `hint`.
- `external_modules` names modules from outside the project (glob patterns, case-insensitive) that `USE` statements may name without a `module-not-found` diagnostic, e.g. `["mpi", "petsc*"]`.
- In the code, a comment `! zfls: disable=masks-parent, declared-twice` hides those codes on its line (`! zfls: disable` hides every code), `! zfls: disable-next-line=...` on the next line and `! zfls: disable-file=...` in the whole file.

These are zfls's own options: fortls does not have them.

## Dialects

zfls's own error checks (the ones fortls does not have, beyond names and arguments) follow a dialect, the Fortran that one compiler accepts. `lint_dialect` (`zfls.linter.dialect` in VS Code) names it: `neutral`, `gfortran`, `ifx` or `flang`. Without it the dialect is that of the compiler of the file's form (`compiler_diagnostics`, or `compiler_diagnostics_fixed` for fixed form; `ifort` is `ifx`'s; or the compiler `compiler_path` names when `compiler_diagnostics` is not set), and neutral when that is none or a compiler with no dialect (`nvfortran`, `nagfor`, `lfortran`). Set it to lint against one compiler and build with another.

- Neutral checks only what gfortran, ifx and Flang all agree on.
- A compiler's dialect also applies that compiler's quirks, ahead of the compiler check: for example `real(kind=3)` is an error in gfortran's dialect and fine in Flang's. A quirk is implemented where its rule is simple; the rest is left to the compiler check on save.
- Each rule has a diagnostic code of its own, so that `diagnostic_severity` or a `! zfls: disable=` comment can switch it off, and the documentation of the rule names the dialects that apply it. A file that the compilers accept gets no new diagnostic in any dialect.

The rules, by the dialects that apply them:

| Code | What it reports | Dialects |
| --- | --- | --- |
| `argument-not-definable` | a constant, expression, named constant or INTENT(IN) argument given for an INTENT(OUT) or INTENT(INOUT) dummy argument | all |
| `argument-too-short` | a whole rank-1 array or a section of literal bounds with fewer elements than an explicit-shape dummy argument | all |
| `argument-storage-short` | an array element with fewer elements left in its array than an explicit-shape dummy argument | gfortran, flang |
| `constant-assigned` | an assignment (`n = 4`, `n(1) = 4`) to a named constant (PARAMETER) | all |
| `case-value-overlap` | a CASE value (integer or one-character literals, ranges included) that overlaps an earlier value of the same SELECT CASE construct | all |
| `label-defined-twice` | a statement label defined twice in a scoping unit | all |
| `label-not-found` | a label that a GO TO, DO, FORMAT reference or I/O specifier (`err=`, `end=`, `eor=`) names and the scoping unit does not define; not checked in a file with an INCLUDE or lines a preprocessor conditional leaves out | all |
| `exit-outside-loop` | an EXIT with no construct name outside a DO construct (in a block or IF construct too); not checked in a file with an INCLUDE, `;` or lines a preprocessor conditional leaves out | all |
| `cycle-outside-loop` | a CYCLE with no construct name outside a DO construct, checked as `exit-outside-loop` | all |
| `intent-not-in-arguments` | a variable with INTENT that is not in the argument list; Flang accepts it, so neither it nor the neutral dialect reports it | gfortran, ifx |
| `parameter-without-value` | a named constant declared with no value (`integer, parameter :: n`) | all |
| `duplicate-dummy` | a dummy argument named twice in a SUBROUTINE or FUNCTION statement | all |
| `bad-kind` | a literal kind that no compiler of the dialect has (`integer(kind=3)`; `real(kind=3)` is gfortran's and ifx's error, Flang has it): neutral rejects what none of gfortran, ifx and Flang accepts | all, each by its compiler's kinds |
| `subscript-count` | an array reference with other subscripts than the rank its declaration gives (`a(1, 2)` for a rank-1 array); not for associate names, assumed-rank or arrays whose rank is not declared | all |
| `unknown-component` | `v%b` where the type of `v` is found whole (its extended types too; none with type parameters or an INCLUDE not read) and has no component or binding `b` | all |
| `allocate-object` | an ALLOCATE or DEALLOCATE of a variable that is neither ALLOCATABLE nor a POINTER (plain names only) | all |
| `allocate-duplicate` | the same object twice in one ALLOCATE or DEALLOCATE statement (plain names, subscripts aside); Flang accepts it | gfortran, ifx |
| `allocate-shape` | an ALLOCATE of an array with no shape (and no SOURCE or MOLD), or with a shape of another rank | all |
| `assignment-type` | an assignment of a value of a type that cannot be converted: a numeric or logical literal to a character variable (all dialects), a character literal to a numeric or logical variable (gfortran, flang; ifx accepts it); the same for variables and expressions of known types, `i = c` and `c = i + 1` (all dialects); and the operands of the expression: a CHARACTER one mixed with a numeric or logical one in arithmetic or a comparison (a character literal there is ifx's to accept), `//` of anything but CHARACTER; operands of unknown type, signs, `.not.` and expressions with a function call are not told; not where the workspace has an `assignment(=)` or an `operator` interface | all, see the description |
| `condition-type` | `if (i)` for a numeric or character variable (not the arithmetic IF) | gfortran, flang |
| `intrinsic-arguments` | a call of an intrinsic function (the ones of the M_intrinsics pages that gfortran accepts the same counts for, about 160) with too few or too many arguments, or with a keyword the intrinsic has not (where it is certain), where nothing of the workspace has that name | all |
| `unbalanced-parentheses` | a statement whose parentheses do not match, outside FORMAT and DATA statements and statements with a preprocessor line inside or cut by a blank line or comment after `&` | all |
| `dangling-operator` | an assignment to a declared variable whose expression ends in an operator (`a = b +`) | all |
| `abstract-type-declared` | a `type(t)` declaration of an ABSTRACT type (`class(t)` is fine) | all |
| `extends-unknown-type` | `extends(t)` of a type that nothing defines, where no module of another project or include could bring it in | all |
| `pure-function-argument` | a dummy argument of a PURE function with no INTENT(IN) or VALUE (all dialects), or with INTENT(OUT) or INTENT(INOUT) (Flang accepts them) | all, and gfortran and ifx for INTENT(OUT) and INTENT(INOUT) |
| `unknown-io-specifier` | a specifier of a READ or WRITE that no I/O statement of any compiler has | all |
