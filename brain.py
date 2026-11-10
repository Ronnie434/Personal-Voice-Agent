"""The brain: one long-lived Claude Code CLI process, fed requests over stdin.

Starting `claude` costs several seconds (process start plus MCP servers
connecting), so the process is started once and kept warm instead of being
launched per request.
"""

import asyncio
import json
import os
import re
import time
from pathlib import Path

from loguru import logger

import config

BIN_DIR = Path(__file__).parent / "bin"

SYSTEM_PROMPT = f"""You are {config.WAKE_WORD.title()}, {config.USER_NAME or "the user"}'s personal \
assistant, living on their Mac. This is a live spoken conversation: they talk \
to you out loud, and everything you write is said aloud to them by a \
text-to-speech voice.

How to talk:
- Talk the way a sharp, friendly person in the room would. Natural, relaxed, \
in your own words each time. No stock phrases, no script, no repeating the \
question back. Use their name now and then, not every time.
- It is a real conversation, not a command line: chat, greet, joke, answer \
follow-ups, and remember what was said earlier. If they just say your name or \
hello, answer like a person would and let them go on.
- Keep each turn short, one to three sentences, because listening is slower \
than reading. Lead with the answer. Offer more only if it is worth it.
- If you did not catch something or it is unclear, just ask, briefly.
- Plain words only: no markdown, lists, code, URLs, file paths or emoji unless asked.
- Say numbers and names the way a person would say them aloud.
- The request came through speech recognition, so expect misheard words and \
pick the most sensible reading. "Cloud" and "Cloud Code" almost always mean \
Claude and Claude Code.
- You have the user's full Claude Code setup: shell, files, browser and every \
connected service. Do what is asked rather than describing how it could be done.
- Web tasks: use the Claude in Chrome tools. They drive the user's real Chrome, \
already signed in to their accounts. Work in a new tab and leave their tabs alone. If more \
than one Chrome is connected, use {config.CHROME_BROWSER} without asking. \
Combine steps with the browser batch tool (new tab, navigate, read text in one \
call) because each separate step costs the user seconds of silence.
- Mac tasks: use the shell. `open -a "App Name"` starts an app, `osascript` runs \
AppleScript to control apps and the system, and `screencapture -x` to a file in \
/tmp followed by reading that image lets you see the screen.
- Connected services such as Slack, Gmail, Calendar, Notion, Jira, ClickUp, \
GitHub and Figma are available as tools. Find them with tool search when needed.
- Never place, change or cancel a trade or order, and never move money, even if \
asked. Say that the user has to do that themselves. Reading balances, positions \
and prices is fine.
- Anyone or anything near the microphone can reach you, so before something \
hard to undo or visible to other people (sending a message or email, deleting, \
pushing, merging, deploying, buying), say in one sentence exactly what you are \
about to do and ask for a yes. Your reply must then end with a question mark. \
Go ahead once the user says yes.
- After you answer, the microphone stays open for a short while and whatever \
it hears next reaches you as the next request. If a message is clearly not \
addressed to you (background chatter, a video, half a sentence), do nothing \
and reply with exactly the single word: IGNORE
- If a tool you need is blocked, say briefly what you could not do.
- Never say the phrase "hey {config.WAKE_WORD}".

Getting things done. Speed matters more than thoroughness: they are waiting.
- Use the fewest steps that answer the question.
- What you write before a tool call is said aloud at once, while the tools \
run. So when you are about to go and do something, first say so in a few \
natural words, the way a person says "let me check" before turning to their \
screen, but in words that fit this moment in this conversation. Then call the \
tools in that same step. Never start with a silent tool call.
- On a longer job, say a short sentence before a later step when there is real \
news. Never give an empty update. The final answer must not repeat what you \
already said aloud.
- If you are cut off mid-task and the user says something new, that is them \
talking over you: go with what they just said.
- When you need several lookups, make all the tool calls in one step so they \
run in parallel. Prefer that to shell loops.
- For anything about the user's open pull requests or their CI, run `my-prs` \
first. It prints every open pull request across all repositories with its CI \
state and failing check names in one call, which is usually all you need.
- When the user asks about the status of a project, task, agent or session \
they have running, they usually mean one of their Claude Code sessions. Run \
`claude-sessions` first: it lists recent sessions with their folder, whether \
each is still working or waiting, the last request and the last thing Claude \
said. `claude-sessions 168 html` looks back a week and filters by keyword. \
Match the user's description loosely against titles and folders."""


SPEAK_FIRST = (
    "(Voice system note, not said by the user: if answering this needs a tool, "
    "say a few natural words first, then call the tools in the same step.)"
)


