"""The MCP surface exposed to clients."""

import asyncio

from cooklang_mcp import server
from cooklang_mcp.server import INSTRUCTIONS, mcp


def test_search_recipes_advertises_its_result_fields():
    tools = {tool.name: tool for tool in asyncio.run(mcp.list_tools())}

    assert "list_recipes" not in tools
    schema = tools["search_recipes"].model_dump(by_alias=True)["outputSchema"]
    summary = schema["$defs"]["RecipeSummary"]

    assert set(summary["properties"]) == {
        "path",
        "title",
        "web_url",
        "tags",
        "is_menu",
    }
    assert summary["required"] == ["path", "title", "web_url", "tags", "is_menu"]
    assert schema["properties"]["result"]["items"] == {"$ref": "#/$defs/RecipeSummary"}


def test_recipe_tools_return_clickable_web_urls(monkeypatch):
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")

    async def search_entries(_query):
        return [
            {
                "path": "Weeknight meals/Chili & Rice.cook",
                "title": "Chili & Rice",
                "tags": ["dinner"],
                "is_menu": False,
            }
        ]

    async def shopping_list():
        return {
            "recipes": [{"path": "Weeknight meals/Chili & Rice.cook", "scale": 1.0}],
            "categories": [],
            "pantry_items": [],
        }

    class Response:
        text = "---\ntitle: Chili & Rice\n---\n"

        @staticmethod
        def json():
            return {"recipe": {"ingredients": [{"name": "rice"}]}}

    async def request(_method, _path, **_kwargs):
        return Response()

    monkeypatch.setattr(server.cook, "search_entries", search_entries)
    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    summary = asyncio.run(server.search_recipes("chili"))[0]
    document = asyncio.run(server.read_recipe("./Weeknight meals/Chili & Rice.cook"))
    shopping = asyncio.run(server.shopping_list())
    written = asyncio.run(
        server.write_recipe(
            "Weeknight meals/Chili & Rice.cook",
            Response.text,
        )
    )
    expected = (
        "https://cook.example.test/recipe/Weeknight%20meals/Chili%20%26%20Rice.cook"
    )

    assert summary.web_url == expected
    assert document.web_url == expected
    assert document.source == Response.text
    assert shopping["recipes"][0]["web_url"] == expected
    assert written == {
        "path": "Weeknight meals/Chili & Rice.cook",
        "web_url": expected,
        "written": True,
        "ingredients": ["rice"],
    }


def test_meal_plan_convention_is_advertised():
    tools = {tool.name: tool for tool in asyncio.run(mcp.list_tools())}
    write_description = tools["write_recipe"].description
    shopping_description = tools["shopping_list"].description

    assert "`Meal Plan.menu`" in INSTRUCTIONS
    assert "`Meal History.menu`" in INSTRUCTIONS
    assert "Only copy" in INSTRUCTIONS
    assert "explicitly asks" in INSTRUCTIONS
    assert "Skip an already-planned path" in INSTRUCTIONS
    assert "`Risotto.cook` and `./Risotto` are the same path" in INSTRUCTIONS
    assert "all of them are checked" in INSTRUCTIONS
    assert "— date estimated" in INSTRUCTIONS
    assert "ask for brief, optional feedback" in INSTRUCTIONS
    assert "Feedback:" in INSTRUCTIONS
    assert "Reuse a matching date section" in INSTRUCTIONS
    assert "newest-first" in INSTRUCTIONS
    assert "history successfully before removing" in INSTRUCTIONS
    assert "clickable Markdown link" in INSTRUCTIONS
    assert "`web_url` returned by the tools" in INSTRUCTIONS
    assert "`Meal Plan.menu`" in write_description
    assert "`Meal History.menu`" in write_description
    assert "blank line (two newline characters)" in write_description
    assert "— date estimated" in write_description
    assert "Feedback:" in write_description
    assert "source path and scale" in shopping_description
    assert "`checked` individually" in shopping_description
