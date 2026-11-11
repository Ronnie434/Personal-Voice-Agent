"""The link to the desktop app: JSON lines over a Unix socket (protocol v1).

The app listens on a socket and starts the engine with FRIDAY_SOCKET and
FRIDAY_TOKEN set. The engine connects, says `hello` with the token, and gets a
`configure` message back with its settings. After that the engine sends events
(`state`, `levels`, `heard`, `reply`, `warning`, `heartbeat`) and the app sends
commands (`pause`, `resume`, `interrupt`, `ask`, `shutdown`).

Without FRIDAY_SOCKET nothing here does anything: `uv run agent.py` works with
no app at all, and every `hub.emit` is a no-op.

Full message list: docs/protocol.md.
"""

import asyncio
import json
import math
import os
import socket
import struct
import time
from collections.abc import Awaitable, Callable

from loguru import logger

from . import __version__

PROTOCOL = 1
HEARTBEAT_SECS = 2.0
LEVELS_HZ = 20
MAX_LINE = 1024 * 1024

Handler = Callable[[dict], Awaitable[None]]


def handshake(path: str, token: str, timeout: float = 5.0) -> tuple[socket.socket, dict]:
    """Connect to the app and return the socket and the settings it sent.

    Blocking, and run before the rest of the engine is imported, because the
    settings arrive as environment-style names that config.py reads on import.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(path)
    hello = {"v": PROTOCOL, "type": "hello", "token": token, "pid": os.getpid(),
             "engine": __version__}
    sock.sendall((json.dumps(hello) + "\n").encode())
    line = b""
    while not line.endswith(b"\n"):
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("the app closed the socket during the handshake")
        line += chunk
        if len(line) > MAX_LINE:
            raise ConnectionError("handshake reply too long")
    message = json.loads(line)
    if message.get("type") != "configure" or message.get("v") != PROTOCOL:
        raise ConnectionError(f"expected configure v{PROTOCOL}, got {message.get('type')!r}")
    sock.settimeout(None)
    return sock, dict(message.get("settings") or {})


def apply_settings(settings: dict) -> None:
    """Put the app's settings where config.py will find them.

    They are also recorded as Friday's own, so none of them (the ElevenLabs
    key in particular) is passed on to Claude.
    """
    for name, value in settings.items():
        os.environ[str(name)] = str(value)
    os.environ["FRIDAY_HOST_KEYS"] = ",".join(str(name) for name in settings)


def level_of(pcm: bytes) -> float:
    """Loudness of 16-bit mono PCM as 0..1, scaled so normal speech sits mid-range."""
    count = len(pcm) // 2
    if not count:
        return 0.0
    samples = struct.unpack(f"<{count}h", pcm[: count * 2])
    rms = math.sqrt(sum(s * s for s in samples) / count) / 32768.0
    if rms <= 0.0:
        return 0.0
    # -60 dB and below is 0, 0 dB is 1.
    return max(0.0, min(1.0, 1.0 + 20.0 * math.log10(rms) / 60.0))


class Hub:
    """Sends events to the app and hands its commands to whoever registered for them."""

    def __init__(self):
        self._writer: asyncio.StreamWriter | None = None
        self._reader: asyncio.StreamReader | None = None
        self._handlers: dict[str, Handler] = {}
        self._tasks: list[asyncio.Task] = []
        self._levels = {"mic": 0.0, "out": 0.0}
        self._levels_sent = {"mic": 0.0, "out": 0.0}
        self._last: dict[str, dict] = {}  # latest state, for late handlers and tests
        self._on_disconnect: Callable[[], Awaitable[None]] | None = None
        self.disconnected = False  # the app went away (set once, never cleared)

    @property
    def on_disconnect(self) -> Callable[[], Awaitable[None]] | None:
        return self._on_disconnect

    @on_disconnect.setter
    def on_disconnect(self, handler: Callable[[], Awaitable[None]] | None) -> None:
        """What to do when the app goes away.

        If it already has (it quit while the engine was still starting), the
        handler runs straight away, so a late-registered shutdown is never missed.
        """
        self._on_disconnect = handler
        if handler is not None and self.disconnected:
            asyncio.get_running_loop().create_task(handler())

    @property
    def connected(self) -> bool:
        return self._writer is not None and not self._writer.is_closing()

    async def attach(self, sock: socket.socket) -> None:
        """Take over a socket that has already been through `handshake`."""
        self._reader, self._writer = await asyncio.open_unix_connection(sock=sock, limit=MAX_LINE)
        self._tasks = [
            asyncio.create_task(self._read()),
            asyncio.create_task(self._heartbeat()),
            asyncio.create_task(self._send_levels()),
        ]

    def on(self, kind: str, handler: Handler) -> None:
        self._handlers[kind] = handler

    def emit(self, kind: str, **fields) -> None:
        """Send one event. Never raises and never blocks: the app is optional."""
        if kind == "state":
            self._last["state"] = fields
        if not self.connected:
            return
        try:
            line = json.dumps({"v": PROTOCOL, "type": kind, **fields}, default=str)
            self._writer.write(line.encode() + b"\n")
        except Exception as e:  # a broken socket must not take the voice loop down
            logger.debug(f"Could not send {kind} to the app: {e}")

    def level(self, source: str, pcm: bytes) -> None:
        """Note how loud the mic ("mic") or Friday's voice ("out") is right now."""
        if self.connected:
            self._levels[source] = max(self._levels[source], level_of(pcm))

    async def close(self) -> None:
        for task in self._tasks:
            task.cancel()
        if self._writer:
            self._writer.close()
        self._writer = None

    async def _read(self):
        try:
            while True:
                line = await self._reader.readline()
                if not line:
                    break
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                handler = self._handlers.get(message.get("type"))
                if handler is None:
                    logger.debug(f"No handler for app message {message.get('type')!r}")
                    continue
                try:
                    await handler(message)
                except Exception as e:
                    logger.exception(e)
        except (ConnectionError, asyncio.IncompleteReadError, ValueError) as e:
            logger.warning(f"Lost the app: {e}")
        # The app is gone (quit or crashed). The engine must not outlive it
        # with an open microphone.
        logger.info("The app closed the connection")
        self._writer = None
        self.disconnected = True
        if self._on_disconnect:
            await self._on_disconnect()

    async def _heartbeat(self):
        while True:
            self.emit("heartbeat", t=round(time.time(), 3))
            await asyncio.sleep(HEARTBEAT_SECS)

    async def _send_levels(self):
        while True:
            await asyncio.sleep(1 / LEVELS_HZ)
            levels, self._levels = self._levels, {"mic": 0.0, "out": 0.0}
            # Silence is sent once, then nothing until there is sound again.
            if levels != self._levels_sent or any(levels.values()):
                self.emit("levels", mic=round(levels["mic"], 3), out=round(levels["out"], 3))
                self._levels_sent = levels


hub = Hub()
