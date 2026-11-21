"""Claude's sign-in: noticing that it has lapsed, and getting the user signed in again.

The Claude CLI signs in with an OAuth session that can expire for good ("OAuth
session expired and could not be refreshed"). From then on every request fails
at once, so Friday hears the user and has nothing to say. `AuthGuard` turns
that into something the user can act on:

- it says out loud that Claude needs signing in again, and why;
- it starts `claude auth login`, which opens the sign-in page in the browser;
- it tells the desktop app (`warning claude_auth`), or shows a notification
  when there is no app;
- it checks every little while until the sign-in works, then says so, tells
  the app (`resolved claude_auth`) and runs the request that failed.

It also checks on its own, at start-up and every AUTH_CHECK_SECS, so a lapsed
sign-in is found before the user is mid-conversation.
"""

import asyncio
import json
import re
import subprocess
import time
from collections.abc import Awaitable, Callable

from loguru import logger

from . import config
from .ipc import hub

# What Claude says when the sign-in is the problem. Only ever matched against
# Claude's own error output (an error result, or what a dying process printed),
# never against an answer.
AUTH_ERROR_RE = re.compile(
    r"failed to authenticate|oauth (?:session|token)|not logged in|please run /login|"
    r"invalid api key|authentication_error|invalid x-api-key|token (?:has )?expired|"
    r"\b401\b",
    re.IGNORECASE,
)

# A request that is as cheap as a real one can be: the smallest model, no tools,
# no MCP servers, no hooks. Used to find out whether the sign-in still works.
PROBE_PROMPT = "Reply with the single word OK."

NEED_SIGN_IN = (
    "Claude needs you to sign in again for Friday to work. I've opened the sign-in "
    "page in your browser. Once you're signed in, I'll pick up where we left off."
)
HEADS_UP = (
    "Heads up, Claude needs you to sign in again for Friday to work. I've opened "
    "the sign-in page in your browser."
)
STILL_REOPENED = "I still need you to sign in to Claude. I've opened the sign-in page again."
STILL_OPEN = "I still need you to sign in to Claude. The sign-in page is open in your browser."
SIGNED_IN = "You're signed in to Claude again."
SIGNED_IN_RESUMING = "You're signed in to Claude again, so I'll pick up where we left off."

NOTIFY_TITLE = "Friday needs you to sign in to Claude"
NOTIFY_TEXT = "Claude's sign-in has expired. Finish signing in in your browser and Friday picks up again."


def is_auth_error(text: str) -> bool:
    return bool(text) and bool(AUTH_ERROR_RE.search(text))


class SignedOut(Exception):
    """Claude turned a request down because it needs signing in again."""


async def _run(args: list[str], timeout: float) -> tuple[int, str, str]:
    """Run a short Claude command; return its exit code, stdout and stderr."""
    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=config.WORKDIR,
        env=config.child_env(),
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except BaseException:  # a timeout, or the check itself being cancelled
        if proc.returncode is None:
            proc.kill()
            await proc.wait()
        raise
    return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace")


async def check() -> str:
    """Whether Claude is signed in: "ok", "signed_out", or "unknown".

    "unknown" (no network, Claude missing, a timeout) is never treated as signed
    out: telling the user to sign in when that won't help is worse than waiting
    for the next check.
    """
    claude = config.find_claude()
    if not claude:
        return "unknown"
    # Free and instant, and enough when there is no sign-in at all.
    try:
        code, out, _ = await _run([claude, "auth", "status", "--json"], 20)
        if json.loads(out or "{}").get("loggedIn") is False:
            return "signed_out"
    except (OSError, TimeoutError, ValueError, AttributeError) as e:
        logger.debug(f"Claude auth status failed: {e!r}")
    # A sign-in that is there but can no longer be refreshed only shows when a
    # request is made, so make the smallest one there is.
    try:
        code, out, err = await _run(
            [
                claude, "-p", PROBE_PROMPT,
                "--model", config.AUTH_PROBE_MODEL,
                "--tools", "",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--settings", json.dumps({"disableAllHooks": True}),
                "--output-format", "json",
            ],
            config.AUTH_PROBE_TIMEOUT_SECS,
        )
    except (OSError, TimeoutError) as e:
        logger.warning(f"Could not check Claude's sign-in: {e!r}")
        return "unknown"
    try:
        result = json.loads(out)
    except ValueError:
        result = None
    if isinstance(result, dict):
        if not result.get("is_error"):
            return "ok"
        if is_auth_error(str(result.get("result") or "")):
            return "signed_out"
    if is_auth_error(f"{out}\n{err}"):
        return "signed_out"
    logger.warning(f"Claude's sign-in check was inconclusive (exit code {code})")
    return "unknown"


