"""A lapsed Claude sign-in: noticed, said out loud, signed in again, and carried on.

The fake Claude plays an OAuth session that can't be refreshed (FAKE_CLAUDE_AUTH)
and a `claude auth login` that the user finishes after a moment.
"""

import asyncio
import time

import pytest
from test_ipc import Host

from friday_engine import agent, auth, config
from friday_engine.auth import AuthGuard, SignedOut, check, is_auth_error
from friday_engine.brain import Brain
from friday_engine.ipc import hub


@pytest.fixture
def sign_in(tmp_path, monkeypatch):
    """Control the fake Claude's sign-in, and count the sign-in pages opened."""

    class SignIn:
        state_file = tmp_path / "auth"
        logins_file = tmp_path / "logins"

        def set(self, state):
            self.state_file.write_text(state)

        @property
        def state(self):
            return self.state_file.read_text().strip() if self.state_file.exists() else "ok"

        @property
        def pages_opened(self):
            return len(self.logins_file.read_text().splitlines()) if self.logins_file.exists() else 0

        def env(self):
            return {"FAKE_CLAUDE_AUTH": str(self.state_file),
                    "FAKE_CLAUDE_LOGINS": str(self.logins_file)}

    s = SignIn()
    for name, value in s.env().items():
        monkeypatch.setenv(name, value)
    monkeypatch.setenv("FAKE_CLAUDE_LOGIN_SECS", "0.3")
    monkeypatch.setattr(config, "AUTH_RETRY_SECS", 0.1)
    monkeypatch.setattr(config, "WORKDIR", tmp_path)
    return s


@pytest.fixture
def events(monkeypatch):
    seen = []
    monkeypatch.setattr(hub, "emit", lambda kind, **f: seen.append((kind, f)))
    return seen


async def until(condition, timeout=5.0):
    deadline = time.time() + timeout
    while not condition():
        if time.time() > deadline:
            raise TimeoutError("condition never held")
        await asyncio.sleep(0.02)


def test_recognises_the_sign_in_errors_claude_gives():
    assert is_auth_error("Failed to authenticate: OAuth session expired and could not be refreshed")
    assert is_auth_error("Invalid API key · Please run /login")
    assert is_auth_error("Not logged in · Please run /login")
    assert is_auth_error('API Error: 401 {"type":"authentication_error"}')
    assert not is_auth_error("API Error: 529 overloaded")
    assert not is_auth_error("")


async def test_check_tells_ok_expired_and_signed_out_apart(sign_in):
    assert await check() == "ok"
    sign_in.set("expired")  # still "logged in", but requests fail
    assert await check() == "signed_out"
    sign_in.set("signed_out")
    assert await check() == "signed_out"


async def test_check_is_unknown_without_claude(monkeypatch):
    monkeypatch.setattr(config, "find_claude", lambda: "")
    assert await check() == "unknown"


async def test_brain_raises_signed_out_instead_of_a_vague_error(sign_in):
    brain = Brain()
    try:
        sign_in.set("expired")
        with pytest.raises(SignedOut):
            await brain.ask("hello")
        sign_in.set("ok")
        assert await brain.ask("hello") == "You said: hello (turn 2)"
        with pytest.raises(SignedOut):
            await brain.ask("authdie now")  # a process that dies signed out
    finally:
        await brain.close()


async def test_a_process_that_has_answered_gets_one_fresh_try(sign_in):
    """A long-lived process may hold a stale sign-in; a new one reads the current one."""
    brain = Brain()
    try:
        assert await brain.ask("hello") == "You said: hello (turn 1)"
        old = brain._proc.pid
        sign_in.set("expired")
        with pytest.raises(SignedOut):
            await brain.ask("again")
        assert brain._proc.pid != old  # it was retried on a fresh process
    finally:
        await brain.close()


@pytest.fixture
async def friday(sign_in, events):
    """The voice loop's request handling with a real brain, outside a pipeline."""
    brain = Brain()
    proc = agent.VoiceCommandProcessor(brain)
    proc.said = []

    async def say(text, final=False):
        proc._spoken.append((time.time(), text))
        proc._last_said_at = time.time()
        proc.said.append(text)

    async def interrupt():
        pass

    async def cancel_task(task):
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    proc._say = say
    proc._interrupt_speech = interrupt
    proc.create_task = lambda coro: asyncio.get_running_loop().create_task(coro)
    proc.cancel_task = cancel_task
    yield proc
    await proc.auth.close()
    await brain.close()


async def test_a_failed_request_is_explained_signed_in_and_run_again(friday, sign_in, events):
    sign_in.set("expired")
    await friday.ask({"text": "open Muse"})
    await until(lambda: auth.NEED_SIGN_IN in friday.said)
    assert ("warning", {"code": "claude_auth"}) in events
    await until(lambda: sign_in.pages_opened == 1)
    # The user finishes signing in in the browser; Friday notices and carries on.
    await until(lambda: any(s.startswith("You said: open Muse") for s in friday.said))
    assert friday.said == [auth.NEED_SIGN_IN, auth.SIGNED_IN_RESUMING, "You said: open Muse (turn 2)"]  # same process: memory kept
    assert ("resolved", {"code": "claude_auth"}) in events
    assert not friday.auth.signed_out


