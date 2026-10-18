"""Agent-oriented catalogue edits, compiled to one atomic CookCLI batch."""

from copy import deepcopy
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, model_validator

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]
Position = Annotated[int, Field(ge=0)]


class Edit(BaseModel):
    model_config = {"extra": "forbid"}


class CreateAisle(Edit):
    action: Literal["create"]
    name: Name
    position: Position | None = None


class RenameAisle(Edit):
    action: Literal["rename"]
    name: Name
    new_name: Name


class MoveAisle(Edit):
    action: Literal["move"]
    name: Name
    position: Position


class DeleteAisle(Edit):
    action: Literal["delete"]
    name: Name
    delete_ingredients: bool = False


AisleChange = Annotated[
    CreateAisle | RenameAisle | MoveAisle | DeleteAisle, Field(discriminator="action")
]


class CreateIngredient(Edit):
    action: Literal["create"]
    name: Name
    aisle: Name
    aliases: list[Name] = Field(default_factory=list)


class UpdateIngredient(Edit):
    action: Literal["update"]
    ingredient: Name
    preferred_name: Name | None = None
    aisle: Name | None = None
    add_aliases: list[Name] = Field(default_factory=list)
    remove_aliases: list[Name] = Field(default_factory=list)

    @model_validator(mode="after")
    def has_changes(self):
        if not (
            self.preferred_name or self.aisle or self.add_aliases or self.remove_aliases
        ):
            raise ValueError(
                "Supply preferred_name, aisle, add_aliases or remove_aliases."
            )
        if {n.lower() for n in self.add_aliases} & {
            n.lower() for n in self.remove_aliases
        }:
            raise ValueError("Cannot add and remove the same alias.")
        return self


class MergeIngredients(Edit):
    action: Literal["merge"]
    ingredients: Annotated[list[Name], Field(min_length=2)]
    preferred_name: Name


class DeleteIngredient(Edit):
    action: Literal["delete"]
    ingredient: Name


IngredientChange = Annotated[
    CreateIngredient | UpdateIngredient | MergeIngredients | DeleteIngredient,
    Field(discriminator="action"),
]


def unique(names):
    """Preserve order and spelling, matching CookCLI's case-insensitive lookup."""
    seen = set()
    result = []
    for name in names:
        if name.lower() not in seen:
            seen.add(name.lower())
            result.append(name)
    return result


def compile_changes(catalogue, changes):
    """Track earlier edits so later updates preserve their changes too.

    This is a private snapshot; CookCLI validates and commits the complete batch
    against the same revision. No writes happen while planning.
    """
    aisles = deepcopy(catalogue["aisles"])

    def aisle_named(name):
        for aisle in aisles:
            if aisle["name"].lower() == name.lower():
                return aisle
        raise ValueError(f"Aisle not found: {name}")

    def ingredient_named(name):
        for aisle in aisles:
            for entry in aisle["ingredients"]:
                if any(n.lower() == name.lower() for n in entry["names"]):
                    return aisle, entry
        raise ValueError(f"Ingredient not found: {name}")

    batch = []
    for change in changes:
        if isinstance(change, CreateAisle):
            aisles.append({"name": change.name, "ingredients": []})
            batch.append(
                {**change.model_dump(exclude_none=True), "action": "add_aisle"}
            )
        elif isinstance(change, (RenameAisle, MoveAisle, DeleteAisle)):
            aisle = aisle_named(change.name)
            body = change.model_dump(exclude={"delete_ingredients"})
            body["name"] = aisle["name"]
            if isinstance(change, RenameAisle):
                aisle["name"] = change.new_name
                body["action"] = "rename_aisle"
            elif isinstance(change, MoveAisle):
                body["action"] = "move_aisle"
            else:
                if aisle["ingredients"] and not change.delete_ingredients:
                    raise ValueError(
                        f"Aisle {change.name!r} is not empty. Move its ingredients first "
                        "or set delete_ingredients=true."
                    )
                aisles.remove(aisle)
                body["action"] = "remove_aisle"
            batch.append(body)
        elif isinstance(change, CreateIngredient):
            names = unique([change.name, *change.aliases])
            aisle = aisle_named(change.aisle)
            aisle["ingredients"].append({"names": names})
            batch.append(
                {"action": "add_ingredient", "aisle": aisle["name"], "names": names}
            )
        elif isinstance(change, UpdateIngredient):
            aisle, entry = ingredient_named(change.ingredient)
            old = entry["names"]
            preferred = change.preferred_name or old[0]
            removed = {n.lower() for n in change.remove_aliases}
            if preferred.lower() in removed:
                raise ValueError(
                    "Cannot remove the preferred name; choose another preferred_name first."
                )
            missing = removed - {n.lower() for n in old}
            if missing:
                raise ValueError(f"Aliases not found: {', '.join(sorted(missing))}")
            names = unique(
                [
                    preferred,
                    *(n for n in old if n.lower() not in removed),
                    *change.add_aliases,
                ]
            )
            body = {
                "action": "update_ingredient",
                "name": change.ingredient,
                "names": names,
            }
            if change.aisle:
                target = aisle_named(change.aisle)
                body["aisle"] = target["name"]
                if target is not aisle:
                    aisle["ingredients"].remove(entry)
                    target["ingredients"].append(entry)
            entry["names"] = names
            batch.append(body)
        elif isinstance(change, DeleteIngredient):
            aisle, entry = ingredient_named(change.ingredient)
            aisle["ingredients"].remove(entry)
            batch.append({"action": "remove_ingredient", "name": change.ingredient})
        elif isinstance(change, MergeIngredients):
            selected = []
            for name in change.ingredients:
                pair = ingredient_named(name)
                if not any(entry is pair[1] for _, entry in selected):
                    selected.append(pair)
            if len(selected) < 2:
                raise ValueError("Choose at least two different ingredients to merge.")
            keep = next(
                (
                    entry
                    for _, entry in selected
                    if any(
                        n.lower() == change.preferred_name.lower()
                        for n in entry["names"]
                    )
                ),
                None,
            )
            if keep is None:
                raise ValueError(
                    "preferred_name must be an existing name of a selected ingredient."
                )
            preferred = next(
                n for n in keep["names"] if n.lower() == change.preferred_name.lower()
            )
            names = unique(
                [
                    preferred,
                    *keep["names"],
                    *(
                        n
                        for _, entry in selected
                        if entry is not keep
                        for n in entry["names"]
                    ),
                ]
            )
            for aisle, entry in selected:
                if entry is not keep:
                    aisle["ingredients"].remove(entry)
            keep["names"] = names
            batch.append(
                {
                    "action": "merge_ingredients",
                    "names": change.ingredients,
                    "main": change.preferred_name,
                }
            )
    return batch
