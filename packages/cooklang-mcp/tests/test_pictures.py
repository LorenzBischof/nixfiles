"""Signed upload links, and what an upload does with one."""

import asyncio

import pytest
from cooklang_mcp import pictures
from cooklang_mcp.pictures import BadToken, mint, receive, verify

PATH = "Weeknight meals/Kürbiswähe.cook"


def test_a_link_authorises_the_one_recipe_it_was_minted_for():
    """And the path survives a round trip through a URL segment, which is why
    it is encoded: a slash alone would make the token two segments."""
    token = mint(PATH)

    assert verify(token) == PATH
    assert "/" not in token and " " not in token and "=" not in token


def test_a_token_this_server_did_not_sign_is_refused_as_a_forgery():
    """Each part tampered with on its own, including the recipe it names.

    The message matters as much as the refusal: "not issued here" tells the
    caller to ask for a new link, where "expired" would have them wait.
    """
    encoded, expiry, signature = mint(PATH).split(".")

    for token in (
        f"{encoded}.{expiry}.{'a' * len(signature)}",
        f"{pictures._b64(b'Secret.cook')}.{expiry}.{signature}",
        f"{encoded}.{int(expiry) + 31536000}.{signature}",
        "nonsense",
    ):
        with pytest.raises(BadToken, match="not issued by this server|not an upload"):
            verify(token)


def test_a_link_that_has_run_out_says_so_rather_than_failing_its_signature():
    """The signature is checked first precisely so this stays a distinct case:
    an unsigned token's expiry is whatever the sender wrote."""
    token = mint(PATH, now=0)

    assert verify(token, now=pictures.TTL_SECONDS - 1) == PATH
    with pytest.raises(BadToken, match="expired"):
        verify(token, now=pictures.TTL_SECONDS + 1)


def collection(monkeypatch, state, status=200):
    """A `cook server` answering every picture upload with `state`."""
    sent = []

    async def put_recipe_image(path, picture):
        sent.append((path, picture))
        return status, state

    monkeypatch.setattr(pictures.cook, "put_recipe_image", put_recipe_image)
    return sent


def test_an_upload_reaches_the_recipe_its_link_names(monkeypatch):
    sent = collection(monkeypatch, {"source": "file"})

    status, body = asyncio.run(receive(mint(PATH), b"\xff\xd8jpeg"))

    assert sent == [(PATH, b"\xff\xd8jpeg")]
    assert (status, body) == (
        200,
        {"path": PATH, "stored": True, "source": "file", "warnings": []},
    )


def test_an_upload_the_frontmatter_will_hide_still_says_so(monkeypatch):
    """`image` metadata wins over a stored file, so the upload can succeed and
    show on nothing. Only the recipe's own text fixes that."""
    collection(monkeypatch, {"source": "metadata"})

    _, body = asyncio.run(receive(mint(PATH), b"\xff\xd8jpeg"))

    assert body["stored"] is True
    (warning,) = body["warnings"]
    assert "`recipe_write`" in warning


def test_what_cook_server_refuses_is_passed_through_word_for_word(monkeypatch):
    """The HEIC case is what this is for: an iPhone photo is refused with
    instructions for converting it, and rewriting that here would lose them."""
    refusal = {"error": "HEIC and AVIF photos can't be read. …", "code": "heif"}
    sent = collection(monkeypatch, refusal, status=415)

    status, body = asyncio.run(receive(mint(PATH), b"\x00\x00\x00\x18ftypheic"))

    assert (status, body) == (415, refusal)
    # Sent anyway: deciding what a picture is belongs to the thing that decodes
    # it, and sniffing the bytes here would only disagree with it.
    assert len(sent) == 1


def test_an_unusable_link_is_refused_before_a_file_is_asked_for(monkeypatch):
    sent = collection(monkeypatch, {})

    status, body = asyncio.run(receive("forged.0.token", b"\xff\xd8jpeg"))

    assert status == 403
    assert sent == []
    assert "error" in body
