"""The voice loop: mic -> wake phrase -> Whisper -> Claude Code CLI -> voice -> speaker.

Started by friday_engine.__main__ (`uv run agent.py`, or the desktop app).
"""

import asyncio
import random
import re
import time
from collections import deque
from difflib import SequenceMatcher

from loguru import logger
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    Frame,
    TranscriptionFrame,
    TTSSpeakFrame,
    VADUserStartedSpeakingFrame,
    VADUserStoppedSpeakingFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.service_switcher import ServiceSwitcher, ServiceSwitcherStrategyFailover
from pipecat.pipeline.worker import PipelineWorker
from pipecat.processors.audio.vad_processor import VADProcessor
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.transports.local.audio import LocalAudioTransport, LocalAudioTransportParams
from pipecat.workers.runner import WorkerRunner

from . import config, voice
from .aec import EchoCanceller
from .brain import Brain
from .ipc import hub
from .stt import WakeFriendlyWhisperSTT

# Whisper writes the wake phrase many ways: "Hey, agent.", "Hay Agent", "OK agent:",
# and mishears the first word ("Pay agent."). At the very start of a sentence
# the wake word alone, or after any of these sound-alikes, counts too.
_WORD = "(?:" + "|".join(re.escape(w) for w in [config.WAKE_WORD, *config.WAKE_ALIASES]) + ")"
WAKE_RE = re.compile(
    rf"(?:\b(?:hey|hay|hi|okay|ok)[\s,.!]*{_WORD}\b"
    rf"|^\W*(?:(?:pay|say|hate|they|yo|eh|a|and|he|hello)[\s,.!]+)?{_WORD}\b)[\s,.!?:;-]*",
    re.IGNORECASE,
)
BARE_WAKE_RE = re.compile(rf"^\W*(?:[\w']+\W+){{1,2}}{_WORD}\W*$", re.IGNORECASE)
SENTENCE_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"'])")
# Said without the wake phrase mid-conversation, these end it. Whisper also
# invents "Thank you." out of silence, so it must not become a request.
END_RE = re.compile(
    r"^\W*(?:(?:okay|ok|alright|great|cool|perfect)\W+)*"
    r"(?:(?:that'?s all|that is all|that'?s it|thanks?( you)?( so much| a lot)?|goodbye|bye|"
    r"go to sleep|no thanks?|i'?m done|we'?re done|see you( later)?)\W*)+$",
    re.IGNORECASE,
)
# Speech this soon after a request that is still being worked on is taken as
# the rest of that request.
MERGE_SECS = 8.0
# Only for long silences; the brain normally says what it is doing itself.
PROGRESS_LINES = [
    "This one's taking a little longer, bear with me.",
    "I'm still looking into it, shouldn't be much longer.",
    "Sorry for the wait, I'm nearly there.",
]
STOP_RE =re.compile(r"^\W*(stop|cancel|never ?mind|forget it|wait|hold on)\b[\s,.!;:-]*", re.IGNORECASE)

# The mic hears the speaker. Speech that begins while the agent is talking, or
# this soon after it stops, is taken to be the agent's own voice.
ECHO_GUARD_SECS = 0.6


# A transcript that replays what the agent just said, word for word and in the
# same order, is its own voice. Two limits keep real replies safe:
# - the speech must have begun while the agent was talking or within
#   ECHO_GUARD_SECS of it stopping (the speaker can't echo after that), so a
#   reply given a moment later always goes through;
# - nearly all of it must line up in order with the agent's words, so a reply
#   that borrows them ("Yes, delete the branch" to "Do you want me to delete
#   the branch?") still has words of its own and goes through.
ECHO_MEMORY_SECS = 45.0
ECHO_MATCH = 0.85
WORD_RE = re.compile(r"[a-z0-9']+")


def extract_command(text: str) -> str | None:
    """Return what follows the wake phrase, "" if nothing does, None if it's absent."""
    match = WAKE_RE.search(text)
    if not match:
        # Said on its own, "hey" is often misheard ("Have Friday.", "Paid
        # Friday."): two or three words ending in the name is a bare wake phrase.
        return "" if BARE_WAKE_RE.match(text) else None
    return text[match.end() :].strip()


