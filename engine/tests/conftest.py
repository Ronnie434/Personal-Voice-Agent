import json
import os
import sys
from pathlib import Path

import pytest

FAKE_CLAUDE = Path(__file__).parent / "fake_claude.py"

# Tests never read the developer's real .env or start the real Claude.
os.environ["FRIDAY_ENV_FILE"] = "/nonexistent/.env"
os.environ["CLAUDE_BIN"] = str(FAKE_CLAUDE)


@pytest.fixture
def claude_log(tmp_path, monkeypatch):
    """Where the fake Claude records how it was started."""
    log = tmp_path / "claude.json"
    monkeypatch.setenv("FAKE_CLAUDE_LOG", str(log))
    return lambda: json.loads(log.read_text())


@pytest.fixture
def engine_env(tmp_path):
    env = {k: v for k, v in os.environ.items() if not k.startswith("ELEVENLABS_")}
    env.update(
        PYTHONPATH=str(Path(__file__).parents[1]),
        FRIDAY_ENV_FILE="/nonexistent/.env",
        CLAUDE_BIN=str(FAKE_CLAUDE),
        FRIDAY_NO_AUDIO="1",
        AGENT_WORKDIR=str(tmp_path),
    )
    return env


@pytest.fixture
def python():
    return sys.executable
