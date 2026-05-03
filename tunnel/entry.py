"""
Entry node — Iran side.

Starts a SOCKS5 server on socks_host:socks_port.
Each TCP connection is multiplexed over a LiveKit DataChannel as framed messages.
"""

import asyncio
import itertools
import logging
import socket
import struct

from livekit import rtc

from .protocol import (
    MSG_CONNECTED, MSG_DATA, MSG_CLOSE,
    encode_connect, encode_data, encode_close,
    decode_frame, MAX_PAYLOAD,
)
from .bale_token import get_token

logger = logging.getLogger(__name__)

# --- Task registry (prevents GC of fire-and-forget tasks) ---
_tasks: set = set()


def _spawn(coro):
    t = asyncio.create_task(coro)
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)
    return t


# --- Per-connection state ---
_streams: dict = {}          # stream_id -> asyncio.StreamWriter (SOCKS client)
_pending: dict = {}          # stream_id -> asyncio.Future (resolved by CONNECTED frame)
_stream_id_counter = itertools.count(1)

# Module-level room reference (replaced on reconnect)
_room: rtc.Room | None = None
_cfg: dict = {}


def _next_stream_id() -> int:
    sid = next(_stream_id_counter)
    return sid & 0xFFFFFFFF  # clamp to uint32


# --- LiveKit data_received callback (must be synchronous) ---

def _on_data_received(packet: rtc.DataPacket):
    if packet.participant is None:
        # Ignore loopback (shouldn't happen but be defensive)
        return
    try:
        stream_id, msg_type, payload = decode_frame(packet.data)
    except ValueError as e:
        logger.warning("Malformed frame from %s: %s", packet.participant.identity, e)
        return

    if msg_type == MSG_CONNECTED:
        fut = _pending.pop(stream_id, None)
        if fut and not fut.done():
            fut.set_result(payload[0] == 0)

    elif msg_type == MSG_DATA:
        writer = _streams.get(stream_id)
        if writer:
            _spawn(_write_to_client(writer, payload, stream_id))

    elif msg_type == MSG_CLOSE:
        writer = _streams.pop(stream_id, None)
        if writer:
            _spawn(_close_writer(writer))


async def _write_to_client(writer: asyncio.StreamWriter, data: bytes, stream_id: int):
    try:
        writer.write(data)
        if writer.transport.get_write_buffer_size() > 65536:
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError):
        _streams.pop(stream_id, None)


async def _close_writer(writer: asyncio.StreamWriter):
    try:
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass


# --- SOCKS5 handshake ---

