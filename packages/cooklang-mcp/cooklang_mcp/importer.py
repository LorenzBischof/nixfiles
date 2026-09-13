"""Reading a recipe off a web page.

`cook import` scrapes the page and then pays an LLM to turn it into Cooklang.
Only the first half belongs here: the caller of this tool is already a model,
so this module fetches and extracts, and the caller converts. Nothing here
summarises — what the page said is what the caller gets, so there is no gap for
a remembered recipe to fill.

Extraction is `recipe-scrapers`, which reads the schema.org Recipe data almost
every recipe site publishes. Pages that publish none get their readable text
instead — plenty of blogs put the recipe in prose and nowhere else.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import urljoin

import httpx
import yaml
from bs4 import BeautifulSoup
from recipe_scrapers import scrape_html

#: Upper bound on the text handed back. Structured extractions land far below
#: it; only the whole-page fallback ever comes close.
MAX_TEXT_CHARS = 60_000

#: Below this much readable text a 200 response is an empty JavaScript shell or
#: a bot challenge ("Just a moment...") rather than a page at all.
#:
#: Deliberately far below the length of a recipe. A higher bar looks like it
#: buys better detection and does not: a consent wall is paragraphs of legalese
#: and clears any threshold worth setting, while a plain static recipe — four
#: ingredients, three steps and no chatter around them — comes to under 300
#: characters and was being rejected wholesale. Whether a page that does have
#: words on it is a recipe is a judgement the caller makes from the text; this
#: only refuses to hand back a page that has no words.
MIN_PAGE_TEXT_CHARS = 100

#: Some sites serve a stub to anything that looks like a script.
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0 Safari/537.36"
)

#: The key the source URL is written under. Not `source`, the Cooklang standard
#: key: cookcli's web UI renders that as a plain nowrap text pill, and only
#: `source.url` as a link. It is a flat key with a dot in it, looked up
#: literally — the nested mapping form is not read at all.
SOURCE_URL = "source.url"

#: Where a page names its own picture when it publishes no recipe data. Both
#: spellings of each: `og:` belongs in `property` and `twitter:` in `name`, and
#: sites get that backwards often enough to be worth looking both ways.
IMAGE_META = [
    {"property": "og:image"},
    {"name": "og:image"},
    {"name": "twitter:image"},
    {"property": "twitter:image"},
]

#: Scraper field -> Cooklang metadata key, in the order they are written.
#: `title` and `source.url` come first and are handled separately.
METADATA_KEYS = [
    ("author", "author"),
    ("description", "description"),
    ("yields", "yield"),
    ("total_time", "time"),
    ("prep_time", "prep time"),
    ("cook_time", "cook time"),
    ("category", "course"),
    ("cuisine", "cuisine"),
    ("image", "image"),
]


async def fetch_recipe(url: str) -> dict[str, Any]:
    """Fetch `url` and extract whatever recipe it holds."""
    if not url.startswith(("http://", "https://")):
        raise ValueError(f"not an http(s) URL: {url}")

    async with httpx.AsyncClient(
        follow_redirects=True, timeout=30.0, headers={"User-Agent": USER_AGENT}
    ) as client:
        try:
            response = await client.get(url)
            response.raise_for_status()
        except httpx.HTTPError as err:
            raise RuntimeError(f"fetching {url}: {err}") from err
        html = response.text

    try:
        scraper = scrape_html(html, org_url=url, supported_only=False)
        # `to_json` asks for every field and drops the ones the page does not
        # answer, which is what makes one broken field survivable.
        data = scraper.to_json()
    except Exception:  # noqa: BLE001 - a page with no recipe data is not an error
        data = {}
    if not data.get("ingredients") and not data.get("instructions"):
        # Not `{}`: a page whose ingredients and steps are unreadable often
        # still names its title, author and picture, and none of that has to be
        # guessed back out of the page text.
        return _page_text(url, html, data)

    # A page can publish a Recipe with no `image` in it and still show the dish
    # off in its social-card tags.
    if not data.get("image"):
        image = _meta_image(BeautifulSoup(html, "html.parser"), url)
        if image:
            data["image"] = image

    title = (data.get("title") or "").strip() or None
    return {
        "url": url,
        "title": title,
        "frontmatter": _frontmatter(url, title, data),
        "text": _truncate(_recipe_text(data)),
        "extraction": "structured",
        "notes": [],
    }


def _recipe_text(data: dict[str, Any]) -> str:
    """The recipe as the page stated it: ingredients, then the method."""
    blocks: list[str] = []

    groups = data.get("ingredient_groups") or []
    if any(group.get("purpose") for group in groups):
        for group in groups:
            heading = group.get("purpose") or "Ingredients"
            lines = "\n".join(f"- {item}" for item in group.get("ingredients", []))
            blocks.append(f"{heading}:\n{lines}")
    else:
        lines = "\n".join(f"- {item}" for item in data.get("ingredients") or [])
        if lines:
            blocks.append(f"Ingredients:\n{lines}")

    steps = data.get("instructions_list") or []
    if steps:
        numbered = "\n".join(f"{n}. {step}" for n, step in enumerate(steps, 1))
        blocks.append(f"Instructions:\n{numbered}")
    elif data.get("instructions"):
        blocks.append(f"Instructions:\n{data['instructions']}")

    return "\n\n".join(blocks)


def _page_text(url: str, html: str, data: dict[str, Any]) -> dict[str, Any]:
    """Fall back to the readable text of the page.

    Returning something the caller can read beats returning an error. The raw
    HTML would be more faithful still, but a recipe page is routinely a
    megabyte of markup around a few kilobytes of words.

    Only the *recipe* was unreadable. Whatever `data` the scraper did get holds
    for the metadata, so a page that names its title or its picture keeps them.
    """
    soup = BeautifulSoup(html, "html.parser")
    for element in soup(["script", "style", "noscript", "template", "svg", "iframe"]):
        element.decompose()
    text = soup.get_text("\n", strip=True)

    if len(text) < MIN_PAGE_TEXT_CHARS:
        raise RuntimeError(
            f"{url} returned a page with no readable text at all ({len(text)} "
            "characters) — most likely a bot challenge or a page rendered by "
            "JavaScript. The recipe could not be read."
        )

    data = dict(data)
    # The dish is pictured whether or not its ingredients were readable: the
    # scraper's `image` first, then the social-card tags.
    if not data.get("image"):
        data["image"] = _meta_image(soup, url)

    notes = [
        "This page publishes no readable ingredients or steps, so `text` is "
        "the readable text of the whole page, navigation and comments "
        "included. Pick the ingredients and steps out of it and use nothing "
        "else."
    ]
    title = (data.get("title") or "").strip() or None
    if title is None:
        title = soup.title.get_text(strip=True) if soup.title else None
        notes.append(
            "`title` is the page's <title>, not necessarily the dish name — "
            "check it before writing."
        )

    return {
        "url": url,
        "title": title,
        "frontmatter": _frontmatter(url, title, data),
        "text": _truncate(text),
        "extraction": "page_text",
        "notes": notes,
    }


def _meta_image(soup: BeautifulSoup, url: str) -> str | None:
    """The picture a page names in its `og:`/`twitter:` meta tags, if any."""
    for attrs in IMAGE_META:
        tag = soup.find("meta", attrs=attrs)
        content = (tag.get("content") or "").strip() if tag else ""
        if content:
            # A relative `content` is rare but legal, and a bare path is no use
            # to whoever reads the metadata later.
            return urljoin(url, content)
    return None


def _frontmatter(url: str, title: str | None, data: dict[str, Any]) -> str:
    """Build a YAML frontmatter block ready to head the `.cook` file."""
    metadata: dict[str, Any] = {}
    if title:
        metadata["title"] = title
    # The one field that must not come from the page: a scraper's idea of the
    # URL can be a canonical or AMP variant, and the caller asked about *this*
    # one.
    metadata[SOURCE_URL] = url

    # Before `yield`, which it is derived from and reads next to.
    servings = _servings(data.get("yields"))
    if servings is not None:
        metadata["servings"] = servings

    for field, key in METADATA_KEYS:
        value = data.get(field)
        if value in (None, "", [], {}):
            continue
        # Times come back as a count of minutes; Cooklang wants a duration.
        metadata[key] = f"{value} minutes" if key.endswith("time") else value

    # No `tags`. A page's keywords are its SEO surface — one recipe offered
    # "Calcium", "Spring" and its author's name — and tags are the collection's
    # own vocabulary. The caller picks them.

    body = yaml.safe_dump(metadata, allow_unicode=True, sort_keys=False, width=1000)
    return f"---\n{body}---\n"


def _servings(yields: Any) -> int | None:
    """`servings` out of a `yields` string, so `{2%servings}` can scale it."""
    if not isinstance(yields, str):
        return None
    head = yields.split(maxsplit=1)[0] if yields.split() else ""
    return int(head) if head.isdigit() else None


def _truncate(text: str) -> str:
    text = text.strip()
    if len(text) <= MAX_TEXT_CHARS:
        return text
    return text[:MAX_TEXT_CHARS] + "\n\n[truncated]"
