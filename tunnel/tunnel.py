#!/usr/bin/env python3
"""
Bale.ai / LiveKit WebRTC Tunnel
Usage:
    python tunnel.py entry --config settings.json
    python tunnel.py exit   --config settings.json
    python tunnel.py entry --config https://raw.githubusercontent.com/.../settings.json
"""

import argparse
import asyncio
import logging
import sys


def main():
    parser = argparse.ArgumentParser(
        prog="tunnel",
        description="WebRTC censorship-bypass tunnel over Bale.ai / LiveKit",
    )
    parser.add_argument(
        "mode",
        choices=["entry", "exit"],
        help="'entry' = Iran side (SOCKS5 proxy), 'exit' = free-internet side (TCP forwarder)",
    )
    parser.add_argument(
        "--config",
        required=True,
        help="Path to settings.json or an HTTPS URL pointing to one",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity (default: INFO)",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        stream=sys.stderr,
    )

    # Import after logging is configured so module-level loggers pick up the level.
    from .config import load_config

    try:
        cfg = load_config(args.config)
    except Exception as e:
        logging.critical("Failed to load config: %s", e)
        sys.exit(1)

    if args.mode == "entry":
        from .entry import run_entry
        coro = run_entry(cfg)
    else:
        from .exit_node import run_exit
        coro = run_exit(cfg)

    try:
        asyncio.run(coro)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
