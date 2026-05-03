"""
Configuration loader — reads settings.json from a local path or HTTPS URL.
"""

import json
import asyncio
import logging

logger = logging.getLogger(__name__)

REQUIRED_KEYS = ["livekit_url", "room_name", "socks_port"]


def load_config(path_or_url: str) -> dict:
    """Load and validate config from a local file or an HTTPS URL."""
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        return asyncio.run(_fetch_config(path_or_url))
    with open(path_or_url) as f:
        cfg = json.load(f)
    _validate(cfg)
    return cfg


async def _fetch_config(url: str) -> dict:
    try:
        import aiohttp
    except ImportError:
        raise ImportError("aiohttp is required to fetch remote configs: pip install aiohttp")
    async with aiohttp.ClientSession() as session:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=15)) as r:
            r.raise_for_status()
            cfg = await r.json(content_type=None)
    _validate(cfg)
    return cfg


def _validate(cfg: dict):
    missing = [k for k in REQUIRED_KEYS if k not in cfg]
    if missing:
        raise ValueError(f"Config is missing required keys: {missing}")
