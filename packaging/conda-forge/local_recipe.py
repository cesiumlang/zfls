"""Copy the conda-forge recipe for a build from a local source archive.

The recipe builds a released zfls from the source archive attached to the
GitHub release. To build an unreleased one (in CI, or to try changes to the
recipe), this writes a copy of the recipe directory whose first source is the
given archive (made by tools/make_source_archive.sh) and whose version is the
archive's:

    python packaging/conda-forge/local_recipe.py \
        dist/zfls-v0.1.2-src.tar.gz OUT
    rattler-build build --recipe OUT -c conda-forge
"""

import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARCHIVE_NAME = re.compile(r"zfls-v(\d+\.\d+\.\d+)-src\.tar\.gz$")
VARIANTS = """\
c_stdlib:
  - if: osx
    then: macosx_deployment_target
c_stdlib_version:
  - if: osx and x86_64
    then: "10.13"
  - if: osx and arm64
    then: "11.0"
"""
FIRST_SOURCE = re.compile(
    r"(source:\n.*?)  - url: [^\n]+\n    sha256: [^\n]+\n", re.S
)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    archive = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    m = ARCHIVE_NAME.search(archive.name)
    if not m or not archive.is_file():
        print(f"not a zfls source archive: {archive}")
        return 2
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(HERE, out, ignore=shutil.ignore_patterns("*.py"))

    recipe = out / "recipe.yaml"
    text = recipe.read_text(encoding="utf-8")
    text, n = FIRST_SOURCE.subn(
        lambda s: f"{s.group(1)}  - path: {archive.as_posix()}\n", text, 1
    )
    if n != 1:
        print("cannot find the first source in recipe.yaml")
        return 1
    text = re.sub(r'(\n  version: )"[^"]*"', rf'\1"{m.group(1)}"', text, 1)
    recipe.write_text(text, encoding="utf-8", newline="\n")
    # what conda-forge's global pinning provides on its build machines
    (out / "variants.yaml").write_text(VARIANTS, encoding="utf-8",
                                       newline="\n")
    print(recipe)
    return 0


if __name__ == "__main__":
    sys.exit(main())
