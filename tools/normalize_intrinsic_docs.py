"""Normalize the intrinsic procedure docs so they pass markdownlint.

The files in src/data/intrinsics come from the M_intrinsics project. After
copying new versions, run ``markdownlint-cli2 --fix`` on them and then this
script, which handles what the automatic fixes cannot:

* links to other manual pages (``[**sign**(3)](#sign)``) become plain text,
  since the pages are shown one at a time in hover popups;
* indented code blocks become fenced ``text`` blocks;
* fences without a language get ``text``;
* repeated level-2 headings (duplicated page titles) are dropped.

Usage:
    python tools/normalize_intrinsic_docs.py [DIR]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_DIR = Path(__file__).resolve().parent.parent / "src/data/intrinsics"
FRAGMENT_LINK = re.compile(r"\[([^\]]*)\]\(#[^)]*\)")
FENCE = re.compile(r"^(\s*)(```+|~~~+)(.*)$")
LIST_ITEM = re.compile(r"^\s*([-*+]|\d+[.)])\s")


def fix_links(text: str) -> str:
    return FRAGMENT_LINK.sub(r"\1", text)


def fix_fences_and_indented(lines: list[str]) -> list[str]:
    out: list[str] = []
    in_fence = False
    fence_marker = ""
    in_list = False
    i = 0
    while i < len(lines):
        line = lines[i]
        m = FENCE.match(line)
        if m:
            if not in_fence:
                in_fence = True
                fence_marker = m.group(2)
                if not m.group(3).strip():
                    line = f"{m.group(1)}{m.group(2)}text"
            elif m.group(2).startswith(fence_marker):
                in_fence = False
            out.append(line)
            i += 1
            continue
        if in_fence:
            out.append(line)
            i += 1
            continue
        if LIST_ITEM.match(line):
            in_list = True
        elif line.strip() and not line.startswith(" "):
            in_list = False
        prev_blank = not out or not out[-1].strip()
        if (
            line.startswith("    ")
            and line.strip()
            and prev_blank
            and not in_list
        ):
            block: list[str] = []
            while i < len(lines) and (
                lines[i].startswith("    ") or not lines[i].strip()
            ):
                block.append(lines[i])
                i += 1
            while block and not block[-1].strip():
                block.pop()
                i -= 1
            out.append("```text")
            out.extend(b[4:] for b in block)
            out.append("```")
            continue
        out.append(line)
        i += 1
    return out


def drop_duplicate_titles(lines: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    skip_blank = False
    for line in lines:
        if line.startswith("## "):
            if line in seen:
                skip_blank = True
                continue
            seen.add(line)
        if skip_blank and not line.strip():
            skip_blank = False
            continue
        skip_blank = False
        out.append(line)
    return out


BOLD = re.compile(r"\*\*(.+?)\*\*")
LOGICAL_LITERAL = re.compile(r"_(\.(?:true|false)\.)_", re.I)
MD_ESCAPE = re.compile(r"\\([\\`*_{}\[\]()#+\-.!<>|~])")
# Bold spans that are prose labels rather than code
PROSE_BOLD = re.compile(
    r"^(Case \(\w+\):|Elemental:|Nonelemental:|Fortran \d+|, then )$"
)


def code_span(text: str) -> str:
    """Inline code for `text`, removing Markdown escapes (code spans do not
    process them)."""
    raw = MD_ESCAPE.sub(r"\1", text)
    if "`" in raw:
        return f"`` {raw} ``"
    return f"`{raw}`"


def bold_to_code(lines: list[str]) -> list[str]:
    """M_intrinsics marks code (arguments, calls, expressions) in bold; use
    code spans so prose checkers and readers see code as code."""
    out = []
    in_fence = False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence or line.lstrip().startswith("#"):
            out.append(line)
            continue

        def repl(m):
            inner = m.group(1)
            if PROSE_BOLD.match(inner):
                return m.group(0)
            return code_span(inner)

        # leave existing code spans alone ("**" is exponentiation there)
        parts = CODE_SPAN.split(line)
        for i in range(0, len(parts), 2):
            parts[i] = BOLD.sub(repl, parts[i])
            parts[i] = LOGICAL_LITERAL.sub(
                lambda m: f"`{m.group(1)}`", parts[i]
            )
        out.append("".join(parts))
    return out


CODE_SPAN = re.compile(r"(``.+?``|`[^`]*`)")
# Manual page references written as plain text, e.g. "exp(3)"
MAN_REF = re.compile(r"(?<![\w`.%])([a-z_][a-z0-9_]*)\((\d)\)")
VOWEL_ITALIC = re.compile(r"\b([Aa]) (_[aeiouAEIOU])")

# (pattern, replacement) applied to prose (outside code spans and fences)
PROSE_FIXES = [
    (re.compile(r"(?<=\S) {2,}(?=\S)"), " "),
    (re.compile(r"(?<=\S) +([.,;)])(?=\s|$)"), r"\1"),
    (re.compile(r"\( +(?=\S)"), "("),
    (re.compile(r"\bie\.(?=\s|$)"), "i.e."),
    (VOWEL_ITALIC, r"\1n \2"),
    (re.compile(r"\ban (scalar|coarray|default)\b"), r"a \1"),
    (re.compile(r"\bas a RHS\b"), "as an RHS"),
    (re.compile(r"\(non zero\)"), "(nonzero)"),
    (re.compile(r"\bMulti-dimensional\b"), "Multidimensional"),
    (re.compile(r"\bwith regards to\b"), "with regard to"),
    # array shapes in prose, e.g. "has shape [n,m]"
    (re.compile(r"(?<=shape )\[([a-z0-9]+(?:,[a-z0-9]+)*)\]"), r"`[\1]`"),
    (re.compile(r"\bthe same the same\b"), "the same"),
    (re.compile(r"\bmy be\b"), "may be"),
    (re.compile(r"\bwill by\b"), "will be"),
    (re.compile(r"\bhas same\b"), "has the same"),
    (
        re.compile(
            r"(?:(?<=^)|(?<=[.:] ))"
            r"(Otherwise|Hence|Therefore|Conversely|Typically)"
            r"(?=( [^,]| ?$))"
        ),
        r"\1,",
    ),
    (re.compile(r"\(not radians\.(?=\s|$)"), "(not radians)."),
    # not inside URLs (en.wikipedia.org)
    (re.compile(r"(?<![./])\bwikipedia\b(?![./])"), "Wikipedia"),
    (re.compile(r"(?<![\w/-])fortran(?=[ ,.;:)]|$)"), "Fortran"),
]


# Fortran identifiers containing underscores, e.g. iso_fortran_env (not in
# URLs, file names or emphasis markup)
SNAKE_IDENT = re.compile(
    r"(?<![\w`/.(\[#\\-])([a-z][a-z0-9]*(?:_[a-z0-9]+)+)(?![\w`/(\\])"
)
# Fortran dotted operators and logical literals, e.g. .ge. .eqv. .true.
# (italic markers may touch them: "_.ge., .lt._")
DOTTED_OP = re.compile(
    r"(?<![A-Za-z0-9`])"
    r"(\.(?:eq|ne|lt|le|gt|ge|and|or|not|eqv|neqv|true|false)\.)"
    r"(?![A-Za-z0-9`])",
    re.I,
)
# Calls of intrinsic procedures in prose, e.g. "atan(X)" or "BESSEL_JN (N, X)";
# compiled from the documented names by set_intrinsic_names()
intrinsic_call = None
# Targeted text corrections applied to whole lines: (old, new)
TEXT_FIXES = [
    ("_.false_.", "`.false.`"),
    ("range 1 to ei, where ei is", "range 1 to `ei`, where `ei` is"),
    ("c*`size_t` (from the iso\\_c\\_binding* module)",
     "`c_size_t` (from the `iso_c_binding` module)"),
    ("[M_attr module]", "[`M_attr` module]"),
    ("x-y points <x%re,x%im>", "x-y points `<x%re,x%im>`"),
    ("\\<x,y\\>.", "`<x,y>`."),
    ("(s1, s2,..., sDIM-1, sDIM+1,..., sn)",
     "`(s1, s2, ..., sDIM-1, sDIM+1, ..., sn)`"),
    ("erfc_scaled(x)=exp(x*x)erfc(x)",
     "`erfc_scaled(x) = exp(x*x) erfc(x)`"),
    ("using cafrun -np 4 with", "using `cafrun -np 4` with"),
    ("for iostat= specifiers", "for `iostat=` specifiers"),
    ("the function MY\\_MULT,", "the function `MY_MULT`,"),
    ("the size mut be", "the size must be"),
    ("of the form NN-HHHHH", "of the form `NN-HHHHH`"),
    ("is of form NN-HHHHH", "is of form `NN-HHHHH`"),
    ("of the bits of two int...", "of the bits of two integers"),
    ("of the bits of two inte...", "of the bits of two integers"),
    ("For example, ceil(0.5) is 1.0, and ceil(-0.5) is 0.0.",
     "For example, `ceil(0.5)` is 1.0, and `ceil(-0.5)` is 0.0."),
    ("[`atan2d`(3),", "`atan2d`(3),"),
    ("`lle`(3))", "`lle`(3)"),
    (": if `dim` present, required).", ": if `dim` is present, required."),
    ("if `dim` if present, coarray is required.",
     "if `dim` is present, coarray is required."),
    ("- `a` : is the data object to query", "- `a`: the data object to query"),
    ("is a ,scalar of the same type", "is a scalar of the same type"),
    ("a non-negative scalar integer..", "a non-negative scalar integer."),
    ("1, 2, .., N, where", "1, 2, ..., N, where"),
    ("_integer_,_character_,or _logical_",
     "_integer_, _character_, or _logical_"),
    ("of the result the result is", "of the result, the result is"),
    ("of type _integer(kind)_ if", "of type `integer(kind)` if"),
    ("Get number of command line arguments",
     "Get the number of command line arguments"),
    ("The atan operation", "The `atan` operation"),
    ("of the atan function", "of the `atan` function"),
    ("element (i,j) of the result", "element `(i,j)` of the result"),
    ("element (j,i) of the input for all (i,j).",
     "element `(j,i)` of the input for all `(i,j)`."),
]


def set_intrinsic_names(names: list[str]) -> None:
    """Calls are lowercase without a space ("atan(X)") or uppercase, as
    in the standard, optionally with one ("BESSEL_JN (N, X)")."""
    global intrinsic_call
    lower = "|".join(
        sorted((re.escape(n.lower()) for n in names), key=len, reverse=True)
    )
    upper = lower.upper()
    intrinsic_call = re.compile(
        rf"(?<![\w`.%-])((?:(?:{lower})|(?:{upper}) ?)\(([^()`\n]*)\))"
        r"(?![\w`])"
    )


def call_to_code(m: re.Match) -> str:
    # "the sum(s)" is an English plural, not a call
    return m.group(0) if m.group(2) == "s" else f"`{m.group(1)}`"


# Math ranges in prose, e.g. "-1 <= atan2pi (Y,X) <= 1" or "0 <= I <= 127"
_BOUND = r"-?(?:\d[\w.]*|PI(?:/\d+)?)"
MATH_RANGE = re.compile(
    rf"(?<![\w`])({_BOUND} ?\\?<= ?[^`<>\n]+? ?\\?<= ?{_BOUND})(?![\w`])"
)
# Shapes written with escaped brackets, e.g. "\[ m, n \]"
ESCAPED_SHAPE = re.compile(r"\\\[ ?([\w, ]+?) ?\\\]")
# Category tag on the first description line, e.g. "\[NUMERIC\]"
CATEGORY = re.compile(r"^(`\w+` - )\\\[([A-Z0-9:_, ]+)\\\]")
# Mathematical functions that are not Fortran intrinsics
MATH_FUNCTIONS = ["arctan", "arcsin", "arccos", "ceil"]


def fix_prose_segment(text: str) -> str:
    text = MATH_RANGE.sub(
        lambda m: code_span(m.group(1).replace("\\<", "<")), text
    )
    text = ESCAPED_SHAPE.sub(r"`[\1]`", text)
    text = MAN_REF.sub(r"`\1`(\2)", text)
    if intrinsic_call is not None:
        text = intrinsic_call.sub(call_to_code, text)
    text = SNAKE_IDENT.sub(r"`\1`", text)
    text = DOTTED_OP.sub(r"`\1`", text)
    for pattern, repl in PROSE_FIXES:
        text = pattern.sub(repl, text)
    return text


def fix_prose(lines: list[str]) -> list[str]:
    """Grammar and spacing fixes for prose; code spans and fences are left
    untouched, as is leading indentation (it carries Markdown structure)."""
    out = []
    in_fence = False
    in_comment = False
    for line in lines:
        if FENCE.match(line) and not in_comment:
            in_fence = not in_fence
            out.append(line)
            continue
        # HTML comments hold sample code; leave them alone
        if not in_fence and "<!--" in line and "-->" not in line:
            in_comment = True
        if in_comment:
            if "-->" in line:
                in_comment = False
            out.append(line)
            continue
        if in_fence or not line.strip():
            out.append(line)
            continue
        for old, new in TEXT_FIXES:
            line = line.replace(old, new)
        indent = line[: len(line) - len(line.lstrip())]
        parts = CODE_SPAN.split(line[len(indent):])
        parts = [
            p if i % 2 else fix_prose_segment(p) for i, p in enumerate(parts)
        ]
        # misplaced code span: "`(bit_size(i)`)" -> "(`bit_size(i)`)"
        fixed = "".join(parts).replace("`(bit_size(i)`)", "(`bit_size(i)`)")
        # space between a code span and following punctuation
        fixed = re.sub(r"(?<=`) +([.,;)])(?=[\s.,;:)]|$)", r"\1", fixed)
        fixed = re.sub(r"\( +(?=`)", "(", fixed)
        fixed = re.sub(r"(?<=`) {2,}(?=\S)", " ", fixed)
        out.append(indent + fixed)
    return out


def normalize(text: str) -> str:
    lines = fix_links(text).split("\n")
    lines = fix_fences_and_indented(lines)
    lines = drop_duplicate_titles(lines)
    lines = bold_to_code(lines)
    lines = fix_prose(lines)
    # page title: the procedure name is code
    if lines and re.fullmatch(r"## [a-z_][a-z0-9_]*", lines[0]):
        lines[0] = f"## `{lines[0][3:]}`"
    # category tag, e.g. "`abs` - \[NUMERIC\] Absolute value"
    lines = [CATEGORY.sub(r"\1`[\2]`", line) for line in lines]
    return "\n".join(lines)


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DIR
    paths = sorted(root.glob("*.md"))
    set_intrinsic_names([p.stem for p in paths] + MATH_FUNCTIONS)
    changed = 0
    for path in paths:
        text = path.read_text(encoding="utf-8")
        new = normalize(text)
        if new != text:
            path.write_text(new, encoding="utf-8", newline="\n")
            changed += 1
    print(f"normalized {changed} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
