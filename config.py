"""Settings for the voice agent. Override any of these with environment variables."""

import os
from pathlib import Path

# Secrets and overrides live in a .env file next to this one (KEY=value lines).
_env = Path(__file__).parent / ".env"
if _env.exists():
    for _line in _env.read_text().splitlines():
        _key, _sep, _value = _line.strip().partition("=")
        if _sep and _key and not _key.startswith("#") and _value.strip():
            os.environ.setdefault(_key.strip(), _value.strip().strip("\"'"))
from pathlib import Path

# Say "hey <WAKE_WORD>, ..." to give a command.
WAKE_WORD = os.getenv("WAKE_WORD", "friday")
# Other spellings speech recognition produces for the same name.
WAKE_ALIASES = [
    w for w in os.getenv("WAKE_ALIASES", "fri day,fryday,fridays,friday's").split(",") if w
]

# Once the wake phrase has started a conversation, everything said goes to the
# agent with no wake phrase, until you say "thanks" / "bye" / "that's all" or
# nothing has been said for this long after its last reply. It decides for
# itself whether stray speech (TV, other people) was meant for it.
CONVERSATION_SECS = float(os.getenv("CONVERSATION_SECS", "60"))

# Spoken once at startup.
GREETING = os.getenv("GREETING", "Friday is ready.")

# Talking over the agent cuts it off at once and what you say becomes the next
# request. Relies on echo cancellation keeping its own voice out of the mic.
# Set INSTANT_BARGE_IN=0 if it keeps cutting itself off: then only the wake
# phrase interrupts it.
INSTANT_BARGE_IN = os.getenv("INSTANT_BARGE_IN", "1").lower() in ("1", "true", "yes")

# Which Chrome to drive when more than one has the Claude extension connected
# (for example two profiles). Use the name the extension shows, e.g. "Browser 2".
CHROME_BROWSER = os.getenv("CHROME_BROWSER", "the first one listed")

# Where the Claude CLI runs. Relative paths in your requests resolve from here.
WORKDIR = Path(os.getenv("AGENT_WORKDIR", str(Path.home()))).expanduser()

# Claude model alias for the brain ("sonnet", "opus", "haiku", or a full id).
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "sonnet")

# What the agent calls you. Empty for no name.
USER_NAME = os.getenv("USER_NAME", "Ronak")

# The agent says what it is doing as it works. If it has still said nothing for
# this long, it says a short "taking a bit longer" line; the wait doubles each
# time and there are at most three such lines per request.
PROGRESS_QUIET_SECS =float(os.getenv("PROGRESS_QUIET_SECS", "25"))

# Hard stop for a single request.
TASK_TIMEOUT_SECS = float(os.getenv("TASK_TIMEOUT_SECS", "300"))

# Follow-ups within this window continue the same Claude conversation. After
# it, the brain swaps in a fresh, already-warm Claude process.
SESSION_IDLE_SECS = float(os.getenv("SESSION_IDLE_SECS", "600"))

# Local speech models.
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
KOKORO_VOICE = os.getenv("KOKORO_VOICE", "af_heart")

# ElevenLabs voice, used when ELEVENLABS_API_KEY is set (in .env). Without a
# key the agent speaks with the local Kokoro voice above. With it, every
# sentence the agent says is sent to ElevenLabs to be turned into speech.
ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "")
ELEVENLABS_VOICE_ID = os.getenv("ELEVENLABS_VOICE_ID", "xd8j2LFPw16XKmJ5qeBK")
ELEVENLABS_MODEL = os.getenv("ELEVENLABS_MODEL", "eleven_flash_v2_5")

# Longest reply that gets spoken, in characters. Longer replies are cut off.
MAX_SPOKEN_CHARS = int(os.getenv("MAX_SPOKEN_CHARS", "700"))

# How much the brain may do without asking:
#   "auto"              - full access; Claude Code's own safety check blocks
#                         actions it judges destructive or unrequested (default)
#   "bypassPermissions" - full access, nothing checked or blocked
#   "dontAsk"           - only what ALLOWED_TOOLS (and your Claude settings) permit
PERMISSION_MODE = os.getenv("PERMISSION_MODE", "auto")

# Always permitted with no safety check, which makes these the fastest calls.
ALLOWED_TOOLS = [
    # Scripts in bin/ (on the brain's PATH): one-call answers to common questions.
    "Bash(my-prs)",
    "Bash(my-prs:*)",
    "Bash(claude-sessions)",
    "Bash(claude-sessions:*)",
    "Read",
    "Grep",
    "Glob",
    "WebSearch",
    "WebFetch",
    "Bash(git status:*)",
    "Bash(git log:*)",
    "Bash(git diff:*)",
    "Bash(git branch:*)",
    "Bash(gh pr list:*)",
    "Bash(gh pr view:*)",
    "Bash(gh pr checks:*)",
    "Bash(gh pr status:*)",
    "Bash(gh run list:*)",
    "Bash(gh run view:*)",
    "Bash(gh issue list:*)",
    "Bash(gh issue view:*)",
    "Bash(gh issue status:*)",
    "Bash(gh search prs:*)",
    "Bash(gh search issues:*)",
    "Bash(gh pr diff:*)",
    "Bash(gh repo view:*)",
    "Bash(gh repo list:*)",
    "Bash(gh status:*)",
    # Filters Claude pipes read-only output through.
    "Bash(head:*)",
    "Bash(tail:*)",
    "Bash(jq:*)",
    "Bash(grep:*)",
    "Bash(wc:*)",
    "Bash(sort:*)",
    "Bash(uniq:*)",
    "Bash(cut:*)",
    "Bash(ls:*)",
    "Bash(date:*)",
    "Bash(uptime:*)",
    "Bash(df:*)",
    "Bash(ps:*)",
    "Bash(pmset -g:*)",
    "Bash(docker ps:*)",
    "Bash(kubectl get:*)",
]

# Never available, in any permission mode. An open microphone must not be able
# to trade. Looking at balances, positions, quotes and order history still works.
_ROBINHOOD = "mcp__claude_ai_Robinhood-Halak__"
DISALLOWED_TOOLS = [
    _ROBINHOOD + name
    for name in (
        "place_equity_order",
        "place_option_order",
        "place_crypto_order",
        "exercise_option",
        "cancel_equity_order",
        "cancel_option_order",
        "cancel_crypto_order",
        "cancel_option_exercise",
    )
]
