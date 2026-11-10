# Friday voice agent: handoff (2026-11-10)

Hands-free voice assistant on Ronak's Mac. Say "hey Friday", then talk normally.
Mic → Silero VAD → MLX Whisper (local) → Claude Code CLI (warm process, the user's
subscription) → ElevenLabs voice → speaker. Built on Pipecat 1.15.0, Python 3.12, uv.

## State right now

- Working and tested by voice (with the Mac's `say` voice, not Ronak's own).
- The agent runs as a background command of the Claude session that started it.
  **When that session closes, Friday stops.** A new session must start it again
  (see "Run"). There is no auto-start at login yet.
- Tracked in git: https://github.com/Ronnie434/Personal-Voice-Agent (main).

## Run

```bash
cd "/Users/ronakpatel/Documents/Personal Voice Agent" && uv run agent.py --debug >> logs/agent.log 2>&1
```

Start it as a background command, wait for `Listening.` in `logs/agent.log`, and
read that log to see what was heard and said. Stop any old `agent.py` first.
Ronak's standing instruction: Claude starts/restarts it and reads the log; never
ask him to run anything or paste output.

Typed test without audio: `uv run agent.py --text "any failing CI on my open PRs"`.

## Files

- `agent.py`: pipeline and conversation logic (`VoiceCommandProcessor`).
- `brain.py`: the warm `claude -p` stream-json process, system prompt, interrupt.
- `config.py`: every setting, env-overridable; loads `.env`.
- `stt.py`: Whisper wrapper without Pipecat's filter that dropped 10-character transcripts.
- `aec.py`: WebRTC echo cancellation so the mic doesn't hear Friday's own voice.
- `bin/my-prs`, `bin/claude-sessions`: fast helpers the brain is told to use.
- `.env`: `ELEVENLABS_API_KEY` (secret, chmod 600; never print it).

## How it behaves

- Wake: "hey Friday" (also bare "Friday ...", and any 2 to 3 words ending in Friday,
  because "hey" is often misheard). Aliases in `config.WAKE_ALIASES`.
- After waking, everything said goes to Claude with no wake phrase, for
  `CONVERSATION_SECS` (60) after each reply and all the time it is working.
  "thanks" / "bye" / "that's all" ends it. Claude replies `IGNORE` to speech not
  meant for it, and that is not spoken.
- No canned lines. Claude says a few natural words before using tools (its text
  before a tool call is spoken at once), then the answer. One exception:
  `PROGRESS_LINES` after 25 s of silence, doubling, max three per request.
- Talking over Friday cuts its speech at once (`INSTANT_BARGE_IN`). Speech while it
  is working interrupts Claude with a `control_request` interrupt, which keeps the
  conversation memory. Speech within 8 s of a request still in progress is joined
  to it once (a pause mid-sentence), instead of replacing it.
- Access: `--permission-mode auto`, `--chrome` (drives the user's real Chrome),
  shell/AppleScript/screenshots for the Mac, all connected MCP services. Hooks are
  disabled for the brain. Eight Robinhood order tools are blocked in
  `config.DISALLOWED_TOOLS`; reads are allowed. The prompt makes it ask for a yes
  before sending, deleting, pushing, merging, deploying or buying.
- Voice: ElevenLabs voice `xd8j2LFPw16XKmJ5qeBK`, model `eleven_flash_v2_5`, used
  when the key is set; otherwise local Kokoro `af_heart`. Starter plan, about
  68,500 characters a month.

## Open items (none promised, all offered to Ronak)

1. Interruption accuracy: he said it is "sometimes not accurate". Fixed the
   split-sentence case; the join fix has no clean voice test yet. Ask which case
   he means if it comes up again (cuts off on noise, or fails to stop).
2. ElevenLabs credits run out → Friday goes silent. No fallback to Kokoro yet.
3. The key has all permissions; a text-to-speech-only key would be safer.
4. No auto-start at login; no listening chime.
5. Chrome tasks are slow (one page was 53 s). Two Chromes are connected; it uses
   the first (`CHROME_BROWSER`).
6. Computer-use (pixel clicking) is not available to the Claude CLI; desktop
   control is shell + AppleScript only.
7. With a 60 s open window, TV or other people reach Claude. It usually ignores
   them, but it is a full-access agent: shorten `CONVERSATION_SECS` if needed.
8. Part of OfferBee's dev `APPLE_IAP_PRIVATE_KEY` was printed into the previous
   session's tool output by mistake (a `convex env list` filter missed a
   multi-line value). Ronak was told; rotating it is his decision.

## Lessons for whoever continues

- Test by playing `say "..."` through the speaker and grepping `logs/agent.log`.
  Ronak often uses Friday while you work: check the log for recent activity
  first, or your test cuts into his conversation (this happened three times).
- Restarting the agent wipes Claude's conversation memory. Tell him when you do.
- Never print secrets: list env variable names only, and watch multi-line values.
- The only voice-capable keys elsewhere on this Mac are uare.ai company keys in
  `core-chat-app/.env`. They were deliberately not used.
- Model compliance with "speak before tools" is not 100%; a per-message note
  (`brain.SPEAK_FIRST`) raises it. Whisper mishears names; widen the wake match
  rather than asking him to repeat.
