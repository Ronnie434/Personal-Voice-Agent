# App ↔ engine protocol, v1

JSON lines over a Unix socket. Every message is `{"v":1,"type":...}`.
Implemented in `engine/friday_engine/ipc.py`; exercised end to end by
`engine/tests/test_ipc.py`, whose `Host` class is the reference for the app side.

## Start-up

1. The app creates the socket (mode 0600) and starts the engine with
   `FRIDAY_SOCKET=<path>` and `FRIDAY_TOKEN=<random per launch>`.
2. Engine → app: `hello {token, pid, engine}`. A wrong token: the app hangs up
   and the engine exits.
3. App → engine: `configure {settings}`. Settings are the same names as the
   environment variables in `config.py` (`ELEVENLABS_API_KEY`, `WAKE_WORD`,
   `INPUT_DEVICE`, …). They are never passed on to Claude.
4. The engine loads and reports `state`.

If the socket closes, the engine shuts down: it never outlives the app with an
open microphone. Without `FRIDAY_SOCKET` the engine runs alone, as before.

## Engine → app

| type | fields | when |
|---|---|---|
| `state` | `state`, `conversation` | on change. `starting`, `loading`, `warming_claude`, `listening`, `hearing`, `thinking`, `speaking`, `paused`. `conversation` is true while no wake phrase is needed (show the orb). |
| `levels` | `mic`, `out` (0–1) | 20 Hz while there is sound, then one zero |
| `heard` | `text` | a request was accepted |
| `reply` | `text`, `final` | each thing Friday says; `final` is the answer itself |
| `warning` | `code` | `tts_quota`, `tts_auth`, `claude_missing` (more to come: `claude_auth`, `mic_denied`, `device_lost`, `model_missing`) |
| `devices` | `inputs`, `outputs`, `default_input`, `default_output` | once at start |
| `heartbeat` | `t` | every 2 s |

## App → engine

| type | fields | effect |
|---|---|---|
| `pause` / `resume` | | stop acting on speech and go quiet / start again |
| `interrupt` | | stop talking and stop the current request |
| `ask` | `text` | a typed request, handled as if spoken after the wake phrase |
| `shutdown` | | exit cleanly |

Not built yet: `say`, `probe`, `download_model`, `tool_activity`, `download`.
While paused the microphone stream stays open but nothing heard is acted on;
closing the stream on pause is M2 work.
