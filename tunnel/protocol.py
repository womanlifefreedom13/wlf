"""
Frame encoding/decoding for the tunnel multiplexing protocol.

Frame format:
    [stream_id: 4B LE][msg_type: 1B][payload_len: 4B LE][payload: N bytes]

Each LiveKit publishData call carries exactly one frame (atomic delivery).
"""

import struct

HEADER_SIZE = 9          # 4 + 1 + 4
MAX_PAYLOAD = 8192

MSG_CONNECT   = 0x01
MSG_DATA      = 0x02
MSG_CLOSE     = 0x03
MSG_CONNECTED = 0x04


def encode_frame(stream_id: int, msg_type: int, payload: bytes) -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"Payload too large: {len(payload)} > {MAX_PAYLOAD}")
    return struct.pack("<IBI", stream_id, msg_type, len(payload)) + payload


def decode_frame(data: bytes) -> tuple:
    """Returns (stream_id, msg_type, payload). Raises ValueError on malformed input."""
    if len(data) < HEADER_SIZE:
        raise ValueError(f"Frame too short: {len(data)} bytes")
    stream_id, msg_type, payload_len = struct.unpack_from("<IBI", data, 0)
    expected = HEADER_SIZE + payload_len
    if len(data) != expected:
        raise ValueError(f"Frame length mismatch: expected {expected}, got {len(data)}")
    return stream_id, msg_type, data[HEADER_SIZE:]


def encode_connect(stream_id: int, host: str, port: int) -> bytes:
    """CONNECT: 1B host_len + host bytes + 2B port (big-endian)."""
    host_b = host.encode()
    payload = bytes([len(host_b)]) + host_b + struct.pack(">H", port)
    return encode_frame(stream_id, MSG_CONNECT, payload)


def decode_connect(payload: bytes) -> tuple:
    """Returns (host, port) from a CONNECT payload."""
    host_len = payload[0]
    host = payload[1:1 + host_len].decode()
    port = struct.unpack_from(">H", payload, 1 + host_len)[0]
    return host, port


def encode_connected(stream_id: int, ok: bool) -> bytes:
    """CONNECTED: 1B status (0=success, 1=failure)."""
    return encode_frame(stream_id, MSG_CONNECTED, bytes([0 if ok else 1]))


def encode_data(stream_id: int, chunk: bytes) -> bytes:
    """DATA: raw bytes (must be <= MAX_PAYLOAD)."""
    return encode_frame(stream_id, MSG_DATA, chunk)


def encode_close(stream_id: int) -> bytes:
    """CLOSE: empty payload."""
    return encode_frame(stream_id, MSG_CLOSE, b"")