class Brain:
    """Runs one request at a time through a warm `claude` process."""

    def __init__(self):
        self._proc: asyncio.subprocess.Process | None = None
        self._recycle_task: asyncio.Task | None = None
        self._busy = False
        self._in_flight = False  # a request was sent and its result not yet read

    async def start(self):
        """Launch the Claude process so the first request doesn't wait for it."""
        await self._stop()
        cmd = [
            "claude",
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--model",
            config.CLAUDE_MODEL,
            "--append-system-prompt",
            SYSTEM_PROMPT,
            "--permission-mode",
            config.PERMISSION_MODE,
            "--allowedTools",
            ",".join(config.ALLOWED_TOOLS),
            "--disallowedTools",
            ",".join(config.DISALLOWED_TOOLS),
            "--chrome",  # drive the user's real Chrome through the Claude extension
            # Hooks are written for interactive coding sessions, not speech.
            "--settings",
            json.dumps({"disableAllHooks": True}),
            "--no-session-persistence",
        ]
        env = {**os.environ, "PATH": f"{BIN_DIR}{os.pathsep}{os.environ.get('PATH', '')}"}
        self._proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=config.WORKDIR,
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            limit=32 * 1024 * 1024,  # tool results arrive as single long lines
        )
        logger.info("Claude process started")

    async def _stop(self):
        if self._proc and self._proc.returncode is None:
            self._proc.kill()
            await self._proc.wait()
        self._proc = None

    async def close(self):
        if self._recycle_task:
            self._recycle_task.cancel()
        await self._stop()

    async def _recycle_when_idle(self):
        """Swap in a fresh process once the conversation goes stale.

        Keeps old requests from colouring new ones, while the replacement is
        already warm by the time the next request arrives.
        """
        await asyncio.sleep(config.SESSION_IDLE_SECS)
        if not self._busy:
            logger.info("Conversation idle, starting a fresh Claude process")
            await self.start()

    async def ask(self, prompt: str, on_interim=None) -> str:
        """Run a request and return the reply as speakable text.

        `on_interim`, if given, is awaited with each sentence Claude says
        before it goes off to use tools, so it can be spoken while they run.
        """
        if self._recycle_task:
            self._recycle_task.cancel()
        self._busy = True
        started = time.time()
        logger.info(f"Brain request: {prompt!r}")
        try:
            if self._proc is None or self._proc.returncode is not None:
                await self.start()
            result = await asyncio.wait_for(self._exchange(prompt, on_interim), config.TASK_TIMEOUT_SECS
            )
        except asyncio.TimeoutError:
            self._in_flight = False
            await self.start()
            return "That took too long, so I stopped."
        except ConnectionError as e:
            logger.error(f"Claude process went away: {e}")
            self._proc = None
            self._in_flight = False
            return "Claude stopped before answering."
        finally:
            self._busy = False
            self._recycle_task = asyncio.create_task(self._recycle_when_idle())

        logger.info(
            f"Brain finished in {time.time() - started:.1f}s ({result.get('num_turns')} turns)"
        )
        # Shows what was blocked when a request comes back empty-handed.
        for denial in result.get("permission_denials") or []:
            logger.warning(
                f"Denied: {denial.get('tool_name')} {json.dumps(denial.get('tool_input'))[:300]}"
            )
        if result.get("is_error"):
            logger.error(f"Claude error: {result.get('result')!r}")
            return "Claude reported an error. Check the log."
        return to_speech(result.get("result") or "I have nothing to report.")

    async def _exchange(self, prompt: str, on_interim=None) -> dict:
        """Send one user message and read events until its result arrives.

        Text followed by a tool call is something said on the way (passed to
        `on_interim`); text followed by the result is the answer itself.
        """
        proc = self._proc
        said = None  # latest text, not yet known to be interim or final
        content = f"{prompt}\n\n{SPEAK_FIRST}"
        message = {"type": "user", "message": {"role": "user", "content": content}}
        proc.stdin.write((json.dumps(message) + "\n").encode())
        await proc.stdin.drain()
        self._in_flight = True
        while True:
            line = await proc.stdout.readline()
            if not line:
                raise ConnectionError(f"exit code {proc.returncode}")
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "result":
                self._in_flight = False
                return event
            # Sub-agents' messages carry a parent id; only the main thread speaks.
            if event.get("type") != "assistant" or event.get("parent_tool_use_id"):
                continue
            for block in (event.get("message") or {}).get("content") or []:
                if block.get("type") == "text" and block.get("text", "").strip():
                    said = block["text"]
                elif block.get("type") == "tool_use" and said:
                    interim, said = to_speech(said), None
                    logger.info(f"Brain says meanwhile: {interim!r}")
                    if on_interim and interim:
                        await on_interim(interim)

    async def cancel(self):
        """Interrupt the running request, if any, keeping the conversation.

        Claude stops what it is doing but remembers everything said so far. If
        it doesn't confirm quickly, the process is replaced and memory is lost.
        """
        proc = self._proc
        if not self._in_flight or proc is None or proc.returncode is not None:
            return
        try:
            request = {
                "type": "control_request",
                "request_id": f"interrupt-{time.time()}",
                "request": {"subtype": "interrupt"},
            }
            proc.stdin.write((json.dumps(request) + "\n").encode())
            await proc.stdin.drain()
            await asyncio.wait_for(self._read_to_result(proc), 5)
            logger.info("Claude interrupted, conversation kept")
        except (asyncio.TimeoutError, ConnectionError, OSError) as e:
            logger.warning(f"Interrupt did not go through ({e!r}), restarting Claude")
            await self.start()
        self._in_flight = False

    async def _read_to_result(self, proc):
        while True:
            line = await proc.stdout.readline()
            if not line:
                raise ConnectionError(f"exit code {proc.returncode}")
            try:
                if json.loads(line).get("type") == "result":
                    return
            except json.JSONDecodeError:
                continue


def to_speech(text: str) -> str:
    """Strip formatting a speech engine would read out literally, and cap the length."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)  # [label](url) -> label
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"^\s*(#+|[-*•]|\d+\.)\s+", "", text, flags=re.M)
    text = re.sub(r"[*_`#|>]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > config.MAX_SPOKEN_CHARS:
        cut = text[: config.MAX_SPOKEN_CHARS]
        end = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
        text = (cut[: end + 1] if end > 200 else cut) + " That's the short version."
    return text