class VoiceCommandProcessor(FrameProcessor):
    """Passes what the user says to Claude once the wake phrase has opened a conversation."""

    def __init__(self, brain: Brain):
        super().__init__()
        self._brain = brain
        self._task: asyncio.Task | None = None
        self._awake_until = 0.0
        self._bot_speaking = False
        self._bot_stopped_at = 0.0
        self._in_conversation = False
        self._heard_self = False
        self._could_be_echo = False  # current speech began during or just after ours
        self._spoken: deque[tuple[float, str]] = deque(maxlen=20)
        self._last_said_at = 0.0
        self._heard = ""  # the request being worked on, and when it was heard
        self._heard_at = 0.0
        self._joined = False
        self._paused = False
        self._user_speaking = False
        self._state = ""

    # -- what the desktop app sees and can ask for ---------------------------

    def _awake(self) -> bool:
        busy = self._task is not None and not self._task.done()
        return busy or time.time() < self._awake_until

    def _report_state(self):
        """Tell the app what Friday is doing, whenever that changes."""
        busy = self._task is not None and not self._task.done()
        if self._paused:
            state = "paused"
        elif self._bot_speaking:
            state = "speaking"
        elif busy:
            state = "thinking"
        elif self._user_speaking and self._awake():
            state = "hearing"
        else:
            state = "listening"
        conversation = not self._paused and self._awake()
        if (state, conversation) != self._state:
            self._state = (state, conversation)
            hub.emit("state", state=state, conversation=conversation)

    async def watch_conversation(self):
        """Notice the conversation window closing on its own (nothing else marks it)."""
        while True:
            await asyncio.sleep(0.5)
            self._report_state()

    async def pause(self, _message=None):
        """Stop acting on anything heard, and go quiet, until resumed."""
        logger.info("Paused")
        self._paused = True
        self._awake_until = 0.0
        self._in_conversation = False
        await self._interrupt_speech()
        await self._abandon_task()
        self._report_state()

    async def resume(self, _message=None):
        logger.info("Resumed")
        self._paused = False
        self._report_state()

    async def interrupt(self, _message=None):
        """Stop talking and stop the request in progress; stay in the conversation."""
        logger.info("Interrupted from the app")
        await self._interrupt_speech()
        await self._abandon_task()
        self._report_state()

    async def ask(self, message: dict):
        """A typed request from the app: handled as if said after the wake phrase."""
        text = str(message.get("text") or "").strip()
        if not text or self._paused:
            return
        self._in_conversation = True
        self._awake_until = time.time() + config.CONVERSATION_SECS
        if self._task is not None and not self._task.done():
            await self._abandon_task()
        await self._interrupt_speech()
        self._start(text, joined=False)

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, VADUserStoppedSpeakingFrame):
            self._user_speaking = False
        if isinstance(frame, VADUserStartedSpeakingFrame):
            self._user_speaking = True
            self._could_be_echo = (
                self._bot_speaking or time.time() - self._bot_stopped_at < ECHO_GUARD_SECS
            )
            if config.INSTANT_BARGE_IN and self._bot_speaking:
                # Echo cancellation keeps the agent's voice out of the mic, so speech
                # now is the user talking over it: go quiet at once and take what
                # they say as the next request.
                logger.info("Interrupted by speech")
                await self._interrupt_speech()
                self._heard_self = False
                self._awake_until = time.time() + config.CONVERSATION_SECS
            else:
                # Judge echo by when the speech started, not when its transcript
                # arrives: transcription can finish well after the agent goes quiet.
                self._heard_self = not config.INSTANT_BARGE_IN and (
                    self._bot_speaking or time.time() - self._bot_stopped_at < ECHO_GUARD_SECS
                )
        elif isinstance(frame, BotStartedSpeakingFrame):
            self._bot_speaking = True
            # Whatever is being captured right now is about to include our voice.
            self._heard_self = not config.INSTANT_BARGE_IN
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self._bot_speaking = False
            self._bot_stopped_at = time.time()
            if self._in_conversation:
                # Conversation mode: once the agent has answered, whatever is said
                # next is taken as the next request, no wake phrase needed. A reply
                # is several sentences and this can fire between them, so the
                # window is re-opened at each pause until something is heard.
                self._awake_until = time.time() + config.CONVERSATION_SECS

        if isinstance(
            frame, (VADUserStartedSpeakingFrame, BotStartedSpeakingFrame, BotStoppedSpeakingFrame)
        ):
            logger.debug(f"{type(frame).__name__} heard_self={self._heard_self}")
        self._report_state()

        if isinstance(frame, TranscriptionFrame):
            if not self._paused:
                await self._on_transcript(frame.text.strip())
                self._report_state()
            return  # transcripts stop here; only our replies go on to speech

        await self.push_frame(frame, direction)

    def _is_echo(self, text: str) -> bool:
        """True if the transcript is the agent's own recent speech picked up by the mic.

        Backs up the timing check, which loses track when a new sound starts
        before the echo has finished being transcribed. See ECHO_MATCH for
        what keeps real replies from being mistaken for echo.
        """
        if not self._could_be_echo:
            return False  # began after the agent went quiet: the user
        words = WORD_RE.findall(text.lower())
        if len(words) < 3:
            return False  # too short to tell apart from a real "yes" or "stop"
        cutoff = time.time() - ECHO_MEMORY_SECS
        said = [w for t, line in self._spoken if t > cutoff for w in WORD_RE.findall(line.lower())]
        matcher = SequenceMatcher(None, words, said, autojunk=False)
        in_order = sum(block.size for block in matcher.get_matching_blocks())
        return in_order / len(words) >= ECHO_MATCH

    async def _say(self, text: str, final: bool = False):
        hub.emit("reply", text=text, final=final)
        self._spoken.append((time.time(), text))
        self._last_said_at = time.time()
        # One sentence per frame: Kokoro synthesizes a whole frame before any of
        # it plays, so a long reply sent in one piece starts late or not at all.
        for sentence in SENTENCE_RE.split(text):
            if sentence.strip():
                await self.push_frame(TTSSpeakFrame(sentence.strip()))

    async def _on_transcript(self, text: str):
        command = extract_command(text)
        woken = command is not None
        busy = self._task is not None and not self._task.done()

        if self._heard_self:
            # Speech that overlapped the agent's own voice. With the wake phrase
            # in it, that's the user cutting in (the agent never says the
            # phrase); without it, it's just the speaker being heard by the mic.
            if not woken:
                logger.debug(f"Ignored (agent's own voice): {text!r}")
                return
            logger.info("Interrupted by wake phrase")
            await self._interrupt_speech()

        if not woken and self._is_echo(text):
            logger.debug(f"Ignored (matches what the agent just said): {text!r}")
            return

        if not woken:
            # In a conversation everything said goes to Claude, as it would
            # between two people. While it is working it is still listening.
            if not busy and time.time() > self._awake_until:
                logger.debug(f"Ignored (no wake phrase): {text!r}")
                return
            if END_RE.match(text):
                logger.info(f"Conversation ended: {text!r}")
                self._awake_until = 0.0
                self._in_conversation = False
                return
            command = text
        else:
            self._in_conversation = True
            self._awake_until = time.time() + config.CONVERSATION_SECS
            if not command:
                command = text  # just the name: let Claude answer the hello itself

        stop = STOP_RE.match(command)
        if stop:
            rest = command[stop.end() :].strip()
            if not rest:  # just "stop"; "wait, do X instead" goes to Claude whole
                if busy:
                    logger.info("Stopped the request in progress")
                    await self._abandon_task()
                return

        joined = False
        if busy:
            if not stop and not self._joined and time.time() - self._heard_at < MERGE_SECS:
                # A pause mid-sentence splits one request in two ("check the PR
                # in our service ... number 7381"). Put the halves back together
                # rather than treating the second as a new request.
                logger.info("Joining this to what was said a moment ago")
                command = f"{self._heard} {command}"
                joined = True
            else:
                logger.info("Interrupting the request in progress with what was just said")
            # Claude is interrupted but keeps the conversation either way.
            await self._abandon_task()

        self._start(command, joined)

    def _start(self, command: str, joined: bool):
        logger.info(f"Heard: {command!r}")
        hub.emit("heard", text=command)
        # Joined once at most, so a TV or a long ramble can't chain on forever.
        self._heard, self._heard_at, self._joined = command, time.time(), joined
        self._task = self.create_task(self._run(command))
        self._report_state()

    async def _interrupt_speech(self):
        """Cut off whatever the agent is saying or about to say."""
        await self.broadcast_interruption()

    async def _abandon_task(self):
        task, self._task = self._task, None
        if task:
            await self.cancel_task(task)
        await self._brain.cancel()

    async def _keep_user_posted(self):
        """Break a long silence, rarely, and never with the same line twice running.

        The brain says what it's doing as it goes, so this only speaks when
        nothing at all has been said for a while, and waits longer each time.
        """
        quiet_for = config.PROGRESS_QUIET_SECS
        lines =random.sample(PROGRESS_LINES, len(PROGRESS_LINES))
        for line in lines:
            while (wait := self._last_said_at + quiet_for - time.time()) > 0:
                await asyncio.sleep(wait)
            await self._say(line)
            quiet_for *= 2

    async def _run(self, command: str):
        self._last_said_at = time.time()
        progress = asyncio.create_task(self._keep_user_posted())
        try:
            reply = await self._brain.ask(command, on_interim=self._say)
        except FileNotFoundError:
            hub.emit("warning", code="claude_missing")
            reply = "I can't find the Claude command line tool."
        except Exception as e:  # keep listening whatever one request does
            logger.exception(e)
            reply = "That failed. Check the log."
        finally:
            progress.cancel()
        logger.info(f"Reply: {reply!r}")
        self._task = None
        if reply.strip(" .").upper() == "IGNORE":
            self._report_state()
            return  # wasn't meant for the agent: stay quiet, and don't prolong the conversation
        await self._say(reply, final=True)
        self._report_state()


