# Friday

Friday is a hands-free voice assistant for macOS. Say "hey Friday", then talk
normally. It listens locally, hands your request to the Claude Code CLI, and
speaks the answer back.

Pipeline: mic → Silero VAD → MLX Whisper (local speech-to-text) → Claude Code
CLI (a warm `claude -p` process) → ElevenLabs text-to-speech → speaker. Built
on [Pipecat](https://github.com/pipecat-ai/pipecat), Python 3.12, and
[uv](https://docs.astral.sh/uv/).

## Requirements

- macOS on Apple Silicon (MLX Whisper)
- Python 3.12+ and `uv`
- Claude Code CLI installed and signed in (`claude`)
- `gh` CLI signed in (for the `bin/my-prs` helper)
- An ElevenLabs API key

## Setup

```bash
uv sync
cp .env.example .env   # then add your ELEVENLABS_API_KEY
```

## Run

```bash
uv run agent.py --debug
```

Wait for `Listening.`, then say "hey Friday". Typed test without audio:

```bash
uv run agent.py --text "any failing CI on my open PRs"
```

## Files

- `agent.py`: pipeline and conversation logic
- `brain.py`: the warm Claude Code process, system prompt, interrupts
- `config.py`: every setting, overridable through `.env`
- `stt.py`: Whisper wrapper
- `aec.py`: echo cancellation so the mic doesn't hear Friday's own voice
- `bin/`: fast helper commands the brain is told to use
- `HANDOFF.md`: detailed notes on current state and behavior

## Friday for Mac (menu bar app)

A SwiftUI menu bar app that runs this engine for you: no terminal, a pause
shortcut (⇧⌘M), the last exchange in a popover, and Friday's bars on screen
while a conversation is open. Built for local use; it is not notarized.

```bash
app/build-app.sh --install     # builds, signs for this Mac, copies to /Applications
```

- The app runs the engine from this checkout with `uv run agent.py` and talks to
  it over a Unix socket (`docs/protocol.md`). Settings > Advanced can point it at
  another checkout.
- Settings are in `~/Library/Application Support/Friday/settings.json`, the
  ElevenLabs key in the Keychain (or this checkout's `.env`), the engine log in
  `~/Library/Logs/Friday/engine.log`.
- Only one Friday can listen. If one is running from a terminal, the app waits
  and offers to stop it.
- `uv run agent.py` still works on its own, exactly as before.

Tests: `uv run pytest` (engine) and `cd app && swift test` (app core, including
runs against the real engine with no audio). `app/.build/debug/Friday --fake`
runs the UI on a scripted engine; `--snapshots <folder>` draws every screen.
Plan and spike results: `docs/DESKTOP_APP_PLAN.md`, `docs/spike.md`.
