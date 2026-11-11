"""The link to the desktop app, end to end: a test host starts the real engine process."""

import asyncio
import json
import os
import secrets
import struct
import tempfile

import pytest

from friday_engine import ipc


class Host:
    """What the desktop app does: listen, start the engine, check the token, configure."""

    def __init__(self, python, env, settings=None, token=None):
        self.python, self.env, self.settings = python, env, settings or {}
        self.token = token or secrets.token_hex(16)
        self.events: list[dict] = []
        self._connected = asyncio.Event()

    async def __aenter__(self):
        # Unix socket paths are limited to ~100 bytes, so not pytest's tmp_path.
        self._dir = tempfile.TemporaryDirectory(dir="/tmp", prefix="fri-")
        self.path = os.path.join(self._dir.name, "friday.sock")
        self._server = await asyncio.start_unix_server(self._on_connect, self.path)
        os.chmod(self.path, 0o600)
        self.proc = await asyncio.create_subprocess_exec(
            self.python, "-m", "friday_engine",
            env={**self.env, "FRIDAY_SOCKET": self.path, "FRIDAY_TOKEN": self.token},
            stdin=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        await asyncio.wait_for(self._connected.wait(), 8)
        return self

    async def __aexit__(self, *exc):
        try:  # an engine that was refused exits on its own
            await asyncio.wait_for(self.proc.wait(), 1)
        except TimeoutError:
            self.proc.kill()
            await self.proc.wait()
        self._server.close()
        self._dir.cleanup()

    async def _on_connect(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.hello = json.loads(await reader.readline())
        if self.hello.get("token") != self.token:
            writer.close()
            return
        self.send("configure", settings=self.settings)
        self._connected.set()

    def send(self, kind, **fields):
        self.writer.write((json.dumps({"v": 1, "type": kind, **fields}) + "\n").encode())

    async def until(self, match, timeout=20):
        """Read events until one satisfies `match`; return it."""

        async def read():
            while True:
                line = await self.reader.readline()
                if not line:
                    raise ConnectionError("engine closed the socket")
                event = json.loads(line)
                self.events.append(event)
                if match(event):
                    return event

        return await asyncio.wait_for(read(), timeout)

    def state(self, name):
        return self.until(lambda e: e["type"] == "state" and e["state"] == name)


async def test_handshake_configure_ask_and_reply(claude_log, python, engine_env):
    settings = {"ELEVENLABS_API_KEY": "el-secret-from-keychain", "USER_NAME": "Tester"}
    async with Host(python, engine_env, settings) as host:
        assert host.hello["v"] == 1 and host.hello["type"] == "hello"
        assert host.hello["pid"] == host.proc.pid
        await host.state("listening")
        assert [e["state"] for e in host.events if e["type"] == "state"][:2] == [
            "starting", "warming_claude"]

        host.send("ask", text="tool please")
        final = await host.until(lambda e: e["type"] == "reply" and e["final"])
        assert final["text"] == "All good, see the page."
        kinds = [(e["type"], e.get("text") or e.get("state")) for e in host.events]
        assert ("heard", "tool please") in kinds
        assert ("state", "thinking") in kinds
        assert ("reply", "Let me check that.") in kinds
        await host.state("listening")

        # The key the app sent is Friday's, and is not handed on to Claude.
        assert "ELEVENLABS_API_KEY" not in claude_log()["env"]
        assert "FRIDAY_TOKEN" not in claude_log()["env"]


async def test_pause_resume_and_interrupt(python, engine_env):
    async with Host(python, engine_env) as host:
        await host.state("listening")
        host.send("ask", text="slow job")
        await host.state("thinking")
        host.send("interrupt")
        await host.state("listening")
        host.send("pause")
        await host.state("paused")
        host.send("ask", text="ignored while paused")
        host.send("resume")
        await host.state("listening")
        host.send("ask", text="hello")
        final = await host.until(lambda e: e["type"] == "reply" and e["final"])
        assert final["text"].startswith("You said: hello")
        assert not any(e.get("text") == "ignored while paused" for e in host.events)


async def test_heartbeat(python, engine_env):
    async with Host(python, engine_env) as host:
        first = await host.until(lambda e: e["type"] == "heartbeat", timeout=10)
        second = await host.until(lambda e: e["type"] == "heartbeat", timeout=5)
        assert 1.5 < second["t"] - first["t"] < 3.5


async def test_engine_exits_when_the_app_goes_away(python, engine_env):
    async with Host(python, engine_env) as host:
        await host.state("listening")
        host.writer.close()  # the app quit or crashed
        assert await asyncio.wait_for(host.proc.wait(), 10) == 0


async def test_shutdown_message(python, engine_env):
    async with Host(python, engine_env) as host:
        await host.state("listening")
        host.send("shutdown")
        assert await asyncio.wait_for(host.proc.wait(), 10) == 0


async def test_engine_that_is_refused_never_starts(python, engine_env):
    """An engine the app hangs up on (wrong token) gets no settings and gives up."""
    host = Host(python, engine_env)

    async def refuse(reader, writer):
        await reader.readline()
        writer.close()

    host._on_connect = refuse
    with pytest.raises(asyncio.TimeoutError):
        async with host:
            pass
    assert host.proc.returncode not in (None, 0)


def test_levels():
    def tone(amplitude, n=1600):
        return struct.pack(f"<{n}h", *([amplitude, -amplitude] * (n // 2)))

    assert ipc.level_of(b"") == 0.0
    assert ipc.level_of(tone(0)) == 0.0
    assert ipc.level_of(tone(32767)) == pytest.approx(1.0, abs=0.01)
    quiet, normal = ipc.level_of(tone(100)), ipc.level_of(tone(3000))
    assert 0.0 < quiet < normal < 1.0


def test_emit_without_an_app_does_nothing():
    ipc.Hub().emit("state", state="listening")  # must not raise


def test_settings_from_the_app_are_marked_as_fridays(monkeypatch):
    monkeypatch.delenv("FRIDAY_HOST_KEYS", raising=False)
    ipc.apply_settings({"ELEVENLABS_API_KEY": "k", "WAKE_WORD": "friday"})
    assert os.environ["FRIDAY_HOST_KEYS"] == "ELEVENLABS_API_KEY,WAKE_WORD"
    monkeypatch.delenv("ELEVENLABS_API_KEY")
    monkeypatch.delenv("WAKE_WORD")
    monkeypatch.delenv("FRIDAY_HOST_KEYS")
