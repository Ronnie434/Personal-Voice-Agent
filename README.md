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