async def test_asking_again_while_signed_out_says_so_without_a_second_page(
    friday, sign_in, events, monkeypatch
):
    monkeypatch.setenv("FAKE_CLAUDE_LOGIN_SECS", "never")
    monkeypatch.setattr(config, "AUTH_RETRY_SECS", 5)
    sign_in.set("expired")
    await friday.ask({"text": "first"})
    await until(lambda: auth.NEED_SIGN_IN in friday.said)
    await friday.ask({"text": "second"})
    await until(lambda: auth.STILL_OPEN in friday.said)
    await until(lambda: sign_in.pages_opened == 1)
    assert friday.auth._pending == "second"  # the latest request is the one run later
    # Long enough later, asking again brings the page up afresh.
    monkeypatch.setattr(config, "AUTH_REOPEN_SECS", 0)
    await friday.ask({"text": "third"})
    await until(lambda: auth.STILL_REOPENED in friday.said)
    await until(lambda: sign_in.pages_opened == 2)


async def test_the_regular_check_warns_before_anything_is_asked(friday, sign_in, events):
    sign_in.set("expired")
    watcher = asyncio.create_task(friday.auth.watch())
    try:
        await until(lambda: auth.HEADS_UP in friday.said)
        await until(lambda: sign_in.pages_opened == 1)
        await until(lambda: auth.SIGNED_IN in friday.said)
        assert ("resolved", {"code": "claude_auth"}) in events
    finally:
        watcher.cancel()


async def test_paused_friday_warns_the_app_but_stays_quiet(friday, sign_in, events, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_LOGIN_SECS", "never")
    sign_in.set("expired")
    await friday.pause()
    watcher = asyncio.create_task(friday.auth.watch())
    try:
        await until(lambda: ("warning", {"code": "claude_auth"}) in events)
        await asyncio.sleep(0.3)
        assert friday.said == []
        assert sign_in.pages_opened == 0  # no browser opened at someone not using Friday
    finally:
        watcher.cancel()


async def test_the_app_can_ask_for_the_page_again(sign_in, events, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_LOGIN_SECS", "never")
    monkeypatch.setattr(config, "AUTH_REOPEN_SECS", 0)

    async def nothing(*_):
        pass

    guard = AuthGuard(say=nothing, resume=nothing)
    try:
        await guard.ask_again()  # not signed out: nothing to do
        assert sign_in.pages_opened == 0
        sign_in.set("expired")
        await guard.lapsed("hello")
        await until(lambda: sign_in.pages_opened == 1)
        await guard.ask_again()
        await until(lambda: sign_in.pages_opened == 2)
    finally:
        await guard.close()


async def test_end_to_end_through_the_app_link(python, engine_env, sign_in, tmp_path):
    """The real engine process, as the desktop app runs it, with Claude signed out."""
    env = {**engine_env, **sign_in.env(), "FAKE_CLAUDE_LOGIN_SECS": "1",
           "AUTH_RETRY_SECS": "0.2"}
    sign_in.set("expired")
    async with Host(python, env) as host:
        # Found at start-up, before anything is asked.
        await host.until(lambda e: e["type"] == "warning" and e["code"] == "claude_auth")
        await host.until(lambda e: e["type"] == "reply" and e["text"] == auth.HEADS_UP)
        await host.until(lambda e: e["type"] == "resolved" and e["code"] == "claude_auth")
        await host.until(lambda e: e["type"] == "reply" and e["text"] == auth.SIGNED_IN)
        assert sign_in.pages_opened == 1

        # Lapses again mid-conversation: the request is explained, then answered.
        sign_in.set("expired")
        host.send("ask", text="hello")
        await host.until(lambda e: e["type"] == "reply" and e["text"] == auth.NEED_SIGN_IN)
        await host.until(lambda e: e["type"] == "resolved")
        await host.until(lambda e: e["type"] == "reply" and e["text"] == auth.SIGNED_IN_RESUMING)
        reply = await host.until(lambda e: e["type"] == "reply" and e["final"]
                                 and e["text"].startswith("You said: hello"))
        assert reply
        assert sign_in.pages_opened == 2
        host.send("shutdown")


async def test_after_giving_up_the_regular_check_still_notices_a_sign_in(sign_in, events):
    """Signed in some other way (a terminal) long after Friday stopped waiting."""
    said, resumed = [], []

    async def say(text):
        said.append(text)

    async def resume(request):
        resumed.append(request)

    guard = AuthGuard(say=say, resume=resume)
    guard.signed_out = True  # and no sign-in being waited for any more
    watcher = asyncio.create_task(guard.watch())
    try:
        await until(lambda: resumed == [None])
        assert not guard.signed_out
        assert ("resolved", {"code": "claude_auth"}) in events
    finally:
        watcher.cancel()
        await guard.close()