def notify(title: str, text: str) -> None:
    """A macOS notification, for when Friday runs without the desktop app.

    The app shows its own (and a window), so this stays quiet when it is there.
    """
    if hub.connected:
        return
    script = f"display notification {json.dumps(text)} with title {json.dumps(title)}"
    try:
        subprocess.Popen(["osascript", "-e", script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        logger.debug(f"Could not show a notification: {e!r}")


class AuthGuard:
    """Gets Friday through a lapsed Claude sign-in.

    `say(text)` speaks (or shows) something to the user. `resume(request)` is
    awaited once the sign-in works again, with the request that failed (or
    None); it decides what to say and whether to run it. `busy()` and
    `paused()` let the regular check stay out of the way.
    """

    def __init__(
        self,
        say: Callable[[str], Awaitable[None]],
        resume: Callable[[str | None], Awaitable[None]],
        busy: Callable[[], bool] = lambda: False,
        paused: Callable[[], bool] = lambda: False,
    ):
        self._say, self._resume, self._busy, self._paused = say, resume, busy, paused
        self.signed_out = False
        self._pending: str | None = None
        self._pending_at = 0.0
        self._login: asyncio.subprocess.Process | None = None
        self._login_started = 0.0
        self._login_output: asyncio.Task | None = None
        self._recovery: asyncio.Task | None = None
        self._signed_in = asyncio.Event()

    # -- found out -------------------------------------------------------------

    async def lapsed(self, request: str | None = None) -> str:
        """Claude needs signing in: a request failed (`request`), or a check found it.

        Starts the sign-in, warns the app, and returns what to tell the user.
        """
        first = not self.signed_out
        self.signed_out = True
        self._signed_in.clear()
        if request:
            self._pending, self._pending_at = request, time.time()
        if first:
            logger.warning("Claude needs signing in again")
        hub.emit("warning", code="claude_auth")
        if first:
            notify(NOTIFY_TITLE, NOTIFY_TEXT)
        if self._recovery is None or self._recovery.done():
            self._recovery = asyncio.create_task(self._wait_for_sign_in())

        if request is None and self._paused():
            # Paused: don't open a browser at someone who isn't using Friday. The
            # app shows the warning, and the first request after resuming opens it.
            return ""
        reopened = await self.open_sign_in(force=not first)
        if request is None:
            return HEADS_UP
        if first:
            return NEED_SIGN_IN
        return STILL_REOPENED if reopened else STILL_OPEN

    # -- the sign-in page --------------------------------------------------------

    async def open_sign_in(self, force: bool = False, now: bool = False) -> bool:
        """Start `claude auth login`, which opens the sign-in page in the browser.

        One sign-in runs at a time. With `force` (asked again), a sign-in that
        has been open for a while is replaced, so the page comes up afresh;
        with `now`, however briefly it has been open. Returns whether a page
        was opened.
        """
        running = self._login is not None and self._login.returncode is None
        if running and not now and (
            not force or time.time() - self._login_started < config.AUTH_REOPEN_SECS
        ):
            return False
        await self._stop_login()
        claude = config.find_claude()
        if not claude:
            return False
        try:
            self._login = await asyncio.create_subprocess_exec(
                claude, "auth", "login",
                cwd=config.WORKDIR,
                env=config.child_env(),
                # No terminal: the page in the browser finishes the sign-in by itself.
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except OSError as e:
            logger.error(f"Could not start the Claude sign-in: {e!r}")
            return False
        self._login_started = time.time()
        self._login_output = asyncio.create_task(self._drain(self._login))
        logger.info("Opened the Claude sign-in page")
        return True

    @staticmethod
    async def _drain(proc):
        """Read the sign-in's output so it never blocks. Its links hold one-time
        codes, so none of it is logged."""
        while await proc.stdout.readline():
            pass

    async def _stop_login(self):
        proc, self._login = self._login, None
        if proc is not None and proc.returncode is None:
            proc.kill()
            await proc.wait()
        if self._login_output:
            self._login_output.cancel()
            self._login_output = None

    def forget(self):
        """The user cancelled: don't run the failed request after signing in."""
        if self._pending:
            logger.info("Dropped the request waiting for the Claude sign-in")
        self._pending = None

    async def ask_again(self, _message=None):
        """The user asked for the sign-in page again (the app's button)."""
        if self.signed_out:
            await self.open_sign_in(now=True)

    # -- waiting for it ------------------------------------------------------------

    async def _wait_for_sign_in(self):
        """Check until the sign-in works, then carry on where Friday left off."""
        deadline = time.time() + config.AUTH_WAIT_SECS
        while time.time() < deadline:
            # The sign-in finishing is the usual sign, but the user may sign in
            # some other way (a terminal), so look every little while as well.
            login = self._login
            try:
                if login is not None and login.returncode is None:
                    await asyncio.wait_for(login.wait(), config.AUTH_RETRY_SECS)
                else:
                    await asyncio.sleep(config.AUTH_RETRY_SECS)
            except TimeoutError:
                pass
            if login is not None and login is self._login and login.returncode not in (None, 0):
                logger.warning(f"The Claude sign-in ended without signing in ({login.returncode})")
                self._login = None
            if await check() == "ok":
                await self._recovered()
                return
        logger.warning("Gave up waiting for the Claude sign-in; the next request tries again")
        await self._stop_login()

    async def _recovered(self):
        logger.info("Claude is signed in again")
        self.signed_out = False
        await self._stop_login()
        hub.emit("resolved", code="claude_auth")
        pending, self._pending = self._pending, None
        if pending and time.time() - self._pending_at > config.AUTH_PENDING_SECS:
            pending = None  # too old to still be wanted
        self._signed_in.set()
        try:
            await self._resume(pending)
        except Exception as e:
            logger.exception(e)

    async def until_signed_in(self):
        await self._signed_in.wait()

    # -- looking ahead ---------------------------------------------------------------

    async def watch(self):
        """Check the sign-in at start-up and then regularly, between requests."""
        first = True
        while True:
            if not self._busy():
                if not self.signed_out:
                    status = await check()
                    if first and status == "ok" and not self.signed_out:
                        # A fresh engine starts with nothing to report, so tell
                        # the app any sign-in warning it still shows is stale.
                        hub.emit("resolved", code="claude_auth")
                    first = False
                    if status == "signed_out" and not self.signed_out:
                        message = await self.lapsed(None)
                        if message:
                            await self._say(message)
                elif self._recovery is None or self._recovery.done():
                    # Gave up waiting a while ago: the user may have signed in
                    # some other way since.
                    if await check() == "ok" and self.signed_out:
                        await self._recovered()
            await asyncio.sleep(config.AUTH_CHECK_SECS)

    async def close(self):
        if self._recovery:
            self._recovery.cancel()
        await self._stop_login()
