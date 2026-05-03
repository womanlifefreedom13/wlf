"""
Exit node — free-internet side.

Joins the LiveKit room and listens for framed tunnel messages.
For each CONNECT frame: opens a real TCP connection to the target host.
Forwards DATA frames to the TCP socket and pumps responses back as DATA frames.
"""

import asyncio
import logging

from livekit import rtc

from .protocol import (
    MSG_CONNECT, MSG_DATA, MSG_CLOSE,
    decode_frame, decode_connect,
    encode_connected, encode_data, encode_close,
    MAX_PAYLOAD,
)
from .bale_token import get_token

logger = logging.getLogger(__name__)

# --- Task registry ---
_tasks: set = set()


def _spawn(coro):
    t = asyncio.create_task(coro)
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)
    return t


# --- Per-stream state ---
_tcp_writers: dict = {}   # stream_id -> asyncio.StreamWriter (to target)
_tcp_tasks: dict = {}     # stream_id -> asyncio.Task (pump task)

_room: rtc.Room | None = None
_cfg: dict = {}


# --- Stream cleanup helpers ---

def _cleanup_stream(stream_id: int):
    writer = _tcp_writers.pop(stream_id, None)
    if writer:
        try:
            writer.close()
        except Exception:
            pass
    task = _tcp_tasks.pop(stream_id, None)
    if task and not task.done():
        task.cancel()


def _cleanup_all_streams():
    for sid in list(_tcp_writers):
        _cleanup_stream(sid)


# --- TCP → DataChannel pump ---

async def _tcp_to_dc_pump(stream_id: int, reader: asyncio.StreamReader):
    """Read from target TCP socket and forward as DATA frames."""
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
        logger.debug("[%d] Target idle timeout", stream_id)
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        logger.debug("[%d] Target connection error: %s", stream_id, e)
    except Exception as e:
        logger.warning("[%d] Unexpected pump error: %s", stream_id, e)
    finally:
        _cleanup_stream(stream_id)
        try:
            await _room.local_participant.publish_data(
                payload=encode_close(stream_id),
                reliable=True,
            )
        except Exception:
            pass
        logger.debug("[%d] Pump ended, CLOSE sent", stream_id)


# --- Frame handlers (async, called via _spawn from sync callback) ---

async def _handle_connect(stream_id: int, host: str, port: int):
    logger.debug("[%d] CONNECT %s:%d", stream_id, host, port)
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=10.0,
        )
    except Exception as e:
        logger.warning("[%d] TCP connect to %s:%d failed: %s", stream_id, host, port, e)
        try:
            await _room.local_participant.publish_data(
                payload=encode_connected(stream_id, False),
                reliable=True,
            )
        except Exception:
            pass
        return

    _tcp_writers[stream_id] = writer
    task = _spawn(_tcp_to_dc_pump(stream_id, reader))
    _tcp_tasks[stream_id] = task

    try:
        await _room.local_participant.publish_data(
            payload=encode_connected(stream_id, True),
            reliable=True,
        )
    except Exception as e:
        logger.warning("[%d] publish_data(CONNECTED) failed: %s", stream_id, e)
        _cleanup_stream(stream_id)
        return

    logger.info("[%d] Tunnel open: %s:%d", stream_id, host, port)


async def _handle_data(stream_id: int, payload: bytes):
    writer = _tcp_writers.get(stream_id)
    if not writer:
        logger.debug("[%d] DATA for unknown stream, dropping", stream_id)
        return
    try:
        writer.write(payload)
        if writer.transport.get_write_buffer_size() > 65536:
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        logger.debug("[%d] Write to target failed: %s", stream_id, e)
        _cleanup_stream(stream_id)


async def _handle_close(stream_id: int):
    logger.debug("[%d] CLOSE received", stream_id)
    _cleanup_stream(stream_id)


# --- LiveKit data_received callback (must be synchronous) ---

def _on_data_received(packet: rtc.DataPacket):
    if packet.participant is None:
        return
    try:
        stream_id, msg_type, payload = decode_frame(packet.data)
    except ValueError as e:
        logger.warning("Malformed frame from %s: %s", packet.participant.identity, e)
        return

    if msg_type == MSG_CONNECT:
        try:
            host, port = decode_connect(payload)
        except Exception as e:
            logger.warning("[%d] Bad CONNECT payload: %s", stream_id, e)
            return
        _spawn(_handle_connect(stream_id, host, port))

    elif msg_type == MSG_DATA:
        _spawn(_handle_data(stream_id, payload))

    elif msg_type == MSG_CLOSE:
        _spawn(_handle_close(stream_id))


# --- Reconnect logic ---

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
    token = await get_token(_cfg, "exit")
    await _connect_with_backoff(_room, _cfg["livekit_url"], token)


# --- Public entry point ---

async def run_exit(cfg: dict):
    global _room, _cfg
    _cfg = cfg

    token = await get_token(cfg, "exit")

    _room = rtc.Room()
    _room.on("data_received", _on_data_received)
    _room.on("disconnected", lambda reason: _spawn(_on_disconnect(reason)))

    await _connect_with_backoff(_room, cfg["livekit_url"], token)
    logger.info("Exit node ready — waiting for tunneled connections")

    # Keep alive; all work is event-driven via callbacks and tasks.
    stop_event = asyncio.Event()
    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass
    finally:
        _cleanup_all_streams()
        await _room.disconnect()
