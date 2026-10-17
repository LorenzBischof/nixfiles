"""Menu-file surgery: the part `mark_cooked` used to leave to the client."""

from datetime import date

import pytest

from cooklang_mcp import menus

HISTORY = (
    "---\ntitle: Meal History\n---\n"
    "= Saturday (2026-10-17)\n@./Chili{}\n\n"
    "Feedback: Too hot.\n\n"
    "= Monday (2026-10-12)\n@./Soup{}\n"
)


@pytest.mark.parametrize(
    ("left", "right"),
    [
        ("Risotto.cook", "./Risotto"),
        ("Risotto.cook", "Risotto"),
        ("./Risotto", "risotto"),
        ("Meal Plan.menu", "./Meal Plan"),
        ("Weeknight meals/Chili.cook", "./Weeknight meals/Chili"),
    ],
)
def test_a_path_and_a_reference_name_the_same_recipe(left, right):
    assert menus.same_recipe(left, right)
    assert menus.same_recipe(right, left)


def test_different_recipes_stay_different():
    assert not menus.same_recipe("Risotto.cook", "Risotto Bianco.cook")
    assert not menus.same_recipe("Chili.cook", "Weeknight meals/Chili.cook")


def test_a_reference_is_the_path_without_its_extension():
    assert menus.reference("Weeknight meals/Chili & Rice.cook") == (
        "./Weeknight meals/Chili & Rice"
    )
    assert menus.reference("./Risotto") == "./Risotto"


@pytest.mark.parametrize(
    ("line", "name"),
    [
        ("@./Risotto{}", "./Risotto"),
        ("@./Risotto{} — date estimated", "./Risotto"),
        ("@./Risotto{2%servings}", "./Risotto"),
        ("@paper towels{1}", "paper towels"),
        # Braces are what let a name hold a space, but a bare one still parses.
        ("@./Risotto", "./Risotto"),
        ("Feedback: Too hot.", None),
        ("", None),
    ],
)
def test_a_block_s_first_line_identifies_its_component(line, name):
    assert menus.component(line) == name


def test_a_round_trip_keeps_the_file_and_normalises_its_spacing():
    assert menus.render(menus.parse(HISTORY)) == HISTORY
    # Extra blank lines collapse; the content survives.
    assert menus.render(menus.parse("= Meals\n\n\n@./A{}\n\n\n\n@./B{}\n\n")) == (
        "= Meals\n@./A{}\n\n@./B{}\n"
    )


def test_a_new_date_opens_a_section_in_newest_first_order():
    assert menus.add_to_history(HISTORY, "Risotto.cook", date(2026, 10, 14)) == (
        "---\ntitle: Meal History\n---\n"
        "= Saturday (2026-10-17)\n@./Chili{}\n\n"
        "Feedback: Too hot.\n\n"
        "= Wednesday (2026-10-14)\n@./Risotto{}\n\n"
        "= Monday (2026-10-12)\n@./Soup{}\n"
    )


def test_the_newest_and_oldest_dates_land_at_the_ends():
    newest = menus.add_to_history(HISTORY, "Risotto.cook", date(2026, 10, 20))
    assert newest.index("Risotto") < newest.index("Chili")
    oldest = menus.add_to_history(HISTORY, "Risotto.cook", date(2026, 1, 1))
    assert oldest.index("Risotto") > oldest.index("Soup")


def test_a_matching_date_is_reused_and_feedback_follows_its_recipe():
    assert menus.add_to_history(
        HISTORY,
        "Risotto.cook",
        date(2026, 10, 12),
        feedback="Perfect.",
    ) == (
        "---\ntitle: Meal History\n---\n"
        "= Saturday (2026-10-17)\n@./Chili{}\n\n"
        "Feedback: Too hot.\n\n"
        "= Monday (2026-10-12)\n@./Risotto{}\n\n"
        "Feedback: Perfect.\n\n"
        "@./Soup{}\n"
    )


def test_an_estimated_date_is_marked_on_the_recipe_only():
    written = menus.add_to_history(
        HISTORY, "Risotto.cook", date(2026, 10, 14), estimated=True
    )

    assert "@./Risotto{} — date estimated" in written
    assert "@./Chili{}\n" in written


def test_blank_feedback_is_not_recorded():
    for blank in (None, "", "   "):
        written = menus.add_to_history(
            "", "Risotto.cook", date(2026, 10, 14), feedback=blank
        )
        assert "Feedback" not in written


def test_an_empty_history_gets_frontmatter():
    assert menus.add_to_history("", "Risotto.cook", date(2026, 10, 14)) == (
        "---\ntitle: Meal History\n---\n= Wednesday (2026-10-14)\n@./Risotto{}\n"
    )


def test_removing_a_recipe_leaves_the_rest_of_the_plan_alone():
    plan = (
        "---\ntitle: Meal Plan\n---\n"
        "= Meals\n@./Risotto{2%servings}\n\n@./Caprese{}\n\n@paper towels{1}\n"
    )
    trimmed, removed = menus.remove_from_plan(plan, "Risotto.cook")

    assert removed is True
    assert trimmed == (
        "---\ntitle: Meal Plan\n---\n= Meals\n@./Caprese{}\n\n@paper towels{1}\n"
    )


def test_removing_a_recipe_that_is_not_there_changes_nothing():
    plan = "---\ntitle: Meal Plan\n---\n= Meals\n@./Caprese{}\n"
    trimmed, removed = menus.remove_from_plan(plan, "Risotto.cook")

    assert removed is False
    assert trimmed == plan


def test_a_loose_ingredient_is_never_mistaken_for_a_recipe():
    plan = "= Meals\n@paper towels{1}\n"
    _trimmed, removed = menus.remove_from_plan(plan, "paper towels.cook")

    # It matches by name, which is correct: nothing else can tell them apart.
    # What matters is that an unrelated removal leaves it in place.
    assert removed is True
    other, removed = menus.remove_from_plan(plan, "Risotto.cook")
    assert removed is False
    assert other == plan


def test_a_reference_written_either_way_is_found():
    for spelling in ("@./Risotto{}", "@Risotto{}", "@./Risotto"):
        _trimmed, removed = menus.remove_from_plan(
            f"= Meals\n{spelling}\n", "Risotto.cook"
        )
        assert removed is True, spelling


def test_a_heading_without_a_date_is_left_in_place():
    source = "= Meals\n@./Soup{}\n"
    written = menus.add_to_history(source, "Risotto.cook", date(2026, 10, 14))

    assert "= Meals" in written
    assert "= Wednesday (2026-10-14)" in written
    assert menus.heading_date("Meals") is None
    assert menus.heading_date("Friday (2026-02-30)") is None
    assert menus.heading_date("Friday (2026-10-16)") == date(2026, 10, 16)