async def run_voice():
    hub.emit("state", state="loading", conversation=False)
    devices = voice.list_devices()
    hub.emit("devices", **devices)
    # Echo cancellation needs a speaker rate WebRTC supports (48k, not Kokoro's 24k).
    echo = EchoCanceller()
    transport = LocalAudioTransport(
        LocalAudioTransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_in_filter=echo,
            audio_out_sample_rate=48000,
            input_device_index=voice.pick_device(config.INPUT_DEVICE, devices["inputs"]),
            output_device_index=voice.pick_device(config.OUTPUT_DEVICE, devices["outputs"]),
        )
    )
    echo.attach_to_output(transport.output())
    # A longer pause before end-of-speech, so a mid-sentence breath doesn't split a command.
    vad = VADProcessor(vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=1.0)))
    stt = WakeFriendlyWhisperSTT(
        settings=WakeFriendlyWhisperSTT.Settings(model=config.WHISPER_MODEL, language="en")
    )
    backup, backup_name = voice.make_backup_tts()
    if config.ELEVENLABS_API_KEY:
        logger.info(f"Voice: ElevenLabs {config.ELEVENLABS_VOICE_ID}, {backup_name} as backup")
        primary = voice.make_elevenlabs_tts()
        tts = ServiceSwitcher(
            services=[primary, backup],
            strategy_type=ServiceSwitcherStrategyFailover,
        )
    else:
        logger.info(f"Voice: {backup_name} (no ElevenLabs key set)")
        tts = backup

    brain = Brain()
    hub.emit("state", state="warming_claude", conversation=False)
    try:
        await brain.start()  # warm up while the speech models load
    except FileNotFoundError:
        logger.error("The Claude command line tool is not installed")
        hub.emit("warning", code="claude_missing")

    commands = VoiceCommandProcessor(brain)
    pipeline = Pipeline(
        [
            transport.input(),
            vad,
            stt,
            commands,
            tts,
            transport.output(),
        ]
    )
    # No idle timeout: the agent sits and waits for as long as it's running.
    worker = PipelineWorker(pipeline, idle_timeout_secs=None)
    runner = WorkerRunner()
    await runner.add_workers(worker)

    if isinstance(tts, ServiceSwitcher):

        @tts.strategy.event_handler("on_service_switched")
        async def on_voice_switched(strategy, service):
            logger.warning(f"Voice: switched to {service.name}")
            if service is backup:
                hub.emit("warning", code=voice.elevenlabs_warning(type(primary).last_error))
                await worker.queue_frames(
                    [TTSSpeakFrame("My usual voice isn't working, so I'm using my backup voice.")]
                )

    async def shutdown(_message=None):
        logger.info("Shutting down")
        await runner.cancel(reason="the app asked")

    hub.on("pause", commands.pause)
    hub.on("resume", commands.resume)
    hub.on("interrupt", commands.interrupt)
    hub.on("ask", commands.ask)
    hub.on("shutdown", shutdown)
    hub.on_disconnect = shutdown
    watcher = asyncio.create_task(commands.watch_conversation())

    logger.info(f'Listening. Say "hey {config.WAKE_WORD}, ..." (Ctrl-C to quit)')
    await worker.queue_frames([TTSSpeakFrame(config.GREETING)])
    try:
        await runner.run()
    finally:
        watcher.cancel()
        await brain.close()


