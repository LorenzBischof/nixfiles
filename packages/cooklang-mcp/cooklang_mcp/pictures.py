"""Signed upload links for a recipe's title picture.

MCP cannot carry a file: a tool call is JSON, and its schema vocabulary has no
file type, so the only route through the protocol is the model reciting base64
— 140,000 tokens for a 400 KB photo, corrupt if one of them slips. The bytes go
out of band instead, which is what the protocol's own maintainers recommend: a
tool hands out a URL and whatever holds the photo PUTs it there.

The link authenticates itself, because the uploader has no credential. This
server's bearer token lives in the client's connector configuration, the model
never sees it, and handing it over would put a key to the whole collection into
a transcript to buy one picture. So the link carries what it authorises — one
recipe path, one expiry — followed by an HMAC over both, and verifying
recomputes the signature rather than looking anything up. Keeping no list of
outstanding links is the point: there is nothing to hold in a service whose
unit file says it writes nothing. The cost is that a link can be spent twice
inside its five minutes, which sets the same picture twice.

The key is made at startup, so there is no secret to deploy or rotate. A
restart invalidates whatever was outstanding, and `verify` says so rather than
calling those links forgeries.
"""

from __future__ import annotations

import base64
import hmac
import secrets
import time
from hashlib import sha256
from typing import Any

from . import cookcli as cook

#: Minting and uploading are two consecutive calls, so this is already
#: generous. It bounds how long a link left behind in a transcript stays live.
TTL_SECONDS = 5 * 60

_KEY = secrets.token_bytes(32)


class BadToken(ValueError):
    """An upload token this server did not sign, or will no longer honour."""


def _b64(raw: bytes) -> str:
    """URL-safe base64, unpadded: a token holds no `/` and no `=`."""
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _signature(payload: str) -> str:
    return _b64(hmac.new(_KEY, payload.encode(), sha256).digest())


def mint(path: str, now: float | None = None) -> str:
    """A token authorising one upload to `path`, and nothing else.

    The path is encoded because a real one holds slashes, spaces and umlauts —
    `Weeknight meals/Kürbiswähe.cook` — and a slash would make it two segments.
    """
    expiry = int((time.time() if now is None else now) + TTL_SECONDS)
    payload = f"{_b64(path.encode())}.{expiry}"
    return f"{payload}.{_signature(payload)}"


def verify(token: str, now: float | None = None) -> str:
    """The recipe path `token` authorises an upload to, or raise `BadToken`."""
    parts = token.split(".")
    if len(parts) != 3:
        raise BadToken("this is not an upload link")
    encoded, expiry, signature = parts

    # Before the expiry is so much as read: an unsigned token's expiry is
    # whatever the sender chose, and calling that "expired" would report a
    # forgery as bad timing.
    if not hmac.compare_digest(signature, _signature(f"{encoded}.{expiry}")):
        raise BadToken(
            "this upload link was not issued by this server, or the server has "
            "restarted since issuing it; ask for a new one"
        )
    if (time.time() if now is None else now) > int(expiry):
        raise BadToken("this upload link has expired; ask for a new one")
    return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()


async def receive(token: str, picture: bytes) -> tuple[int, dict[str, Any]]:
    """Store `picture` as the title picture of whichever recipe `token` names.

    `cook server`'s refusals pass through unchanged: it is the one that decodes
    the picture, and its messages name the format and say what to do about it —
    the HEIC an iPhone saves above all.
    """
    try:
        path = verify(token)
    except BadToken as err:
        return 403, {"error": str(err)}

    status, body = await cook.put_recipe_image(path, picture)
    if status >= 400:
        return status, body

    # An `image` line in the frontmatter wins over a stored file, so the upload
    # can succeed and show on nothing. Only the recipe's own text fixes that.
    warnings = []
    if body.get("source") == "metadata":
        warnings.append(
            "This recipe's `image` frontmatter names a picture, and that wins "
            "over a stored file: the page still shows the linked one. Remove "
            "the `image` line with `recipe_write` for this upload to show."
        )
    return status, {
        "path": path,
        "stored": True,
        "source": body.get("source"),
        "warnings": warnings,
    }
