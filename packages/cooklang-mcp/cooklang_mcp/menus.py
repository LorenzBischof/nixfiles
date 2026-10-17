"""Meal-plan and meal-history files, edited structurally rather than by prose.

`Meal Plan.menu` and `Meal History.menu` are ordinary Cooklang files, so a
client could edit them with the recipe tools alone. It did so badly: recording
a cooked meal means appending to one file under the right date section, in the
right order, and removing the same recipe from another, and every part of that
was a paragraph of instructions the model could drop. `mark_cooked` does it
here instead, and the instructions shrink to the one judgement that is really
the model's — which day the meal was eaten.

A file is parsed as optional YAML frontmatter followed by sections introduced
by `= Heading`, each holding blocks of lines separated by blank lines. A block
is the unit that moves: a recipe reference and the `Feedback:` line below it are
two blocks, which is why a reference can be removed without taking the note
after it. Rendering is normalised to one blank line between blocks, so a round
trip tidies spacing rather than preserving it byte for byte.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date as Date

_FENCE = "---"
_SECTION = re.compile(r"^=+\s*(.*?)\s*=*$")
_HEADING_DATE = re.compile(r"\((\d{4}-\d{2}-\d{2})\)")

# A component is `@name{...}`, and only the braces let its name hold a space.
# Without them Cooklang ends the name at the first space, so match that shape
# too rather than silently ignoring a reference written `@./Risotto`.
_COMPONENT = re.compile(r"^@(?:(?P<braced>[^{@]*)\{|(?P<bare>[^{@\s]+))")

ESTIMATED = "— date estimated"
HISTORY_FRONTMATTER = (_FENCE, "title: Meal History", _FENCE)


@dataclass
class Section:
    """One `= Heading` and its blocks; `heading` is None before the first."""

    heading: str | None
    blocks: list[list[str]] = field(default_factory=list)


@dataclass
class Menu:
    """A parsed menu file."""

    frontmatter: list[str] = field(default_factory=list)
    sections: list[Section] = field(default_factory=list)


def normalise(path: str) -> str:
    """A recipe path stripped to the part a reference and a path agree on.

    `Risotto.cook`, `./Risotto` and `Risotto` all name one recipe, so all three
    have to compare equal.
    """
    while path.startswith("./"):
        path = path[2:]
    for suffix in (".cook", ".menu"):
        if path.endswith(suffix):
            return path[: -len(suffix)]
    return path


def reference(path: str) -> str:
    """The `./Name` spelling a menu file refers to a recipe by."""
    return f"./{normalise(path)}"


def same_recipe(left: str, right: str) -> bool:
    """Whether two paths or references name the same recipe."""
    return normalise(left).casefold() == normalise(right).casefold()


def parse(source: str) -> Menu:
    """Split a menu file into frontmatter, sections and blocks."""
    lines = source.splitlines()
    frontmatter: list[str] = []
    if lines and lines[0].strip() == _FENCE:
        for index in range(1, len(lines)):
            if lines[index].strip() == _FENCE:
                frontmatter = [line.rstrip() for line in lines[: index + 1]]
                lines = lines[index + 1 :]
                break
    menu = Menu(frontmatter=frontmatter, sections=[Section(heading=None)])
    block: list[str] = []
    for line in lines:
        stripped = line.strip()
        heading = _SECTION.match(stripped) if stripped.startswith("=") else None
        if heading or not stripped:
            if block:
                menu.sections[-1].blocks.append(block)
                block = []
            if heading:
                menu.sections.append(Section(heading=heading.group(1)))
            continue
        block.append(line.rstrip())
    if block:
        menu.sections[-1].blocks.append(block)
    return menu


def render(menu: Menu) -> str:
    """A parsed menu back as a file, with its spacing normalised."""
    chunks: list[str] = []
    for section in menu.sections:
        blocks = ["\n".join(block) for block in section.blocks]
        if section.heading is None:
            chunks.extend(blocks)
            continue
        # The heading joins its first block, so no blank line separates the two.
        heading = f"= {section.heading}"
        chunks.append(f"{heading}\n{blocks[0]}" if blocks else heading)
        chunks.extend(blocks[1:])
    body = "\n\n".join(chunks)
    head = "\n".join(menu.frontmatter)
    text = f"{head}\n{body}" if head and body else head or body
    return f"{text.rstrip()}\n" if text.strip() else ""


def component(line: str) -> str | None:
    """The name of the component a line opens with, if it opens with one."""
    match = _COMPONENT.match(line.strip())
    if not match:
        return None
    return (match.group("braced") or match.group("bare") or "").strip() or None


def heading_date(heading: str) -> Date | None:
    """The `(YYYY-MM-DD)` a history heading carries, if it carries one."""
    match = _HEADING_DATE.search(heading)
    if not match:
        return None
    try:
        return Date.fromisoformat(match.group(1))
    except ValueError:
        return None


def add_to_history(
    source: str,
    path: str,
    cooked: Date,
    estimated: bool = False,
    feedback: str | None = None,
) -> str:
    """`source` with `path` recorded as cooked on `cooked`.

    The recipe joins an existing section for that date or opens a new one, kept
    in newest-first order among the sections that carry a date. Feedback
    becomes its own block directly below the reference it describes.
    """
    menu = parse(source) if source.strip() else _new_history()
    entry = f"@{reference(path)}{{}}"
    if estimated:
        entry = f"{entry} {ESTIMATED}"
    blocks = [[entry]]
    if feedback and feedback.strip():
        blocks.append([f"Feedback: {feedback.strip()}"])

    for section in menu.sections:
        if section.heading and heading_date(section.heading) == cooked:
            section.blocks[:0] = blocks
            return render(menu)

    index = len(menu.sections)
    for position, section in enumerate(menu.sections):
        if section.heading is None:
            continue
        other = heading_date(section.heading)
        if other is not None and other < cooked:
            index = position
            break
    heading = f"{cooked.strftime('%A')} ({cooked.isoformat()})"
    menu.sections.insert(index, Section(heading=heading, blocks=blocks))
    return render(menu)


def remove_from_plan(source: str, path: str) -> tuple[str, bool]:
    """`source` without `path`, and whether it was there at all.

    Only blocks that open with a reference to this recipe go. A loose
    ingredient, or a note under some other recipe, is left where it is.
    """
    menu = parse(source)
    removed = False
    for section in menu.sections:
        kept = []
        for block in section.blocks:
            name = component(block[0])
            if name is not None and same_recipe(name, path):
                removed = True
                continue
            kept.append(block)
        section.blocks = kept
    return render(menu), removed


def _new_history() -> Menu:
    return Menu(frontmatter=list(HISTORY_FRONTMATTER), sections=[Section(heading=None)])
