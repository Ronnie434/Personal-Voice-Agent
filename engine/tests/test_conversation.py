"""Conversation rules: who gets through, what is echo, what is joined, pause."""

import asyncio
import time

import pytest

from friday_engine import agent, config
from friday_engine.ipc import hub


class FakeBrain:
    def __init__(self, reply="Done.", delay=0.0):
        self.asked, self.cancelled = [], 0
        self.reply, self.delay = reply, delay

    async def ask(self, prompt, on_interim=None):
        self.asked.append(prompt)
        await asyncio.sleep(self.delay)
        return self.reply

    async def cancel(self):
        self.cancelled += 1


@pytest.fixture
def friday(monkeypatch):
    """A VoiceCommandProcessor outside a pipeline: speech and events are captured."""

    def make(brain=None):
        brain = brain or FakeBrain()
        proc = agent.VoiceCommandProcessor(brain)
        proc.said, proc.events, proc.interruptions = [], [], 0

        async def say(text, final=False):
            proc._spoken.append((time.time(), text))
            proc._last_said_at = time.time()
            proc.said.append(text)

        async def interrupt():
            proc.interruptions += 1

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
        proc.brain = brain
        heard = proc._on_transcript

        async def on_transcript(text):
            await heard(text)
            await asyncio.sleep(0.01)  # let the request it started reach the brain

        proc._on_transcript = on_transcript
        monkeypatch.setattr(hub, "emit", lambda kind, **f: proc.events.append((kind, f)))
        return proc

    return make


async def settle(proc):
    if proc._task:
        await asyncio.wait([proc._task], timeout=2)
    await asyncio.sleep(0)


async def test_ignored_without_wake_phrase(friday):
    proc = friday()
    await proc._on_transcript("What time is it?")
    assert proc.brain.asked == []


async def test_wake_phrase_opens_conversation_and_follow_up_needs_none(friday):
    proc = friday()
    await proc._on_transcript("Hey Friday, what time is it?")
    await settle(proc)
    await proc._on_transcript("And tomorrow's weather?")
    await settle(proc)
    assert proc.brain.asked == ["what time is it?", "And tomorrow's weather?"]
    assert proc.said == ["Done.", "Done."]


async def test_thanks_ends_the_conversation(friday):
    proc = friday()
    await proc._on_transcript("Hey Friday, what time is it?")
    await settle(proc)
    await proc._on_transcript("Thanks.")
    await proc._on_transcript("What about tomorrow?")
    assert proc.brain.asked == ["what time is it?"]


async def test_conversation_window_closes_by_itself(friday, monkeypatch):
    proc = friday()
    await proc._on_transcript("Hey Friday, what time is it?")
    await settle(proc)
    proc._awake_until = time.time() - 1
    await proc._on_transcript("What about tomorrow?")
    assert len(proc.brain.asked) == 1


async def test_ignore_reply_is_not_spoken(friday):
    proc = friday(FakeBrain(reply="IGNORE."))
    await proc._on_transcript("Hey Friday, what time is it?")
    await settle(proc)
    assert proc.said == []


async def test_pause_mid_sentence_is_joined_once(friday):
    proc = friday(FakeBrain(delay=5))
    await proc._on_transcript("Hey Friday, check the PR in our service")
    await proc._on_transcript("number 7381")
    assert proc.brain.asked[-1] == "check the PR in our service number 7381"
    assert proc.brain.cancelled == 1
    # A third piece replaces the request rather than chaining on forever.
    await proc._on_transcript("actually open Slack")
    assert proc.brain.asked[-1] == "actually open Slack"
    await proc._abandon_task()


async def test_late_speech_replaces_the_request(friday):
    proc = friday(FakeBrain(delay=5))
    await proc._on_transcript("Hey Friday, check the PR in our service")
    proc._heard_at -= agent.MERGE_SECS + 1
    await proc._on_transcript("open Slack instead")
    assert proc.brain.asked[-1] == "open Slack instead"
    await proc._abandon_task()


async def test_stop_cancels_the_request(friday):
    proc = friday(FakeBrain(delay=5))
    await proc._on_transcript("Hey Friday, summarise my inbox")
    await proc._on_transcript("Stop.")
    assert proc._task is None and proc.brain.cancelled == 1
    assert proc.brain.asked == ["summarise my inbox"]


async def test_own_voice_is_ignored_but_a_reply_is_not(friday):
    proc = friday()
    await proc._on_transcript("Hey Friday, clean up")
    await settle(proc)
    await proc._say("Do you want me to delete the old feature branch now?")
    proc._could_be_echo = True  # speech began while Friday was talking
    await proc._on_transcript("Do you want me to delete the old feature branch now?")
    assert len(proc.brain.asked) == 1
    await proc._on_transcript("Yes, delete the branch")
    await settle(proc)
    assert proc.brain.asked[-1] == "Yes, delete the branch"


async def test_same_words_after_friday_went_quiet_are_the_user(friday):
    proc = friday()
    await proc._on_transcript("Hey Friday, clean up")
    await settle(proc)
    await proc._say("The build finished a minute ago.")
    proc._could_be_echo = False
    await proc._on_transcript("The build finished a minute ago.")
    await settle(proc)
    assert len(proc.brain.asked) == 2


async def test_overlapping_speech_needs_the_wake_phrase(friday, monkeypatch):
    monkeypatch.setattr(config, "INSTANT_BARGE_IN", False)
    proc = friday()
    proc._heard_self = True
    await proc._on_transcript("open the garage")
    assert proc.brain.asked == [] and proc.interruptions == 0
    await proc._on_transcript("Hey Friday, be quiet for a second")
    assert proc.interruptions == 1


async def test_states_reported_to_the_app(friday):
    proc = friday(FakeBrain(delay=0.05))
    proc._report_state()
    await proc._on_transcript("Hey Friday, what time is it?")
    await settle(proc)
    proc._report_state()
    states = [f["state"] for kind, f in proc.events if kind == "state"]
    assert states[:2] == ["listening", "thinking"]
    assert states[-1] == "listening"
    assert ("heard", {"text": "what time is it?"}) in proc.events
    # Still in the conversation after the reply.
    assert [f for k, f in proc.events if k == "state"][-1]["conversation"] is True


async def test_pause_drops_everything_until_resumed(friday):
    proc = friday(FakeBrain(delay=5))
    await proc._on_transcript("Hey Friday, summarise my inbox")
    await proc.pause()
    assert proc._task is None and proc.brain.cancelled == 1 and proc.interruptions == 1
    assert proc.events[-1] == ("state", {"state": "paused", "conversation": False})
    await proc.ask({"text": "typed while paused"})
    assert proc.brain.asked == ["summarise my inbox"]
    await proc.resume()
    assert proc.events[-1][1]["state"] == "listening"
    # The conversation was closed by the pause.
    await proc._on_transcript("what about now")
    assert len(proc.brain.asked) == 1


async def test_typed_ask_needs_no_wake_phrase(friday):
    proc = friday()
    await proc.ask({"text": "what's on my calendar"})
    await settle(proc)
    assert proc.brain.asked == ["what's on my calendar"]
    assert proc.said == ["Done."]