async def run_headless():
    """The brain and the app link with no microphone or speaker.

    Typed requests from the app are answered in text. Used by tests and by
    FRIDAY_NO_AUDIO=1, where nothing may be recorded or played.
    """
    brain = Brain()
    done = asyncio.Event()
    current: asyncio.Task | None = None
    paused = False

    def state(name: str):
        hub.emit("state", state=name, conversation=name == "thinking")

    async def answer(text: str):
        hub.emit("heard", text=text)
        state("thinking")

        async def interim(sentence: str):
            hub.emit("reply", text=sentence, final=False)

        try:
            reply = await brain.ask(text, on_interim=interim)
        except FileNotFoundError:
            hub.emit("warning", code="claude_missing")
            reply = "I can't find the Claude command line tool."
        hub.emit("reply", text=reply, final=True)
        state("listening")

    async def stop_current():
        nonlocal current
        task, current = current, None
        if task and not task.done():
            task.cancel()
            await asyncio.wait([task])  # it must stop reading Claude before the interrupt
            await brain.cancel()

    async def ask(message: dict):
        nonlocal current
        text = str(message.get("text") or "").strip()
        if text and not paused:
            await stop_current()
            current = asyncio.create_task(answer(text))

    async def interrupt(_message=None):
        await stop_current()
        state("paused" if paused else "listening")

    async def pause(_message=None):
        nonlocal paused
        paused = True
        await interrupt()

    async def resume(_message=None):
        nonlocal paused
        paused = False
        state("listening")

    async def shutdown(_message=None):
        done.set()

    for kind, handler in (("ask", ask), ("interrupt", interrupt), ("pause", pause),
                          ("resume", resume), ("shutdown", shutdown)):
        hub.on(kind, handler)
    hub.on_disconnect = shutdown

    state("warming_claude")
    try:
        await brain.start()
    except FileNotFoundError:
        hub.emit("warning", code="claude_missing")
    state("listening")
    try:
        await done.wait()
    finally:
        await stop_current()
        await brain.close()


async def run_text(prompts: list[str]):
    """Send typed requests one after another to the same warm brain."""
    brain = Brain()
    await brain.start()
    try:
        for prompt in prompts:
            print(await brain.ask(prompt))
    finally:
        await brain.close()