async def _socks5_negotiate(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Handle SOCKS5 method negotiation — accept no-auth only."""
    header = await reader.readexactly(2)
    if header[0] != 0x05:
        raise ValueError(f"Not SOCKS5 (ver={header[0]:#x})")
    n_methods = header[1]
    methods = await reader.readexactly(n_methods)
    if 0x00 not in methods:
        writer.write(b"\x05\xFF")  # no acceptable method
        await writer.drain()
        raise ValueError("Client does not support no-auth SOCKS5")
    writer.write(b"\x05\x00")
    await writer.drain()


async def _socks5_read_request(reader: asyncio.StreamReader) -> tuple:
    """Parse SOCKS5 CONNECT request. Returns (host, port)."""
    hdr = await reader.readexactly(4)
    ver, cmd, _rsv, atyp = hdr
    if ver != 0x05:
        raise ValueError(f"Unexpected SOCKS version in request: {ver}")
    if cmd != 0x01:
        raise ValueError(f"Only CONNECT (0x01) supported, got {cmd:#x}")

    if atyp == 0x01:        # IPv4
        addr_b = await reader.readexactly(4)
        host = socket.inet_ntop(socket.AF_INET, addr_b)
    elif atyp == 0x03:      # domain name
        n = (await reader.readexactly(1))[0]
        host = (await reader.readexactly(n)).decode()
    elif atyp == 0x04:      # IPv6
        addr_b = await reader.readexactly(16)
        host = socket.inet_ntop(socket.AF_INET6, addr_b)
    else:
        raise ValueError(f"Unknown ATYP: {atyp:#x}")

    port_b = await reader.readexactly(2)
    port = struct.unpack(">H", port_b)[0]
    return host, port


_SOCKS5_SUCCESS  = b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00"
_SOCKS5_REFUSED  = b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00"
_SOCKS5_UNREACH  = b"\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00"


# --- Per-connection handler ---

async def _handle_socks_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        await _socks5_negotiate(reader, writer)
        host, port = await _socks5_read_request(reader)
    except Exception as e:
        logger.debug("SOCKS5 handshake failed from %s: %s", peer, e)
        writer.close()
        return

    stream_id = _next_stream_id()
    logger.debug("[%d] CONNECT %s:%d", stream_id, host, port)

    loop = asyncio.get_event_loop()
    fut: asyncio.Future = loop.create_future()
    _pending[stream_id] = fut
    _streams[stream_id] = writer

    # Send CONNECT frame to exit node
    try:
        await _room.local_participant.publish_data(
            payload=encode_connect(stream_id, host, port),
            reliable=True,
        )
    except Exception as e:
        logger.warning("[%d] publish_data(CONNECT) failed: %s", stream_id, e)
        _pending.pop(stream_id, None)
        _streams.pop(stream_id, None)
        writer.write(_SOCKS5_UNREACH)
        await writer.drain()
        writer.close()
        return

    # Wait for exit node to confirm the TCP connection
    try:
        ok = await asyncio.wait_for(fut, timeout=15.0)
    except asyncio.TimeoutError:
        logger.warning("[%d] Timeout waiting for CONNECTED", stream_id)
        _streams.pop(stream_id, None)
        writer.write(_SOCKS5_UNREACH)
        await writer.drain()
        writer.close()
        return

    if not ok:
        logger.debug("[%d] Exit node refused connection to %s:%d", stream_id, host, port)
        _streams.pop(stream_id, None)
        writer.write(_SOCKS5_REFUSED)
        await writer.drain()
        writer.close()
        return

    # Tell SOCKS client the connection succeeded
    writer.write(_SOCKS5_SUCCESS)
    await writer.drain()
    logger.info("[%d] Tunnel open: %s:%d", stream_id, host, port)

    # Forward client → DataChannel until EOF or error
    try:
        while True:
            chunk = await asyncio.wait_for(reader.read(MAX_PAYLOAD), timeout=300.0)
            if not chunk:
                break
            await _room.local_participant.publish_data(
                payload=encode_data(stream_id, chunk),
                reliable=True,
            )
    except asyncio.TimeoutError:
        logger.debug("[%d] Client idle timeout", stream_id)
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        logger.debug("[%d] Client connection error: %s", stream_id, e)
    except Exception as e:
        logger.warning("[%d] Unexpected error in client read loop: %s", stream_id, e)
    finally:
        _streams.pop(stream_id, None)
        try:
            await _room.local_participant.publish_data(
                payload=encode_close(stream_id),
                reliable=True,
            )
        except Exception:
            pass
        logger.debug("[%d] Tunnel closed", stream_id)
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


# --- Reconnect logic ---

def _cleanup_all_streams():
    """Cancel all pending futures and close all writers on disconnect."""
    for fut in _pending.values():
        if not fut.done():
            fut.cancel()
    _pending.clear()
    for writer in _streams.values():
        try:
            writer.close()
        except Exception:
            pass
    _streams.clear()


async def _connect_with_backoff(room: rtc.Room, url: str, token: str):
    delay = 2.0
    while True:
        try:
            await room.connect(url, token, options=rtc.RoomOptions(auto_subscribe=True))
            logger.info("Connected to LiveKit room: %s", url)
            return
        except Exception as e:
            logger.warning("LiveKit connect failed (%s), retrying in %.0fs", e, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60.0)


async def _on_disconnect(reason):
    global _room
    logger.warning("LiveKit disconnected (reason=%s), reconnecting...", reason)
    _cleanup_all_streams()
    token = await get_token(_cfg, "entry")
    await _connect_with_backoff(_room, _cfg["livekit_url"], token)


# --- Public entry point ---

async def run_entry(cfg: dict):
    global _room, _cfg
    _cfg = cfg

    token = await get_token(cfg, "entry")

    _room = rtc.Room()
    _room.on("data_received", _on_data_received)
    _room.on("disconnected", lambda reason: _spawn(_on_disconnect(reason)))

    await _connect_with_backoff(_room, cfg["livekit_url"], token)

    socks_host = cfg.get("socks_host", "127.0.0.1")
    socks_port = int(cfg["socks_port"])

    server = await asyncio.start_server(_handle_socks_client, socks_host, socks_port)
    logger.info("SOCKS5 proxy listening on %s:%d", socks_host, socks_port)

    async with server:
        await server.serve_forever()
