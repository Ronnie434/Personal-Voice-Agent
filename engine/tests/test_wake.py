"""The wake phrase, as Whisper actually writes it."""

import pytest

from friday_engine.agent import END_RE, STOP_RE, extract_command


@pytest.mark.parametrize(
    "heard, command",
    [
        ("Hey Friday, what time is it?", "what time is it?"),
        ("Hey, Friday. What's on my calendar?", "What's on my calendar?"),
        ("Hay Friday open Slack", "open Slack"),
        ("OK Friday: play some music", "play some music"),
        ("Okay, Friday, stop", "stop"),
        ("Hi Friday", ""),
        ("Friday, any failing CI?", "any failing CI?"),
        ("Pay Friday. Check my pull requests.", "Check my pull requests."),
        ("Say Friday, what's the weather", "what's the weather"),
        ("Hello Friday, are you there", "are you there"),
        ("Hey Fryday, what's up", "what's up"),
        ("Hey Fri day, what's up", "what's up"),
        ("Hey Fridays, what's up", "what's up"),
        ("So I told him, hey Friday, check the build", "check the build"),
        # "hey" misheard, name alone at the end: a bare wake phrase.
        ("Have Friday.", ""),
        ("Paid Friday.", ""),
        ("Hey there Friday", ""),
    ],
)
def test_wake_phrase_heard(heard, command):
    assert extract_command(heard) == command


@pytest.mark.parametrize(
    "heard",
    [
        "What time is it?",
        "Let's meet on Friday afternoon to go through it",
        "I think the release is next Friday.",
        "Thank you.",
        "",
    ],
)
def test_no_wake_phrase(heard):
    assert extract_command(heard) is None


@pytest.mark.parametrize(
    "heard",
    ["Thanks.", "Thank you so much!", "Okay, that's all.", "Great, thanks", "Bye", "I'm done",
     "Alright, see you later.", "No thanks", "That's it, thank you."],
)
def test_ends_conversation(heard):
    assert END_RE.match(heard)


@pytest.mark.parametrize(
    "heard", ["Thanks for that, now open the PR", "Say goodbye to the team for me", "That's all of them?"]
)
def test_does_not_end_conversation(heard):
    assert not END_RE.match(heard)


def test_stop_words():
    assert STOP_RE.match("Stop.")
    assert STOP_RE.match("never mind")
    assert STOP_RE.match("Wait, do the other one instead").end() == len("Wait, ")
    assert not STOP_RE.match("Don't stop the build")
