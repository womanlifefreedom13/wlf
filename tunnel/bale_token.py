"""
LiveKit token helper.

Supports two modes (set via cfg["token_mode"]):
  "preset"    — use pre-configured tokens from settings.json directly
  "bale_api"  — request a guest token from Bale.ai's meeting API
  "selfhost"  — generate a token locally using api_key + api_secret (self-hosted LiveKit)
"""

import asyncio
import logging

logger = logging.getLogger(__name__)


async def get_token(cfg: dict, role: str) -> str:
    """
    Return a LiveKit JWT for the given role ("entry" or "exit").

    role maps to cfg keys:
        entry -> cfg["entry_token"]
        exit  -> cfg["exit_token"]
    """
    mode = cfg.get("token_mode", "preset")

    if mode == "preset":
        key = f"{role}_token"
        token = cfg.get(key, "")
        if not token:
            raise ValueError(f"token_mode=preset but '{key}' is missing from config")
        return token

    if mode == "bale_api":
        return await _get_bale_guest_token(cfg, role)

    if mode == "selfhost":
        return _generate_selfhost_token(cfg, role)

    raise ValueError(f"Unknown token_mode: {mode!r}")


async def _get_bale_guest_token(cfg: dict, role: str) -> str:
    """
    Request a guest participant token from Bale.ai's meeting API.
    The room_name in cfg must be a valid Bale meeting ID.
    """
    try:
        import aiohttp
    except ImportError:
        raise ImportError("aiohttp required: pip install aiohttp")

    room_name = cfg["room_name"]
    identity = f"tunnel-{role}"

    # Bale.ai meeting guest token endpoint (discovered via their web client)
    # The room_name should be the numeric/alphanumeric meeting ID from a Bale meeting link.
    url = f"https://meet.bale.ai/api/join-room"
    payload = {
        "roomName": room_name,
        "identity": identity,
        "name": identity,
    }

    async with aiohttp.ClientSession() as session:
        async with session.post(url, json=payload,
                                timeout=aiohttp.ClientTimeout(total=15)) as r:
            if r.status != 200:
                body = await r.text()
                raise RuntimeError(
                    f"Bale API returned HTTP {r.status}: {body[:200]}"
                )
            data = await r.json(content_type=None)

    # The response shape mirrors LiveKit's standard token response
    token = data.get("token") or data.get("accessToken") or data.get("jwt")
    if not token:
        raise RuntimeError(f"Could not find token in Bale API response: {list(data.keys())}")

    logger.debug("Obtained Bale guest token for %s (role=%s)", room_name, role)
    return token


def _generate_selfhost_token(cfg: dict, role: str) -> str:
    """
    Generate a LiveKit JWT for a self-hosted server using api_key + api_secret.
    Requires: pip install livekit-api
    """
    try:
        from livekit.api import AccessToken, VideoGrants
    except ImportError:
        raise ImportError("livekit-api required for selfhost mode: pip install livekit-api")

    api_key = cfg.get("api_key")
    api_secret = cfg.get("api_secret")
    if not api_key or not api_secret:
        raise ValueError("token_mode=selfhost requires 'api_key' and 'api_secret' in config")

    room_name = cfg["room_name"]
    identity = f"tunnel-{role}"

    grants = VideoGrants(room_join=True, room=room_name)
    token = (
        AccessToken(api_key, api_secret)
        .with_identity(identity)
        .with_name(identity)
        .with_grants(grants)
        .to_jwt()
    )
    return token
