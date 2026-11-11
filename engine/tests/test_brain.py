"""The contract with the Claude CLI, checked against a fake that speaks its protocol."""

import asyncio

import pytest

from friday_engine import brain as brain_module
from friday_engine import config
from friday_engine.brain import Brain, redact, to_speech


@pytest.fixture
async def brain():
    b = Brain()
    yield b
    await b.close()


async def test_answers_and_keeps_one_warm_process(brain):
    await brain.start()
    pid = brain._proc.pid
    assert await brain.ask("hello") == "You said: hello (turn 1)"
    assert await brain.ask("again") == "You said: again (turn 2)"
    assert brain._proc.pid == pid


async def test_words_before_a_tool_call_are_spoken_meanwhile(brain):
    said = []

    async def on_interim(text):
        said.append(text)

    reply = await brain.ask("tool please", on_interim=on_interim)
    assert said == ["Let me check that."]  # and not the sub-agent's chatter
    assert reply == "All good, see the page."  # markdown and the URL are gone


async def test_claude_dying_is_reported_not_raised(brain):
    assert await brain.ask("die now") == "Claude stopped before answering."
    assert await brain.ask("hello") == "You said: hello (turn 1)"  # a new process


async def test_interrupt_keeps_the_conversation(brain):
    await brain.ask("hello")
    pid = brain._proc.pid
    request = asyncio.create_task(brain.ask("slow job"))
    await asyncio.sleep(0.3)
    request.cancel()
    await asyncio.wait([request])  # as the voice loop does: stop reading, then interrupt
    await brain.cancel()
    assert brain._proc.pid == pid
    assert (await brain.ask("after")).startswith("You said: after (turn 3)")


async def test_claude_never_sees_fridays_secrets(brain, claude_log, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "el-secret")
    monkeypatch.setenv("FROM_DOTENV", "x")
    monkeypatch.setattr(config, "ENV_FILE_KEYS", {"FROM_DOTENV"})
    await brain.start()
    await brain.ask("hello")
    started = claude_log()
    assert "ELEVENLABS_API_KEY" not in started["env"]
    assert "FROM_DOTENV" not in started["env"]
    assert "HOME" in started["env"]


async def test_started_with_the_flags_friday_relies_on(brain, claude_log, tmp_path, monkeypatch):
    monkeypatch.setattr(config, "WORKDIR", tmp_path)
    await brain.start()
    await brain.ask("hello")
    started = claude_log()
    argv = started["argv"]
    for flag in ("-p", "--input-format", "--output-format", "--append-system-prompt",
                 "--permission-mode", "--allowedTools", "--disallowedTools", "--chrome",
                 "--no-session-persistence"):
        assert flag in argv
    assert argv[argv.index("--input-format") + 1] == "stream-json"
    blocked = argv[argv.index("--disallowedTools") + 1]
    assert "place_equity_order" in blocked and "place_crypto_order" in blocked
    assert started["path"].split(":")[0] == str(config.BIN_DIR)
    assert started["cwd"] == str(tmp_path.resolve())


async def test_missing_claude_is_a_clear_error(brain, monkeypatch):
    monkeypatch.setattr(config, "find_claude", lambda: "")
    with pytest.raises(FileNotFoundError):
        await brain.start()


def test_find_claude_checks_usual_places(monkeypatch, tmp_path):
    monkeypatch.delenv("CLAUDE_BIN")
    monkeypatch.setenv("PATH", "/nonexistent")
    monkeypatch.setenv("HOME", str(tmp_path))
    target = tmp_path / ".local/bin/claude"
    target.parent.mkdir(parents=True)
    target.write_text("#!/bin/sh\n")
    assert config.find_claude() in ("", "/opt/homebrew/bin/claude", "/usr/local/bin/claude")
    target.chmod(0o755)
    assert config.find_claude() == str(target)


def test_secrets_are_kept_out_of_the_log(monkeypatch):
    monkeypatch.setenv("MY_API_KEY", "abcdefgh12345678")
    line = redact("using abcdefgh12345678 and sk-ant-api03-zzzzzzzz and token=hunter2hunter2")
    assert "abcdefgh12345678" not in line and "sk-ant" not in line and "hunter2" not in line


def test_long_replies_are_cut_at_a_sentence():
    text = to_speech("This is a sentence. " * 100)
    assert len(text) < config.MAX_SPOKEN_CHARS + 40
    assert text.endswith("That's the short version.")


def test_system_prompt_names_the_helpers():
    assert "my-prs" in brain_module.SYSTEM_PROMPT and "IGNORE" in brain_module.SYSTEM_PROMPT
