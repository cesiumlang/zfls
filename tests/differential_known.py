"""The known differences between zfls's answers and Python fortls's, for
tests/differential.py: what each server gets wrong or answers otherwise by
design (README, "Differences from fortls"), recognized so that the
comparison leaves them out, and the normalization of both answers before
it.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from urllib.parse import unquote

REPO = Path(__file__).resolve().parent.parent

# Typos fixed in zfls's copy of the fortls data files
# cSpell:disable-next-line
TEXT_FIXES = [("RSHIFT(I,SHIFT) eturns", "RSHIFT(I,SHIFT) returns")]
ISO_C_EXTRA = re.compile(r"(?i)c_(float16(_complex)?|uint(\d+|_least\d+|_fast\d+|max)_t|unsigned(_char|_short|_long|_long_long)?)$")
PARAM_VALUE = re.compile(r"(PARAMETER[^\n:]*:: \w+ = [^\n(\[]*)[(\[][^\n]*")
INTRINSIC_DOC = re.compile(
    r"(?:(?:```\w*\n.*?\n```)?\n-----\n)?## `?(\w+)`?\n\n### \*\*Name\*\*",
    re.S,
)


# The intrinsic procedures of zfls's table that fortls's lacks (the
# specific names, `DSQRT`, and newer generics, `REDUCE`): set by main
ZFLS_ONLY_INTRINSICS: set = set()


def zfls_only_intrinsics(fortls_root: Path) -> set:
    table = REPO / "src" / "data" / "procedures.zig"
    ours = set(re.findall(r'\.name = "([^"]+)"', table.read_text("utf-8")))
    internal = fortls_root / "fortls" / "parsers" / "internal"
    theirs_text = (internal / "intrinsic.procedures.json").read_text("utf-8")
    return ours - set(json.loads(theirs_text))


def on_zfls_only_intrinsic(lines: list, line: int, char: int) -> bool:
    """Whether the position is on the name of an intrinsic that only zfls
    knows (`ZFLS_ONLY_INTRINSICS`), which zfls answers on and fortls does
    not."""
    if not (0 <= line < len(lines)):
        return False
    for m in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", lines[line]):
        if m.start() <= char <= m.end():
            return m.group(0).upper() in ZFLS_ONLY_INTRINSICS
    return False


def in_constructor_or_group(lines: list, line: int, char: int) -> bool:
    """Whether the innermost bracket open before the position is an array
    constructor (`[`, `(/`) or a parenthesis that follows no name (an
    implied DO, an expression in parentheses), where zfls's signature help
    looks for the call outside it (hansec #60) and fortls answers null."""
    if not (0 <= line < len(lines)):
        return False
    text = lines[line][:char]
    depth = 0
    for i in range(len(text) - 1, -1, -1):
        c = text[i]
        if c in ")]":
            depth += 1
        elif c in "([":
            if depth > 0:
                depth -= 1
                continue
            if c == "[" or text[i + 1 :].lstrip().startswith("/"):
                return True
            before = text[:i].rstrip()
            return not before or not (before[-1].isalnum() or before[-1] in "_)]>")
    return False


def zfls_only_item(item) -> bool:
    """A zfls completion item of its own: `name=` for a keyword argument
    (hansec #133), a name of a module not used yet that adds the USE
    statement (hansec #62), or an intrinsic that fortls does not know."""
    if not isinstance(item, dict):
        return False
    # (not a variable of the same name: `int1`, Intel's INT1)
    if str(item.get("label", "")).upper() in ZFLS_ONLY_INTRINSICS and item.get("kind") != 6:
        return True
    # the F2023 names of ISO_C_BINDING (#730) and the unsigned and half
    # precision ones of Flang's (#881)
    if str(item.get("label", "")).lower() in ("c_f_strpointer", "f_c_string") or ISO_C_EXTRA.match(str(item.get("label", ""))):
        return True
    # the parent components of an extended type (hansec #121)
    if "labelDetails" in item:
        return True
    if "additionalTextEdits" in item:
        return True
    # a construct or program unit at the start of a statement (#264)
    if "textEdit" in item:
        return True
    return str(item.get("label", "")).endswith("=") and "filterText" in item


def two_forms_item(item) -> bool:
    """A completion item of an intrinsic whose table entry has two
    argument lists (`THIS_IMAGE`)."""
    return isinstance(item, dict) and str(item.get("label", "")).upper() in ("THIS_IMAGE", "TOKENIZE")


def normalize(v):
    """Drop details that legitimately differ between the servers."""
    if isinstance(v, dict):
        # zfls gives each diagnostic a code and source (fortls has neither)
        diagnostic = {"range", "message", "severity"} <= v.keys()
        # and names the unit an IMPORT may not be in (#724)
        if diagnostic and v.get("code") == "import-outside-interface":
            v = {**v, "message": "IMPORT statement outside of interface"}
        return {
            k: normalize(x) for k, x in v.items()
            if k != "traceback" and not (diagnostic and k in ("code", "source"))
        }
    if isinstance(v, list):
        # names not declared under IMPLICIT NONE (hansec #129): zfls only
        # and unused names: zfls only; so are mismatched ENDs and scopes
        # left open (#285), and the diagnostic on an #include whose file is
        # not found (#282)
        return [normalize(x) for x in v if not (isinstance(x, dict) and x.get("code") in ("undeclared-name", "unused-name", "circular-use", "argument-mismatch", "argument-kind", "intent-in-assigned", "mismatched-end", "unclosed-scope", "include-not-found", "unbalanced-parentheses"))]
    if isinstance(v, str):
        for old, new in TEXT_FIXES:
            v = v.replace(old, new)
        # fortls cuts the value of a parameter at its first parenthesis or
        # bracket; zfls shows it whole (upstream issue 124)
        v = PARAM_VALUE.sub(r"\1", v)
        # zfls has the LOWER argument of C_F_POINTER (F2018, #730)
        v = v.replace("${3:shape}, ${4:lower})", "${3:shape})")
        v = v.replace("c_f_pointer(cptr, fptr, shape, lower)", "c_f_pointer(cptr, fptr, shape)")
        # zfls ships a newer M_intrinsics than fortls, its links rewritten
        m = INTRINSIC_DOC.match(v)
        if m:
            return f"<intrinsic manual page {m.group(1)}>"
    return v


INCLUDE_DIRECTIVE = re.compile(r"\s*#\s*include\s*[\"<]", re.I)
USE_LINE = re.compile(r"\s*use\b", re.I)


def on_use_rename_original(lines: list, line: int, char: int) -> bool:
    """Whether (line, char) is on the original name of a rename on a USE
    statement, `use m, local => ORIGINAL`."""
    if not 0 <= line < len(lines) or not USE_LINE.match(lines[line]):
        return False
    text = lines[line]
    start = char
    while start > 0 and (text[start - 1].isalnum() or text[start - 1] == "_"):
        start -= 1
    return text[:start].rstrip().endswith("=>")


def use_rename_extras(lines: list, a, b) -> bool:
    """Whether references `b` are `a` plus locations on the original names
    of USE renames only."""
    if not isinstance(a, list) or not isinstance(b, list) or len(b) <= len(a):
        return False
    rest = list(b)
    for loc in a:
        if loc not in rest:
            return False
        rest.remove(loc)
    for loc in rest:
        start = loc.get("range", {}).get("start", {})
        if not on_use_rename_original(lines, start.get("line", -1), start.get("character", 0)):
            return False
    return True


def on_include_directive(path: Path, position) -> bool:
    """Whether the position is on a preprocessor `#include` line of the file."""
    if not position:
        return False
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    line = position.get("line", -1)
    return 0 <= line < len(lines) and bool(INCLUDE_DIRECTIVE.match(lines[line]))


PP_DEFINE = re.compile(r"^\s*#\s*define\s+(\w+)")
WORD = re.compile(r"[A-Za-z_]\w*")


def macro_names(path: Path, source: str) -> set:
    """The names a preprocessed file (upper-case suffix) `#define`s."""
    if path.suffix == path.suffix.lower():
        return set()
    return {m.group(1) for line in source.splitlines() if (m := PP_DEFINE.match(line))}


def on_macro(lines: list, macros: set, line: int, char: int) -> bool:
    """Whether the position is on the name of a macro of the file: zfls goes
    to its `#define` and lists its uses and directives (#265); fortls answers
    the use itself, and nothing on a directive's line."""
    if not macros or not 0 <= line < len(lines):
        return False
    for m in WORD.finditer(lines[line]):
        if m.start() <= char <= m.end():
            return m.group(0) in macros
    return False


INCLUDE_LINE = re.compile(r"\s*(?:#\s*include|include)\s*[\"'<]", re.I)


def on_include_line(path: Path, position) -> bool:
    """Whether the position is on an `#include` or INCLUDE line of the file."""
    if not position:
        return False
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    line = position.get("line", -1)
    return 0 <= line < len(lines) and bool(INCLUDE_LINE.match(lines[line]))


ASSOC_BOUND = re.compile(r"\b(\w+)\s*=>\s*\w+\s*\(", re.I)


def associate_names(source: str) -> set:
    """Lowercase names bound by `name => array(...)` (ASSOCIATE or pointer
    assignment) in a source file."""
    return {m.group(1).lower() for m in ASSOC_BOUND.finditer(source)}


PP_IF = re.compile(r"\s*#\s*if", re.I)
PP_ENDIF = re.compile(r"\s*#\s*endif", re.I)
CONT_ATTRIBUTE = re.compile(r"\s*,\s*(\w+)", re.I)


ENTITY_LENGTH = re.compile(
    r"^\s*(?:character|real|integer|logical|complex)\b.*?[a-z_]\w*\s*"
    r"(?:\((?:[^()]|\([^()]*\))*\))?\s*\*\s*[\d(]",
    re.I | re.M,
)
TYPE_PARAMS = re.compile(
    r"\b(CHARACTER|REAL|INTEGER|LOGICAL|COMPLEX)"
    r"(?:\s*\*\s*(?:\d+|\((?:[^()]|\([^()]*\))*\))|\((?:[^()]|\([^()]*\))*\))+",
    re.I,
)
SEMICOLON_STRINGS = re.compile(r"^[^!\n]*(?:;[^!\n]*['\"]|['\"][^!\n]*;)", re.M)
PARAM_STRINGS = re.compile(r"(PARAMETER[^\n:]*:: \w+ = )([^\n]*)")
STRING_LITERAL = re.compile(r"\"[^\"\n]*\"|'[^'\n]*'")


def ignore_type_params(v):
    """An entity's own length replaces that of its declaration in zfls
    (`character*10 b*(len(a))` has the length len(a), #237); fortls puts
    both. Compare types without their kind and length."""
    if isinstance(v, dict):
        return {k: ignore_type_params(x) for k, x in v.items()}
    if isinstance(v, list):
        return [ignore_type_params(x) for x in v]
    if isinstance(v, str):
        return TYPE_PARAMS.sub(r"\1", v)
    return v


def ignore_param_strings(v):
    """fortls shows the strings of a parameter declared on a line with `;`
    blanked, zfls as they are (#237). Compare such values without the text
    of their strings and without blanks. (A string continued by a doubled
    quote, `"a;""b"`, is one literal in zfls and two in fortls, which pairs
    the `"` from the left (#231): both read as two literals here.)"""
    if isinstance(v, dict):
        return {k: ignore_param_strings(x) for k, x in v.items()}
    if isinstance(v, list):
        return [ignore_param_strings(x) for x in v]
    if isinstance(v, str):
        return PARAM_STRINGS.sub(
            lambda m: m.group(1) + STRING_LITERAL.sub('""', m.group(2)).replace(" ", ""), v
        )
    return v


def conditional_attributes(source: str) -> set:
    """Uppercase attributes given on a continuation line inside a
    preprocessor conditional, as in `REAL &` / `#ifdef X` / `, POINTER &`."""
    depth = 0
    out = set()
    for line in source.splitlines():
        if PP_IF.match(line):
            depth += 1
        elif PP_ENDIF.match(line):
            depth = max(depth - 1, 0)
        elif depth:
            m = CONT_ATTRIBUTE.match(line)
            if m:
                out.add(m.group(1).upper())
    return out


def ignore_conditional_attributes(v, attrs: set):
    """fortls joins the lines of inactive conditional branches into a
    continued declaration; zfls leaves them out (hansec issue 203). Compare
    declarations without the attributes such branches can add."""
    if isinstance(v, dict):
        return {k: ignore_conditional_attributes(x, attrs) for k, x in v.items()}
    if isinstance(v, list):
        return [ignore_conditional_attributes(x, attrs) for x in v]
    if isinstance(v, str) and attrs:
        alt = "|".join(sorted(attrs))
        return re.sub(rf", (?:{alt})(?=[,\s])", "", v, flags=re.I)
    return v


def ignore_slice_dimensions(v, names: set):
    """fortls gives an ASSOCIATE name bound to an element or a section the
    dimensions of the whole array; zfls gives it those of the section
    (upstream issue 108). Compare the dimensions of such names as equal."""
    if isinstance(v, dict):
        return {k: ignore_slice_dimensions(x, names) for k, x in v.items()}
    if isinstance(v, list):
        return [ignore_slice_dimensions(x, names) for x in v]
    if isinstance(v, str) and names:
        def repl(m):
            return m.group(0) if m.group(3).lower() not in names else m.group(2) + m.group(3)

        return re.sub(r"(, )?DIMENSION\([^)\n]*\)( :: )(\w+)", repl, v)
    return v


ASSOC_STMT = re.compile(r"^\s*(?:\w+\s*:\s*)?associate\s*\((.*)$", re.I | re.M)
ASSOC_NAME = re.compile(r"(\w+)\s*=>")


def associate_bound(source: str) -> set:
    """Lowercase names that ASSOCIATE statements of a source file bind."""
    out = set()
    for m in ASSOC_STMT.finditer(source):
        out |= {n.lower() for n in ASSOC_NAME.findall(m.group(1))}
    return out


SELECT_STMT = re.compile(r"^\s*(?:\w+\s*:\s*)?select\s*(?:type|rank)\s*\(\s*(\w+)\s*=>", re.I | re.M)
NOT_INHERITED = re.compile(r", (?:INTENT\([^)\n]*\)|ALLOCATABLE|POINTER|OPTIONAL|SAVE|VALUE|PROTECTED|TARGET)(?=,|$)", re.I)


def select_bound(source: str) -> set:
    """Lowercase names that SELECT TYPE and SELECT RANK statements of a
    source file bind."""
    return {m.group(1).lower() for m in SELECT_STMT.finditer(source)}


def ignore_associate_attributes(v, names: set):
    """fortls gives an associate name all the attributes of its selector;
    zfls only those the standard gives it (TARGET for a POINTER, not
    INTENT nor ALLOCATABLE; #691). Compare such names' declarations without
    them."""
    if isinstance(v, dict):
        return {k: ignore_associate_attributes(x, names) for k, x in v.items()}
    if isinstance(v, list):
        return [ignore_associate_attributes(x, names) for x in v]
    if isinstance(v, str) and names:
        def repl(m):
            return NOT_INHERITED.sub("", m.group(1)) + m.group(2) + m.group(3) if m.group(3).lower() in names else m.group(0)

        return re.sub(r"^([^\n]*?)( :: )(\w+)$", repl, v, flags=re.M)
    return v


def ignore_associate_functions(v, names: set):
    """fortls shows an associate name bound to a function's result as that
    function (`LOGICAL FUNCTION :: hi`, completed as `hi()`); zfls as the
    variable it is, of the result's type (#721)."""
    if isinstance(v, dict):
        label = str(v.get("label", "")).lower()
        out = {k: ignore_associate_functions(x, names) for k, x in v.items()}
        text = str(out.get("insertText", ""))
        if label in names and text.lower().startswith(label + "("):
            del out["insertText"]
            out.pop("insertTextFormat", None)
            if out.get("kind") == 3:
                out["kind"] = 6
            detail = str(out.get("detail", ""))
            if detail.lower().endswith(" function " + label + "()"):
                out["detail"] = detail[: -len(" function " + label + "()")]
        return out
    if isinstance(v, list):
        return [ignore_associate_functions(x, names) for x in v]
    if isinstance(v, str) and names:
        def repl(m):
            return m.group(1) + m.group(2) if m.group(2)[4:].lower() in names else m.group(0)

        return re.sub(r"^([^\n]*?) FUNCTION( :: \w+)$", repl, v, flags=re.M)
    return v


def untyped_by_fortls(v, names: set) -> set:
    """The names of `names` that fortls's answer `v` gives the type UNKNOWN
    (in a hover, or as the detail of a completion item)."""
    found = set()

    def walk(x):
        if isinstance(x, dict):
            label = x.get("label")
            if isinstance(label, str) and label.lower() in names and x.get("detail") == "UNKNOWN":
                found.add(label.lower())
            for y in x.values():
                walk(y)
        elif isinstance(x, list):
            for y in x:
                walk(y)
        elif isinstance(x, str):
            for m in re.finditer(r"UNKNOWN :: (\w+)", x):
                if m.group(1).lower() in names:
                    found.add(m.group(1).lower())

    walk(v)
    return found


def forget_associate_types(v, names: set):
    """fortls gives an ASSOCIATE name bound to a literal or an expression, or
    spelled like the variable of its selector, the type UNKNOWN; zfls the
    type of the selector (#230). Compare the types of such names as equal."""
    if isinstance(v, dict):
        label = v.get("label")
        out = {k: forget_associate_types(x, names) for k, x in v.items()}
        if isinstance(label, str) and label.lower() in names and "detail" in v:
            out["detail"] = "UNKNOWN"
        return out
    if isinstance(v, list):
        return [forget_associate_types(x, names) for x in v]
    if isinstance(v, str) and names:
        def repl(m):
            return f"UNKNOWN :: {m.group(1)}" if m.group(1).lower() in names else m.group(0)

        return re.sub(r"^[^\n]*? :: (\w+)$", repl, v, flags=re.M)
    return v


def is_error(v) -> bool:
    return isinstance(v, dict) and "__error__" in v


def notifications(res: dict, method: str) -> list:
    return [n["params"] for n in res["notifications"] if n["method"] == method]


CONSTRUCT_KEYWORDS = r"(do|if|select|block|associate|where|forall|critical|change)\b"


INTERFACE_LINE = re.compile(r"\s*interface\s+(\w+)", re.I)
PROCEDURE_LINE = re.compile(r".*\b(?:subroutine|function)\s+(\w+)", re.I)


def generic_specific_definition(lines: list, ref, got) -> bool:
    """Whether fortls's definition is a generic interface of the file and
    zfls's a procedure that the interface lists: on a call of a generic
    interface zfls goes to the procedure the arguments fit (hansec #135)."""
    if not (isinstance(ref, dict) and isinstance(got, dict)) or ref.get("uri") != got.get("uri"):
        return False
    a = ref.get("range", {}).get("start", {}).get("line", -1)
    b = got.get("range", {}).get("start", {}).get("line", -1)
    if not (0 <= a < len(lines) and 0 <= b < len(lines)):
        return False
    iface = INTERFACE_LINE.match(lines[a])
    proc = PROCEDURE_LINE.match(lines[b])
    if not (iface and proc):
        return False
    name = proc.group(1).lower()
    for line in lines[a + 1:]:
        if re.match(r"\s*end\s*interface", line, re.I):
            return False
        if name in re.findall(r"\w+", line.lower()):
            return True
    return False


LITERAL_HOVER = re.compile(r"```\w*\n(REAL|INTEGER|LOGICAL|CHARACTER\(LEN=\d+\))\n```")
INTRINSIC_DOT_OPS = {"eq", "ne", "lt", "le", "gt", "ge", "and", "or", "not", "eqv", "neqv", "true", "false"}


def on_user_operator(lines: list, line: int, char: int) -> bool:
    """Whether the position is on a user-defined operator `.name.` (hansec
    #95), which zfls answers on and fortls does not."""
    if not (0 <= line < len(lines)):
        return False
    for m in re.finditer(r"\.([A-Za-z]+)\.", lines[line]):
        if m.start() <= char <= m.end() and m.group(1).lower() not in INTRINSIC_DOT_OPS:
            return True
    return False


def on_assignment(lines: list, line: int, char: int) -> bool:
    """Whether the position is on the `=` of an assignment or on
    `assignment(=)`, where zfls answers for a defined assignment (hansec
    #95) and fortls does not."""
    if not (0 <= line < len(lines)):
        return False
    text = lines[line]
    if any(0 <= c < len(text) and text[c] == "=" for c in (char, char - 1)):
        return True
    for m in re.finditer(r"(?i)assignment\s*\(\s*=\s*\)", text):
        if m.start() <= char <= m.end():
            return True
    return False


def on_enumerator_statement(lines: list, line: int) -> bool:
    """Whether the line is an ENUMERATOR statement, whose names zfls reads
    (named constants of the scope around the ENUM) and fortls does not."""
    if not (0 <= line < len(lines)):
        return False
    return re.match(r"\s*enumerator\b", lines[line], re.I) is not None


def on_parenthesized_kind(lines: list, line: int) -> bool:
    """Whether the line declares with a kind in parentheses, `INTEGER((4))
    x` (#690), whose names fortls does not read (its FIXME)."""
    if not (0 <= line < len(lines)):
        return False
    pattern = r"\s*(integer|real|complex|logical|character)\s*\(\s*\("
    return re.match(pattern, lines[line], re.I) is not None


def on_import_statement(lines: list, line: int) -> bool:
    """Whether the line is an IMPORT statement, where zfls completes every
    name the host sees (#486) and fortls only those the interface body's
    IMPORT statements name already."""
    if not (0 <= line < len(lines)):
        return False
    return re.match(r"\s*import\b", lines[line], re.I) is not None


def items_within(a, b) -> bool:
    """Whether completion items `a` are all among `b`."""
    if not isinstance(a, list) or not isinstance(b, list):
        return False
    keys = {json.dumps(x, sort_keys=True) for x in b}
    return all(json.dumps(x, sort_keys=True) in keys for x in a)


NON_CODE = re.compile(r"\s*(?:[#!].*)?$")


KEYWORD_WORDS = {"integer", "real", "complex", "logical", "character", "byte", "double", "precision"}
DOT_OPERATORS = {"and", "or", "not", "eqv", "neqv", "xor", "eq", "ne", "lt", "le", "gt", "ge"}


def on_keyword_or_operator(lines: list, line: int, char: int) -> bool:
    """Whether (line, char) is on a type keyword (`real :: x`, `double
    precision`) or an operator (`.or.`): fortls shows the manual page of the
    intrinsic function of that name, zfls shows none (zfls #845)."""
    if not 0 <= line < len(lines):
        return False
    text = lines[line]
    s = e = min(char, len(text))
    while s > 0 and (text[s - 1].isalnum() or text[s - 1] == "_"):
        s -= 1
    while e < len(text) and (text[e].isalnum() or text[e] == "_"):
        e += 1
    word = text[s:e].lower()
    if word in KEYWORD_WORDS:
        return True
    return word in DOT_OPERATORS and s > 0 and text[s - 1] == "." and e < len(text) and text[e] == "."


def adjacent_references(a, b, lines: list) -> bool:
    """Whether references `b` are those of `a` and more, the more being
    names one character after a name (`i*i`, `a(i,i)`, `%n=n`): fortls
    consumes the delimiter after each name, so it misses a name right behind
    it (zfls #844)."""
    if not isinstance(a, list) or not isinstance(b, list) or len(a) >= len(b):
        return False

    def key(x):
        r = x.get("range", {}).get("start", {})
        return (x.get("uri"), r.get("line"), r.get("character"))

    have = {key(x) for x in a}
    if not have <= {key(x) for x in b}:
        return False
    for x in b:
        k = key(x)
        if k in have:
            continue
        ln, ch = k[1], k[2]
        if ln is None or not 0 <= ln < len(lines) or ch is None or ch < 2:
            return False
        text = lines[ln]
        if ch > len(text) or text[ch - 1].isalnum() or text[ch - 1] == "_":
            return False
        if not (text[ch - 2].isalnum() or text[ch - 2] == "_"):
            return False
    return True


def in_string_with_bang(lines: list, line: int, char: int) -> bool:
    """Whether a string literal before (line, char) holds a `!`: fortls
    reads that `!` as a comment and offers nothing (null), zfls knows it is
    a string (zfls #842) and offers an empty list."""
    if not 0 <= line < len(lines):
        return False
    quote = None
    bang = False
    for c in lines[line][:char]:
        if quote:
            if c == quote:
                quote = None
            elif c == "!":
                bang = True
        elif c in "'\"":
            quote = c
        elif c == "!":
            return False
    return bang


def after_non_code_line(lines: list, line: int) -> bool:
    """Whether the line continues a statement across a preprocessor
    directive, comment or blank line before it (`REAL &` / `#ifdef X` /
    `, POINTER &`): zfls reads the statement whole (zfls #259), fortls
    stops at that line."""
    if not 0 < line < len(lines) or not NON_CODE.match(lines[line - 1]):
        return False
    k = line - 1
    while k >= 0 and NON_CODE.match(lines[k]):
        k -= 1
    return k >= 0 and lines[k].split("!")[0].rstrip().endswith("&")


def on_construct_name_or_label(lines: list, line: int, char: int) -> bool:
    """Whether (line, char) is on a statement label or on a construct name
    that the file defines (`name: do`); zfls answers definition, references
    and rename there (fortls #424), fortls has no answer."""
    if not 0 <= line < len(lines):
        return False
    text = lines[line]
    for m in re.finditer(r"[A-Za-z_]\w*|\d+", text):
        if m.start() <= char <= m.end():
            token = m.group(0)
            break
    else:
        return False
    if token.isdigit():
        return True
    name = re.compile(
        r"^\s*(\d+\s+)?" + re.escape(token) + r"\s*:(?!:)\s*" + CONSTRUCT_KEYWORDS, re.I
    )
    return any(name.match(l) for l in lines)


DECLARATION_LINE = re.compile(
    r"\s*(?:\d+\s+)?(?:integer|real|double|complex|logical|character|type|class|dimension|parameter|common|data|"
    r"external|intrinsic|pointer|allocatable|target|save|intent|optional|public|private|equivalence|namelist|use|"
    r"procedure|contains|interface|enum|implicit)\b",
    re.I,
)


def on_implicit_variable(lines: list, line: int, char: int) -> bool:
    """Whether (line, char) is on a name that no declaration of the file
    mentions (an implicitly typed variable or an undeclared dummy
    argument); zfls answers definition, references and rename there (the
    first use is the definition, #849), fortls has no answer."""
    if not 0 <= line < len(lines):
        return False
    for m in re.finditer(r"[A-Za-z_]\w*", lines[line]):
        if m.start() <= char <= m.end():
            token = m.group(0)
            break
    else:
        return False
    word = re.compile(r"\b" + re.escape(token) + r"\b", re.I)
    return not any(DECLARATION_LINE.match(l) and word.search(l) for l in lines)


def own_file_definition(ref, got, own: str) -> bool:
    """Whether zfls found the definition in the requesting file (path
    suffix `own`) where fortls found one in another file."""
    if not (isinstance(ref, dict) and isinstance(got, dict)):
        return False
    ref_uri = unquote(ref.get("uri", ""))
    got_uri = unquote(got.get("uri", ""))
    return got_uri.endswith(own) and not ref_uri.endswith(own)


def first_difference(a, b, path="$"):
    """Return (json path, a value, b value) of the first difference."""
    if type(a) is not type(b):
        return path, a, b
    if isinstance(a, dict):
        for k in list(a) + [k for k in b if k not in a]:
            if k not in a or k not in b:
                missing = "<absent>"
                return f"{path}.{k}", a.get(k, missing), b.get(k, missing)
            d = first_difference(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_difference(x, y, f"{path}[{i}]")
            if d:
                return d
        if len(a) != len(b):
            return f"{path}.length", len(a), len(b)
        return None
    return None if a == b else (path, a, b)


def ref_key(r: dict):
    start = r["range"]["start"]
    return (r["uri"], start["line"], start["character"])


PROCEDURE_STMT = re.compile(r"\b(?:subroutine|function|procedure)\b", re.I)


def uri_line(uri: str, line: int, whole: bool = False):
    """Line `line` of the file of `uri`, or with `whole` all its lines"""
    path = unquote(uri.removeprefix("file://"))
    if os.name == "nt":
        path = path.lstrip("/")
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return [] if whole else ""
    if whole:
        return lines
    return lines[line] if 0 <= line < len(lines) else ""


def separate_procedure_refs(a, b) -> bool:
    """zfls's references to a separate module procedure also list its
    interface and its implementation in a submodule (hansec issue 168):
    whether `b` is `a` plus locations on SUBROUTINE, FUNCTION or PROCEDURE
    statements only."""
    if not (isinstance(a, list) and isinstance(b, list)):
        return False
    ka = {ref_key(r) for r in a}
    kb = {ref_key(r) for r in b}
    if not ka < kb:
        return False
    return all(PROCEDURE_STMT.search(uri_line(u, ln)) for u, ln, _ in kb - ka)


def implicit_result_refs(a, b) -> bool:
    """zfls's references to a function without RESULT and to its result
    variable are those of both (zfls #228); fortls lists one or the other:
    whether `b` is `a` plus places of a name that a FUNCTION statement
    without RESULT among the places defines."""
    if not (isinstance(a, list) and isinstance(b, list)) or not a:
        return False
    ka = {ref_key(r) for r in a}
    kb = {ref_key(r) for r in b}
    if not ka < kb:
        return False
    texts = {u: uri_line(u, -1, whole=True) for u, _, _ in kb}
    for u, ln, ch in kb - ka:
        m = re.match(r"\w+", uri_line(u, ln)[ch:])
        if not m:
            return False
        fun = re.compile(rf"\bfunction\s+{re.escape(m.group(0))}\s*\(", re.I)
        if not any(fun.search(t) and "result" not in t.lower() for text in texts.values() for t in text):
            return False
    return True


USE_RENAME = re.compile(r"^\s*use\b.*=>", re.I)


def use_alias_refs(a, b) -> bool:
    """zfls's references to an entity that USE statements rename also list
    its places under the local names (zfls #233); fortls lists those of
    one name only: whether `b` is `a` plus places of names that a USE
    rename (`local => name`) among the places' files has on either side.
    fortls may have none: for an intrinsic module's entity, say."""
    if a is None:
        a = []
    if not (isinstance(a, list) and isinstance(b, list)):
        return False
    ka = {ref_key(r) for r in a}
    kb = {ref_key(r) for r in b}
    if not ka < kb:
        return False
    renames = set()
    for u in {u for u, _, _ in kb}:
        path = unquote(u.removeprefix("file://"))
        if os.name == "nt":
            path = path.lstrip("/")
        try:
            text = Path(path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for t in text.splitlines():
            if USE_RENAME.match(t):
                for m in re.finditer(r"(\w+)\s*=>\s*(\w+)", t):
                    renames.update(x.lower() for x in m.groups())
    for u, ln, ch in kb - ka:
        m = re.match(r"\w+", uri_line(u, ln)[ch:])
        if not m or m.group(0).lower() not in renames:
            return False
    return True


