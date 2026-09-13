"""Turning a scraped page into something writable."""

import pytest
import yaml
from bs4 import BeautifulSoup
from cooklang_mcp.importer import (
    _frontmatter,
    _meta_image,
    _page_text,
    _recipe_text,
    _servings,
)


def parse(frontmatter: str) -> dict:
    assert frontmatter.startswith("---\n") and frontmatter.endswith("---\n")
    return yaml.safe_load(frontmatter[4:-4])


def test_frontmatter_records_the_url_that_was_asked_for():
    """Not the page's own canonical URL, which is routinely an AMP variant."""
    block = _frontmatter(
        "https://example.com/rezept?utm_source=x",
        "Käsekuchen",
        {"canonical_url": "https://example.com/amp/rezept", "author": "Nina"},
    )
    metadata = parse(block)

    assert metadata["source.url"] == "https://example.com/rezept?utm_source=x"
    assert metadata["title"] == "Käsekuchen"
    assert metadata["author"] == "Nina"
    # `source` is a text pill in the web UI; only `source.url` is a link.
    assert "source" not in metadata


def test_frontmatter_translates_scraper_fields_to_cooklang_keys():
    metadata = parse(
        _frontmatter(
            "https://example.com/r",
            "Pfannkuchen",
            {
                "yields": "4 servings",
                "total_time": 35,
                "prep_time": 10,
                "keywords": ["süß", "schnell"],
                "ratings": 4.5,
            },
        )
    )

    assert metadata["servings"] == 4
    assert metadata["yield"] == "4 servings"
    assert metadata["time"] == "35 minutes"
    assert metadata["prep time"] == "10 minutes"
    # Fields with no Cooklang meaning are dropped rather than carried along,
    # and a page's keywords are SEO, not the collection's tag vocabulary.
    assert "ratings" not in metadata
    assert "tags" not in metadata


def test_meta_image_reads_the_social_card_tags():
    """A page with no recipe data still says which picture is the dish."""
    soup = BeautifulSoup(
        '<meta property="og:image" content="/bilder/kuchen.jpg">', "html.parser"
    )

    # Relative, as it is allowed to be — resolved against the page it came from.
    assert (
        _meta_image(soup, "https://example.com/rezepte/kuchen")
        == "https://example.com/bilder/kuchen.jpg"
    )


def test_meta_image_falls_back_to_twitter_and_then_to_nothing():
    twitter = BeautifulSoup(
        '<meta name="twitter:image" content="https://example.com/t.jpg">',
        "html.parser",
    )
    assert _meta_image(twitter, "https://example.com/r") == "https://example.com/t.jpg"

    empty = BeautifulSoup('<meta property="og:image" content="  ">', "html.parser")
    assert _meta_image(empty, "https://example.com/r") is None


def test_frontmatter_omits_an_image_the_page_never_named():
    assert "image" not in parse(_frontmatter("https://example.com/r", "X", {}))
    assert "image" not in parse(
        _frontmatter("https://example.com/r", "X", {"image": None})
    )


def test_page_text_keeps_the_metadata_the_scraper_did_find():
    """The recipe was unreadable, not the page's picture and name.

    This is the shape of a site whose microdata marks up the image and the
    title but leaves the ingredients as ordinary prose.
    """
    html = f"<html><head><title>Älplermagaronen | Rezepte</title></head><body>{'Zutaten. ' * 100}</body></html>"

    result = _page_text(
        "https://example.com/rezepte/x",
        html,
        {"title": "Älplermagaronen", "image": "https://example.com/bild.jpg"},
    )
    metadata = parse(result["frontmatter"])

    assert metadata["image"] == "https://example.com/bild.jpg"
    # The marked-up name beats the <title>, which carries the site's suffix.
    assert result["title"] == "Älplermagaronen"
    assert metadata["title"] == "Älplermagaronen"
    # ...so the warning about <title> not being the dish name does not apply.
    assert not any("<title>" in note for note in result["notes"])


def test_page_text_returns_a_recipe_too_short_to_look_like_one():
    """A whole static recipe can be shorter than a bot challenge is wordy.

    This is fruitjuicetab.ch to the character: four ingredients, three steps,
    no prose around them. It has everything the caller needs and comes to a
    couple of hundred characters, so length cannot be what decides.
    """
    html = (
        "<html><head><title>Omelette</title></head><body>"
        "<h1>Omelette</h1><h2>Zutaten</h2>"
        "<ul><li>200g Mehl</li><li>320ml Milch</li>"
        "<li>1 Prise Salz</li><li>4 Eier</li></ul>"
        "<h2>Zubereitung</h2>"
        "<ol><li>Mehl und Milch verruehren.</li>"
        "<li>Salz und die Eier darunterruehren.</li>"
        "<li>Eine duenne Schicht Teig goldbraun backen.</li></ol>"
        "</body></html>"
    )

    result = _page_text("https://example.com/omelette/", html, {})

    assert len(result["text"]) < 300
    assert "320ml Milch" in result["text"]
    assert "goldbraun backen" in result["text"]


def test_page_text_refuses_a_page_with_no_words_on_it():
    """An empty shell or a challenge interstitial is not a recipe to read."""
    html = "<html><head><title>Just a moment...</title><body>Enable JavaScript and cookies to continue</body></html>"

    with pytest.raises(RuntimeError, match="no readable text"):
        _page_text("https://example.com/r", html, {})


def test_page_text_falls_back_to_the_page_title_and_says_so():
    html = f"<html><head><title>Rezept des Tages</title></head><body>{'Zutaten. ' * 100}</body></html>"

    result = _page_text("https://example.com/r", html, {})

    assert result["title"] == "Rezept des Tages"
    assert any("<title>" in note for note in result["notes"])


def test_servings_only_where_the_yield_starts_with_a_count():
    assert _servings("4 servings") == 4
    assert _servings("12 Stück") == 12
    assert _servings("a loaf") is None
    assert _servings(None) is None


def test_recipe_text_keeps_ingredient_group_headings():
    text = _recipe_text(
        {
            "ingredient_groups": [
                {"purpose": "Für den Boden", "ingredients": ["200 g Mehl"]},
                {"purpose": "Für die Füllung", "ingredients": ["1 kg Quark"]},
            ],
            "instructions_list": ["Teig kneten.", "Backen."],
        }
    )

    assert text == (
        "Für den Boden:\n- 200 g Mehl\n\n"
        "Für die Füllung:\n- 1 kg Quark\n\n"
        "Instructions:\n1. Teig kneten.\n2. Backen."
    )


def test_recipe_text_without_groups_is_a_plain_list():
    text = _recipe_text(
        {
            "ingredients": ["3 Eier", "250 ml Milch"],
            "ingredient_groups": [{"purpose": None, "ingredients": ["3 Eier"]}],
            "instructions": "Alles verrühren.",
        }
    )

    assert (
        text
        == "Ingredients:\n- 3 Eier\n- 250 ml Milch\n\nInstructions:\nAlles verrühren."
    )
