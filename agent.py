"""Hands-free voice agent: mic -> wake phrase -> Whisper -> Claude Code CLI -> Kokoro -> speaker.

Run:   uv run agent.py
Test the brain without audio:   uv run agent.py --text "what time is it"
"""

import argparse
import asyncio
import random
import re
import sys
import time
from collections import deque

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
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineWorker
from pipecat.processors.audio.vad_processor import VADProcessor
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.services.kokoro.tts import KokoroTTSService
from pipecat.transports.local.audio import LocalAudioTransport, LocalAudioTransportParams
from pipecat.workers.runner import WorkerRunner

import config
from aec import EchoCanceller
from brain import Brain
from stt import WakeFriendlyWhisperSTT

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


# A transcript mostly made of words the agent said this recently is its own voice.
ECHO_MEMORY_SECS = 45.0
ECHO_OVERLAP = 0.7
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
        self._spoken: deque[tuple[float, str]] = deque(maxlen=20)
        self._last_said_at = 0.0
        self._heard = ""  # the request being worked on, and when it was heard
        self._heard_at = 0.0
        self._joined = False

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, VADUserStartedSpeakingFrame):
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

        if isinstance(frame, TranscriptionFrame):
            await self._on_transcript(frame.text.strip())
            return  # transcripts stop here; only our replies go on to speech

        await self.push_frame(frame, direction)

    def _is_echo(self, text: str) -> bool:
        """True if the transcript is the agent's own recent speech picked up by the mic.

        Backs up the timing check, which loses track when a new sound starts
        before the echo has finished being transcribed.
        """
        words = WORD_RE.findall(text.lower())
        if len(words) < 3:
            return False  # too short to tell apart from a real "yes" or "stop"
        cutoff = time.time() - ECHO_MEMORY_SECS
        said = {w for t, line in self._spoken if t > cutoff for w in WORD_RE.findall(line.lower())}
        return sum(w in said for w in words) / len(words) >= ECHO_OVERLAP

    async def _say(self, text: str):
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

        logger.info(f"Heard: {command!r}")
        # Joined once at most, so a TV or a long ramble can't chain on forever.
        self._heard, self._heard_at, self._joined = command, time.time(), joined
        self._task = self.create_task(self._run(command))

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
            reply = "I can't find the Claude command line tool."
        except Exception as e:  # keep listening whatever one request does
            logger.exception(e)
            reply = "That failed. Check the log."
        finally:
            progress.cancel()
        logger.info(f"Reply: {reply!r}")
        if reply.strip(" .").upper() == "IGNORE":
            return  # wasn't meant for the agent: stay quiet, and don't prolong the conversation
        await self._say(reply)


async def run_voice():
    # Echo cancellation needs a speaker rate WebRTC supports (48k, not Kokoro's 24k).
    echo = EchoCanceller()
    transport = LocalAudioTransport(
        LocalAudioTransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_in_filter=echo,
            audio_out_sample_rate=48000,
        )
    )
    echo.attach_to_output(transport.output())
    # A longer pause before end-of-speech, so a mid-sentence breath doesn't split a command.
    vad = VADProcessor(vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=1.0)))
    stt = WakeFriendlyWhisperSTT(
        settings=WakeFriendlyWhisperSTT.Settings(model=config.WHISPER_MODEL, language="en")
    )
    if config.ELEVENLABS_API_KEY:
        from pipecat.services.elevenlabs.tts import ElevenLabsTTSService

        logger.info(f"Voice: ElevenLabs {config.ELEVENLABS_VOICE_ID}")
        tts = ElevenLabsTTSService(
            api_key=config.ELEVENLABS_API_KEY,
            settings=ElevenLabsTTSService.Settings(
                voice=config.ELEVENLABS_VOICE_ID, model=config.ELEVENLABS_MODEL
            ),
        )
    else:
        logger.info(f"Voice: local Kokoro {config.KOKORO_VOICE} (no ElevenLabs key set)")
        tts = KokoroTTSService(
            settings=KokoroTTSService.Settings(voice=config.KOKORO_VOICE),
            # Default is 3s to first audio, which a busy machine can miss; the
            # reply is then dropped in silence.
            stop_frame_timeout_s=20.0,
        )

    brain = Brain()
    await brain.start()  # warm up while the speech models load

    pipeline = Pipeline(
        [
            transport.input(),
            vad,
            stt,
            VoiceCommandProcessor(brain),
            tts,
            transport.output(),
        ]
    )
    # No idle timeout: the agent sits and waits for as long as it's running.
    worker = PipelineWorker(pipeline, idle_timeout_secs=None)
    runner = WorkerRunner()
    await runner.add_workers(worker)

    logger.info(f'Listening. Say "hey {config.WAKE_WORD}, ..." (Ctrl-C to quit)')
    await worker.queue_frames([TTSSpeakFrame(config.GREETING)])
    try:
        await runner.run()
    finally:
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--text",
        action="append",
        help="send a typed request to the brain and print the reply (repeatable)",
    )
    parser.add_argument("--debug", action="store_true", help="log every transcript and frame")
    args = parser.parse_args()

    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if args.debug else "INFO")

    asyncio.run(run_text(args.text) if args.text else run_voice())
