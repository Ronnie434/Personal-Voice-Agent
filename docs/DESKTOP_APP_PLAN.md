# Friday Desktop App: Architecture and Packaging Plan

Date: 2026-11-10. Scope: turn the current repo (`uv run agent.py`) into a downloadable, signed, auto-updating macOS app a person can install, configure in a UI, and have it work as it does today. Apple Silicon only.

Evidence labels used below: **[repo]** = read from this codebase, **[measured]** = measured on this Mac, **[web]** = from web research (search was thin on MLX/PyInstaller/TCC specifics, so those are marked), **[verify]** = my engineering judgment that must be proven in the Phase 0 spike before anyone relies on it.

---

## 1. What exists today (the packaging-relevant facts)

From reading `agent.py`, `brain.py`, `config.py`, `stt.py`, `aec.py`, `pyproject.toml`, `.env.example`, `bin/`, `HANDOFF.md`:

1. **Pipeline** [repo]: `LocalAudioTransport` (PyAudio, via pipecat `local` extra) -> `EchoCanceller` (livekit WebRTC APM) -> Silero VAD (onnxruntime) -> `WakeFriendlyWhisperSTT` (mlx_whisper, `whisper-large-v3-turbo`) -> `VoiceCommandProcessor` (wake regex, conversation window, barge-in, echo heuristics) -> `Brain` (a long-lived `claude -p --input-format stream-json` subprocess) -> ElevenLabs TTS (Kokoro fallback) -> speaker.
2. **Brain contract** [repo]: stdin/stdout stream-json, `control_request` interrupt, permission mode `auto`, `--chrome`, `--allowedTools`/`--disallowedTools`, hooks disabled, `--no-session-persistence`, cwd = `AGENT_WORKDIR` (default `$HOME`), `bin/` prepended to PATH.
3. **Config** [repo]: `config.py` reads a `.env` next to itself at import time and builds module-level constants. No runtime reload. All settings are env-overridable.
4. **Size** [measured]: `.venv` is 1.4 GB. Largest: torch 571 MB, mlx 238 MB, llvmlite 128 MB, scipy 83 MB, onnxruntime 76 MB, av 45 MB, sympy 29 MB, numpy 26 MB, pipecat 24 MB, espeakng 21 MB, livekit 20 MB, numba 18 MB. The Whisper model is downloaded separately into `~/.cache/huggingface` (about 1.5 to 1.6 GB for `whisper-large-v3-turbo` in fp16; the HF cache dir here shows 20 KB only because blobs are symlinked, so I did not measure it exactly: **[verify]**).
5. **Tooling versions** [measured]: `claude` 2.1.301 at `~/.local/bin/claude` (native installer location), `gh` at `/opt/homebrew/bin/gh`, `uv` at `~/.local/bin/uv`, arm64, Python 3.12.13.

### Things in the current code that break or hurt once it is an app

These are not changes to make now (instruction: do not modify existing code); they are the refactor list that Phase 1 must include.

| # | Issue | Where | Why it matters for an app |
|---|---|---|---|
| 1 | `.env` is located via `Path(__file__).parent` | `config.py` | Inside a signed bundle the code dir is read-only. Config must come from the host (env/IPC) and Application Support. |
| 2 | `BIN_DIR = Path(__file__).parent / "bin"` | `brain.py` | Must point at `Contents/Resources/bin`. |
| 3 | `claude` is found via PATH | `brain.py` | A GUI app launched by launchd gets a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). `~/.local/bin/claude` will not be found. The host must resolve the absolute path and pass it (`CLAUDE_BIN`). The agent already has a `FileNotFoundError` path that says "I can't find the Claude command line tool", which is exactly what users would hit. |
| 4 | Child `claude` inherits the whole `os.environ` | `brain.py` (`env = {**os.environ, ...}`) | `config.py` pushes `ELEVENLABS_API_KEY` from `.env` into `os.environ`, so **the ElevenLabs key is visible to Claude and to every shell command Claude runs**. A prompt-injected page or a hostile person near the mic could exfiltrate it. Scrub the child env (allow-list: HOME, PATH, LANG, TMPDIR, USER, SHELL, proxy vars, `CLAUDE_*`, `ANTHROPIC_*` if the user set them). |
| 5 | `bin/claude-sessions` has shebang `#!/usr/bin/env python3` | `bin/` | On a clean Mac `/usr/bin/python3` is a stub that triggers the Xcode Command Line Tools install dialog. Use the bundled interpreter. `bin/my-prs` is POSIX sh and needs `gh`. |
| 6 | System prompt is personal | `brain.SYSTEM_PROMPT` | Mentions `my-prs`, `claude-sessions`, Chrome extension, Robinhood trade ban, "Ronak" default. Needs profile/feature-toggle templating. |
| 7 | `DISALLOWED_TOOLS` is 8 hard-coded Robinhood MCP tools | `config.py` | Generalize into a user-editable "blocked tools" list with presets (finance, messaging, deploy). |
| 8 | `PROGRESS_LINES`, VAD `stop_secs=1.0`, `ECHO_GUARD_SECS`, `ECHO_MEMORY_SECS`, `ECHO_OVERLAP`, `MERGE_SECS` are code constants | `agent.py` | Expose a small "advanced" subset (see section 7). |
| 9 | No input/output device selection | `agent.py` | Users with AirPods, external mics, monitors need a picker. `LocalAudioTransportParams` takes device indices. |
| 10 | Kokoro fallback pulls **torch (571 MB)** | `pyproject.toml` extras `kokoro`, `whisper` | Single biggest size item. Also `whisper` extra (faster-whisper/ctranslate2) is unused when MLX is used. Drop both for the app (see 4.4). |
| 11 | `numba`/`llvmlite` (146 MB) come from `mlx-whisper` word timestamps | transitive | JIT -> needs hardened-runtime JIT entitlement. Worth testing whether import can be lazy/avoided since `stt.py` never asks for word timestamps [verify]. |
| 12 | ElevenLabs out of credits -> silence | HANDOFF open item 2 | An app must fail audibly/visibly: fallback voice + menu bar warning. |
| 13 | Logs go to stderr / `logs/agent.log` | HANDOFF | Need structured log file in `~/Library/Logs/Friday`, rotation, and a transcript-privacy switch. |
| 14 | Restarting the agent wipes Claude conversation memory | HANDOFF | Settings changes that restart the sidecar must be batched and clearly signposted; prefer hot-reload for cheap settings. |

---

## 2. Shell technology: options and firm recommendation

Requirements that drive the choice: mic permission prompt that attributes cleanly to "Friday", menu bar presence with no Dock icon, login item, Keychain, Sparkle-grade updates, small download, long-running supervision of a Python child, and a settings UI that is not painful.

### 2.1 Comparison

| Option | Download size (shell only, excl. Python) | Effort | Mic / TCC | Menu bar + login item | Auto-update | Verdict |
|---|---|---|---|---|---|---|
| **Native Swift/SwiftUI menu bar app + Python sidecar** | ~5-10 MB | Medium (new language, but small surface; Claude writes most of it) | Best. App bundle has `NSMicrophoneUsageDescription`; prompt says "Friday". Can later capture audio natively (AVAudioEngine) | First class: `MenuBarExtra`, `LSUIElement`, `SMAppService.mainApp.register()` (macOS 13+) [web] | **Sparkle 2**, the mature macOS-native standard with EdDSA signing, delta updates [web] | **Recommended** |
| Tauri 2 + Python sidecar | ~10-15 MB shell (system WebView) | Medium-high: Rust + web UI + sidecar plumbing | OK, but permission APIs and Info.plist keys need plugins/custom config | Tray + autostart plugin work, slightly less polished | Official Tauri updater (narrower than Sparkle on macOS); community `tauri-plugin-sparkle-updater` exists but is new (Dec 2025) [web] | Good second choice. Known pain: Tauri re-bundles externals and **invalidates PyInstaller signatures**; ActivityWatch needed several PRs and inside-out signing to notarize [web] |
| Electron + Python sidecar | ~90-130 MB shell (Chromium + Node) | Lowest if you live in React; strongest UI tooling | Works; prompt may attribute to "Friday" if helper processes are signed correctly, but Electron's multi-process helpers complicate TCC | Tray, `app.setLoginItemSettings` | `electron-updater` (GitHub Releases provider, easy) [web] | Rejected: doubles the runtime footprint (Chromium + Python) for an app whose UI is a settings window and a menu |
| py2app / Briefcase / PyInstaller `.app` only (rumps or PySide6 UI) | 0 extra shell; whole app is Python | Lowest for a first build | Mic prompt attributes to the Python-based app | `rumps` menu bar works; login item needs plist/SMAppService via pyobjc | Sparkle via pyobjc, awkward | Best for a throwaway prototype, weak for a maintainable product (UI quality, signing of frozen mega-bundle, one process for UI and audio so a UI hang stops listening) |
| Pure native rewrite (Swift audio + WhisperKit/MLX Swift + ...) | Smallest | Very high; re-implements Pipecat flow, wake logic, barge-in | Cleanest | Cleanest | Sparkle | Not now. Leave as a long-term option, see Phase 5 |

### 2.2 Recommendation

**Native Swift menu bar app (the "host") supervising a bundled Python 3.12 sidecar (the "agent"), talking over a Unix domain socket with JSON lines.**

Why, in order of weight:
1. **Permissions behave.** macOS TCC attributes mic (and Automation, Screen Recording, Files) prompts to the *responsible process*, which for a child spawned by a signed app bundle is normally that app. A Swift host with the right Info.plist keys and a sidecar *inside the bundle* gives one clean "Friday would like to access the microphone" prompt and one row in System Settings [web, partial; **verify** child attribution in the spike].
2. **Lifecycle is native.** `SMAppService.mainApp.register()` is a few lines, shows up in Login Items, and needs no helper [web]. `LSUIElement` gives menu-bar-only presence. `NSWorkspace` sleep/wake and audio-route notifications are available for restart logic.
3. **Keychain and Sparkle are first-class**, not plugins.
4. **Isolation.** The UI process never does audio or inference. If MLX or Whisper hangs or crashes, the menu bar stays alive, shows the state, and restarts the sidecar. This is the main architectural reason to prefer a split over py2app.
5. **Size.** Shell adds under 10 MB, versus ~100+ MB for Electron.
6. The cost is learning/maintaining Swift. The Swift surface is small (menu, 4 onboarding screens, settings form, process supervisor, Keychain, Sparkle): roughly 1.5 to 2.5k lines. Settings UI can be Swift forms; no web stack needed.

Fallback if Swift is a hard no: **Tauri**, with the Python runtime shipped as resources (not as a Tauri "sidecar" PyInstaller binary) and signed by a post-bundle script. Electron only if the team insists on a rich web UI.

Minimum OS: **macOS 14 (Sonoma)**. MLX wheels target recent macOS (macOS 13.5/14+ depending on release; there are bug reports of MLX Metal init crashes on specific OS versions [web]), `SMAppService` is 13+, and SwiftUI `MenuBarExtra` is 13+. Setting 14 as the floor avoids a class of Metal issues. **[verify]** with the exact `mlx` version pinned in `uv.lock`.

---

## 3. Target architecture

```
Friday.app  (Developer ID signed, hardened runtime, notarized, LSUIElement=1)
├─ Contents/MacOS/Friday                      Swift host (menu bar, UI, supervisor)
├─ Contents/Frameworks/Sparkle.framework      auto-update
├─ Contents/Resources/
│   ├─ agent/                                 friday_agent Python package (agent.py, brain.py, ... renamed, no .env)
│   ├─ python/                                relocatable CPython 3.12 (python-build-standalone, arm64)
│   │   └─ lib/python3.12/site-packages/      pre-installed, pruned deps (mlx, pipecat, onnxruntime, livekit, numpy ...)
│   ├─ bin/                                   my-prs, claude-sessions (shebang -> bundled python)
│   ├─ models/silero_vad.onnx                 (ships inside pipecat wheel already)
│   └─ defaults/profile-*.json                prompt/tool profiles
└─ Contents/Info.plist                        NSMicrophoneUsageDescription, NSAppleEventsUsageDescription, ...

~/Library/Application Support/Friday/
   settings.json         non-secret settings (schema-versioned)
   models/               HF_HOME for Whisper (downloaded on first run)
   run/friday.sock       0600 Unix socket, per-launch token
~/Library/Logs/Friday/   agent.log (rotated), host.log
Keychain (service "ai.friday.app"): ELEVENLABS_API_KEY
```

Processes at runtime: **Friday (Swift)** -> spawns **python agent** (one process: audio, VAD, STT, TTS, state machine) -> spawns **claude** (warm CLI) -> spawns whatever Claude runs (bash, osascript, screencapture, gh, chrome helper).

### 3.1 Why not PyInstaller as the default

PyInstaller works, but for this stack it is the riskier choice:
- It freezes everything into one opaque archive/`_internal` tree; MLX's `mlx.metallib` and `libmlx.dylib` must be located by relative path, and MLX upstream issues show the metallib must sit next to `libmlx.dylib` and moves break lookup [web]. A hook is needed and must be tested.
- Signing: every embedded Mach-O must be signed with your Developer ID and hardened runtime, and one missed binary fails notarization [web]. PyInstaller re-signs ad hoc by default [web], which you then override.
- Each Python code fix means re-freezing; a relocatable runtime + plain `.py` files lets you iterate and diff.

**Preferred: embedded relocatable CPython + pre-built site-packages**, the same approach Briefcase and Beeware use, built reproducibly with `uv`:
1. Download a pinned `python-build-standalone` 3.12 arm64 (install_only, ~30-45 MB unpacked).
2. `uv pip install --target Resources/python/lib/python3.12/site-packages -r requirements.lock` (exported from `uv.lock`, trimmed extras).
3. Prune: delete `__pycache__`, tests, `*.pyi`, docs, unused torch/sympy/networkx if present, `ctranslate2`, `kokoro`, unneeded `scipy` submodules (verify imports first), unneeded `PIL` codecs.
4. Byte-compile to `.pyc` (optional, small startup win).
5. Sign every `.so`/`.dylib`/Mach-O inside-out with a script (`find ... -exec codesign --force --options runtime --timestamp --sign "$ID" {} \;`), then the Python executable, then the app. Never `--deep` as the only step.
6. Launch with `Resources/python/bin/python3.12 -I -m friday_agent`. Run with an env that sets `PYTHONHOME`, `PYTHONNOUSERSITE=1`, `HF_HOME`.

Alternatives for the record:
- **PyInstaller `--onedir`**: acceptable fallback if embedded runtime signing proves fiddly. Use `--collect-all mlx`, add `mlx.metallib` via `datas`, entitlements file on the EXE. Prefer onedir over onefile (onefile unpacks to temp on every start: slow, and breaks signature expectations).
- **Nuitka**: produces compiled C and can shrink/obfuscate, but long builds and fragile with MLX/pipecat dynamic imports. Not worth it for a personal/OSS-style tool.
- **uv-managed runtime created on first launch** (host downloads `uv`, runs `uv sync` into Application Support): smallest DMG (~15 MB) but first run needs ~1 GB of network downloads, depends on PyPI being up, produces unsigned `.so` files outside the bundle (hardened runtime `disable-library-validation` becomes mandatory), and is harder to support. Reasonable for a *dev beta only*.

### 3.2 Real bundle size estimate

Starting from the measured 1.4 GB venv:

| Step | Installed size |
|---|---|
| Current `.venv` | 1,400 MB (measured) |
| Drop `kokoro` + `whisper` extras (torch, sympy, networkx, ctranslate2, espeak) | about -700 MB -> ~700 MB |
| Prune caches/tests/docs/unused scipy parts | about -80-120 MB -> ~580-620 MB |
| Add CPython runtime | +40 MB |
| Swift host + Sparkle | +10 MB |
| **Installed app (estimate)** | **~600-650 MB** |
| **DMG (compressed, UDZO/ULFO)** | **~200-280 MB** (native libs compress about 2.2-3x) |
| Whisper model, downloaded first run | ~1.5-1.6 GB (or ~0.4-0.6 GB if a quantized MLX variant is accepted, to be benchmarked) |

If `numba`/`llvmlite` can be avoided: another -145 MB installed. If scipy is only imported for filters in a path we never hit: -80 MB. Best realistic: ~400-450 MB installed, ~150-200 MB DMG. These are estimates: **the Phase 0 spike must produce the real numbers**. (Apple Silicon only, so no universal2 doubling.)

### 3.3 TTS fallback without torch

Replace Kokoro fallback with (a) macOS `AVSpeechSynthesizer`/`say` driven from the host or agent (zero size, offline, instant), or (b) `kokoro-onnx` (ONNX Runtime is already bundled, model ~80-300 MB downloadable on demand, no torch). This also fixes HANDOFF item 2 (credits run out -> silence): on ElevenLabs HTTP 401/402/429 or timeout, speak via fallback and raise a menu bar warning.

---

## 4. First-run onboarding

A single window (SwiftUI), 6 steps, each with a live status check and "Fix it" button. State machine persisted in `settings.json` so quitting midway resumes. Every step can be skipped except the first three required ones; the menu bar icon shows an amber dot until required steps are done.

### Step 0: Welcome
One sentence on what Friday does and the privacy summary: audio is transcribed on-device; only the reply text goes to ElevenLabs; Claude runs on your own Claude account with your computer access.

### Step 1: Claude Code CLI (required)
Detect, in order: configured path, `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/claude`, then `/bin/zsh -lic 'command -v claude'` (login shell picks up nvm/npm global installs). Run `claude --version` with a 5 s timeout.
- **Not installed**: show the official installer command and offer **"Install for me"**: run `curl -fsSL https://claude.ai/install.sh | bash` in a visible log pane (the native installer places `claude` at `~/.local/bin/claude` and edits shell rc for PATH) [web]. Offer "Copy command" and a Homebrew alternative (`brew install --cask claude-code`) [web]. The user must click to consent; do not run silently.
- **Installed but not signed in**: the CLI login is interactive (browser OAuth). Open Terminal.app (AppleScript or `open -a Terminal`) running `claude`, with an instruction to complete `/login`; then poll. For detection use a cheap non-interactive probe: `claude auth status` if it exists in the installed version (the search could not confirm this subcommand; **[verify]** with `claude --help`), otherwise a one-turn `claude -p "reply with ok" --max-turns 1 --output-format json` and parse `is_error`. Cache the result; re-probe on app activation.
- **Version gate**: record a minimum tested `claude` version (the brain relies on stream-json `control_request` interrupt, `--chrome`, `--permission-mode auto`, `--disallowedTools`). On older versions show "Update Claude Code" (`claude update`). Run a contract test at every sidecar start: send a trivial message, require a `result` event; surface protocol drift loudly.
- **Policy check (risk, not a blocker)**: Friday launches the user's *own* locally installed CLI and never touches their credentials. Still, confirm Anthropic's current terms for products that drive a consumer Claude subscription through the CLI before public distribution (see Risks).

### Step 2: ElevenLabs key (required for the good voice; skippable)
- Paste field with "Test key" button. Test with a harmless call (`GET /v1/user/subscription` or a short TTS of "Friday is ready"); show characters remaining. Recommend creating a key restricted to Text to Speech (HANDOFF open item 3: the key currently has all permissions). Link to the ElevenLabs API keys page.
- Store in Keychain (`kSecClassGenericPassword`, service `ai.friday.app`, `kSecAttrAccessibleAfterFirstUnlock` so it works at login before unlock-edge cases; `...ThisDeviceOnly`). Never write to `settings.json` or `.env`.
- Voice picker: fetch `/v1/voices`, preview button, store `voice_id`. Model dropdown (`eleven_flash_v2_5` default).
- Skip -> local fallback voice.

### Step 3: Microphone permission (required)
- Check `AVCaptureDevice.authorizationStatus(for: .audio)`. If `.notDetermined` call `requestAccess` (prompt text from `NSMicrophoneUsageDescription`). If `.denied` deep-link: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- Show live input level meter (host-side `AVAudioEngine` tap, closed afterwards) and a **device picker** for input and output with a "Say hey Friday" test, so wrong-mic problems are caught here, not later.
- **[verify]** that the prompt and the permission row attribute to "Friday" when the Python sidecar (a child) opens the mic. If attribution is wrong, the fallback is for the host to hold the permission and stream PCM to the sidecar (Phase 5 path anyway).

### Step 4: Optional access that Claude will need
Ask only when needed, with a "Test" button each, because Claude's `osascript` / `screencapture` calls will otherwise trigger surprise prompts mid-conversation:
- **Accessibility** (only if the user enables UI scripting / keystroke automation): `AXIsProcessTrustedWithOptions`; deep-link `Privacy_Accessibility`. Note: Friday itself needs no Accessibility for its core loop; this is for what Claude may do with System Events.
- **Automation** (Apple Events): triggered lazily; app needs `NSAppleEventsUsageDescription` and the `com.apple.security.automation.apple-events` entitlement.
- **Screen Recording** (for `screencapture -x` which the system prompt tells Claude to use): the grant attaches to the responsible app. Explain in plain words; deep-link `Privacy_ScreenCapture`.
- **Files and Folders / Full Disk Access**: default workdir is `$HOME`; Desktop/Documents/Downloads access will prompt for Friday. Offer "choose working folder" (default `~/Friday`) rather than the whole home.
- **Notifications** (for errors and "needs your yes").
- **Chrome**: optional "Control my Chrome" toggle explaining the Claude in Chrome extension must be installed and signed in; detect by running a one-turn probe. If off, `--chrome` is not passed and the prompt drops browser instructions.

### Step 5: GitHub CLI (optional)
Detect `gh` at `/opt/homebrew/bin`, `/usr/local/bin`, login shell. Not installed: offer `brew install gh` (if Homebrew exists) or download the official pkg link. Signed in: `gh auth status --hostname github.com`; if not, Terminal with `gh auth login --web`. Enabling it turns on the `my-prs` helper, the `gh ...` allow-list entries, and the PR paragraph of the system prompt. Disabled -> those are omitted.

### Step 6: Speech model download
- Whisper model repo `mlx-community/whisper-large-v3-turbo` (default). Download with `huggingface_hub.snapshot_download(local_dir=~/Library/Application Support/Friday/models, ...)` from the sidecar running in a "prepare" mode, emitting `{"event":"download","bytes":N,"total":M,"file":...}` over IPC. UI shows progress bar, speed, ETA, Pause/Resume (HF supports resumable downloads), disk-space precheck (need >= 3 GB free), network-failure retry with backoff.
- Verify integrity (sha256 from HF metadata), then **warm-up**: load the model and transcribe 1 s of silence so the first real utterance is not slow. Show "Compiling Metal shaders (first run only)".
- Model choices in UI with honest tradeoffs: Turbo (default, best accuracy), a smaller/quantized one (faster, less RAM, worse on names like "Friday"). Disk usage shown with "Delete model".
- Optionally host the model on your own CDN/GitHub Releases to avoid HF rate limits and outages; keep HF as fallback.
- Test the HF cache path rule: set `HF_HOME` (and `HUGGINGFACE_HUB_CACHE`) for the sidecar so nothing lands in the user's real `~/.cache`.

### Step 7: Wake word and conversation
Name field "What should I call you?" (`USER_NAME`), wake word (`WAKE_WORD`) with a **"Say it three times" test** that runs STT and *auto-suggests aliases* from what Whisper actually produced (`WAKE_ALIASES`), because the repo's own notes say Whisper mishears names. Conversation window slider (`CONVERSATION_SECS`), barge-in toggle (`INSTANT_BARGE_IN`) with the warning "turn off if Friday keeps interrupting itself" and an automatic hint if headphones are detected (headphones -> barge-in safe).

### Step 8: Safety profile and finish
Pick **Safe (default)**, **Balanced**, or **Full access** (see section 10). Show the exact consequence in one line each. Then "Start Friday" -> greeting plays -> menu bar turns green. Offer "Launch at login" (default on, with a clear toggle, as Apple guidance prefers user control over silent registration [web]).

---

## 5. Settings UI mapped to every option

Settings window with tabs: **General, Voice, Listening, Claude, Access, Advanced**. Anything marked *restart* requires restarting the sidecar (and wipes Claude conversation memory: confirm dialog says so); *hot* is applied live over IPC.

| Setting (`config.py` / code) | Type | UI control | Tab | Apply | Notes |
|---|---|---|---|---|---|
| `WAKE_WORD` | string | Text field + "test" | Listening | restart* (regex and prompt are built at import) | Refactor to a function so it can hot-reload [repo]. Validate: letters only, 3-20 chars. |
| `WAKE_ALIASES` | CSV | Token list editor, "suggest from test" | Listening | restart* | Same refactor. |
| `CONVERSATION_SECS` | float 60 | Slider 10-300 s | Listening | hot | Read per use already (`config.CONVERSATION_SECS` accessed at runtime). |
| `INSTANT_BARGE_IN` | bool | Toggle | Listening | hot | |
| `GREETING` | string | Text field, empty = silent start | General | hot | |
| `USER_NAME` | string | Text field | General | restart (prompt) | |
| `AGENT_WORKDIR` | path | Folder picker | Claude | restart | Default `~/Friday` recommended; `$HOME` shown with warning. |
| `CLAUDE_MODEL` | alias | Dropdown (sonnet, opus, haiku, custom id) | Claude | restart | Show per-model latency/cost hint. |
| `PERMISSION_MODE` | enum | Segmented: Safe (dontAsk) / Balanced (auto) / Full (bypassPermissions) | Access | restart | `bypassPermissions` requires typing a confirmation. |
| `ALLOWED_TOOLS` | list | Grouped checkbox tree (read-only git, gh read, shell filters, web) + custom rules | Access | restart | Presets generated from current defaults. |
| `DISALLOWED_TOOLS` | list | Editable list + presets ("Block trading", "Block sending messages") | Access | restart | Default keeps the 8 Robinhood tools only if the connector is detected; otherwise none. |
| `CHROME_BROWSER` | string | Text/dropdown, shown only if Chrome enabled | Claude | restart | |
| `PROGRESS_QUIET_SECS` | float 25 | Stepper | Advanced | hot | |
| `TASK_TIMEOUT_SECS` | float 300 | Stepper | Advanced | hot | |
| `SESSION_IDLE_SECS` | float 600 | Stepper ("forget conversation after") | Advanced | hot | |
| `WHISPER_MODEL` | HF repo | Dropdown + "custom repo" | Listening | restart | Triggers download flow. |
| `KOKORO_VOICE` | string | Fallback voice dropdown (system voices) | Voice | restart | Becomes "fallback voice"; implement via AVSpeech/kokoro-onnx. |
| `ELEVENLABS_API_KEY` | secret | Secure field -> Keychain, Test button, Remove | Voice | restart | Never in settings.json. |
| `ELEVENLABS_VOICE_ID` | string | Voice picker with preview | Voice | restart | |
| `ELEVENLABS_MODEL` | string | Dropdown | Voice | restart | |
| `MAX_SPOKEN_CHARS` | int 700 | Slider 200-2000 | Voice | hot | Also show monthly character use estimate (Starter ~68,500/month per HANDOFF). |
| (new) input device / output device | id | Pickers with level meter | General | restart (audio) | Not in config today; add. |
| (new) fallback behaviour on TTS failure | enum | Speak with system voice / stay silent | Voice | hot | |
| (new) launch at login | bool | Toggle | General | immediate | `SMAppService`. |
| (new) log level, transcript logging | enum, bool | Dropdown, toggle "Don't store what I say" | Advanced | hot | Privacy. |
| (new) VAD `stop_secs`, echo constants | floats | Advanced disclosure (default hidden) | Advanced | restart | Names: "Pause before I'm done talking". |
| (new) integrations: GitHub helpers, Chrome, session helper | toggles | Toggles | Claude | restart | Compose system prompt from fragments. |
| (new) prompt profile | text | "Personality / extra instructions" editor with reset | Claude | restart | Replaces hand-editing `SYSTEM_PROMPT`. |
| (new) updates: channel, auto-check | enum, bool | Toggles | General | immediate | Sparkle. |

Implementation note: settings are a versioned JSON schema (`schema_version`, migrations). The Swift host is the single writer; it passes the effective config to the sidecar as one JSON blob (IPC `configure`) plus secrets via a separate field held only in memory. `config.py` becomes `Settings.load(json)`; the legacy `.env` path stays for dev.

---

## 6. IPC between host and agent

### 6.1 Transport
**Unix domain socket** at `~/Library/Application Support/Friday/run/friday.sock`, mode `0600`, directory `0700`, host listens, sidecar connects (so the host owns the lifecycle). **Per-launch random token** passed to the sidecar through its environment (env on a child is not world-readable on macOS; argv is visible in `ps`, so avoid argv). Framing: newline-delimited JSON (JSON Lines), UTF-8, one object per line. No TCP, no localhost HTTP (any local process could hit it). Alternatives considered: stdin/stdout JSON lines (simplest, but stdout is polluted by libraries and loguru; keep stdout/stderr for raw logs only), gRPC/WebSocket (overkill).

Also keep a **stdin pipe held open from the host**; if the host dies, the sidecar sees EOF and exits (kills its `claude` child too). Belt and braces with `prctl`-style process groups: spawn sidecar with `setsid`/new process group and `killpg` on stop.

### 6.2 Protocol (v1)

Envelope: `{"v":1,"id":"<uuid>","type":"cmd|evt|res","name":"...","data":{...}}`.

Host -> agent commands:
- `hello {token, host_version}` -> `res {agent_version, protocol, capabilities}`
- `configure {settings, secrets}` (sent right after connect and on hot changes)
- `start` / `stop` (graceful; stop speaks nothing and closes audio)
- `pause_listening` / `resume_listening` (mute from menu, "Do not disturb")
- `interrupt` (stop talking and abort current Claude request; same as barge-in)
- `say {text}` (test voice; also used for host-originated notices)
- `ask {text}` (typed request, mirrors `--text`)
- `probe {what: "claude"|"elevenlabs"|"mic"|"models"}` for onboarding checks
- `download_model {repo}` / `cancel_download`
- `get_state`, `get_logs {since}` (tail), `shutdown`

Agent -> host events:
- `state {phase: starting|loading_models|warming_claude|listening|hearing|thinking|speaking|paused|error, since}` drives the menu bar icon
- `transcript {text, woke, ignored_reason}` (suppressed when "don't store what I say" is on)
- `reply {text}`, `tool_activity {name, summary}` (optional, from stream-json `tool_use` blocks, for a live "Friday is working on..." line)
- `permission_denied {tool, input_preview}` (from `permission_denials`, today only logged)
- `download {file, bytes, total}` / `download_done`
- `warning {code, message}`: `tts_quota`, `tts_auth`, `claude_auth`, `claude_missing`, `mic_denied`, `audio_device_lost`, `model_missing`
- `error {code, message, fatal}`
- `heartbeat {ts, rss_mb, cpu}` every 2 s

### 6.3 Mapping to existing code (minimal intrusion)
A thin `friday_agent/ipc.py` wraps existing objects instead of rewriting them: `VoiceCommandProcessor` gets an optional `emit(event)` callback at the points that already `logger.info(...)` ("Heard", "Reply", "Interrupted by speech", "Brain says meanwhile", "Denied"). `Brain.cancel()` already implements interrupt. Start/stop maps to `run_voice()` task start/cancel. Log lines continue to a rotating file independently of IPC so debugging does not depend on the socket.

### 6.4 Control surfaces for humans
Menu items call the same commands. A tiny CLI shim `friday ctl status|interrupt|say "..."` (talks to the socket) gives Claude-side automation and support a debug hook. Also expose `friday://` URL scheme (`friday://pause`) for Shortcuts later.

---

## 7. Menu bar UX, lifecycle, recovery

### 7.1 Menu bar
Icon states (template images, accessible labels): grey ring = paused/not set up, green dot = listening, pulsing = hearing, spinner = thinking, waveform = speaking, amber = warning, red = error. Menu:
- Status line ("Listening. Say hey Friday" / "Thinking... (checking your PRs)")
- Pause listening (also global hotkey, e.g. Ctrl-Opt-F; mute is important for a hot mic)
- Stop talking (interrupt)
- Last heard / last reply (collapsible, off if transcripts are not stored)
- Warnings with fix actions ("ElevenLabs quota reached - using system voice")
- Settings..., Open logs, Check for updates, About, Quit

Treat the hot mic seriously: persistent visible indicator (macOS already shows the orange mic dot), plus an audible chime option when the conversation window opens/closes (HANDOFF open item 4).

### 7.2 Lifecycle
- **Launch at login**: `SMAppService.mainApp.register()`; read `status` on every launch to mirror the true state (users can disable it in System Settings, and `status` may report `.notFound` after a user disables it [web]). Default on after onboarding, with explicit toggle.
- **Single instance**: lock file + `NSRunningApplication` check.
- **Start**: host starts sidecar after onboarding complete; `loading_models` can take 5-15 s, `warming_claude` several seconds (MCP servers connecting, per `brain.py` docstring). Show a progress phase, speak greeting only at `listening`.
- **Stop/quit**: send `shutdown`, wait 3 s, `SIGTERM` process group, then `SIGKILL`. Verify no orphan `claude` or MCP server children (check by process group at next launch and kill stale ones recorded in a pid file).
- **Sleep/wake and devices**: observe `NSWorkspace.didWakeNotification` and CoreAudio default-device changes; restart audio stage (or the sidecar) after wake or after AirPods connect/disconnect; otherwise PyAudio streams die silently.

### 7.3 Crash recovery
- Watchdog: heartbeat miss for 10 s or process exit -> restart with exponential backoff (1, 2, 4, 8, 30 s). More than 5 crashes in 10 minutes -> stop, show red state with "Open log" and "Send diagnostics" (opt-in zip of logs with transcripts redacted).
- Distinguish causes in the UI: `claude_missing`/`claude_auth` (go back to onboarding step), `mic_denied`, `model_missing` (re-download), Metal/MLX init failure (suggest macOS update).
- `Brain` already handles `claude` exit (`ConnectionError`) and timeouts by restarting; surface that as an event so the menu shows "Claude restarted, memory cleared".
- macOS crash reports for Python segfaults land in `~/Library/Logs/DiagnosticReports`; include in diagnostics zip.
- Optional crash reporting via Sentry (Swift SDK + Python SDK), strictly opt-in.

### 7.4 Resource behaviour
The pipeline transcribes every VAD segment with a 1.5 GB model to find the wake phrase. That is CPU/GPU and battery cost whenever anyone talks nearby. Mitigations to consider: skip STT for very short blips, a smaller first-pass model for wake detection, or a dedicated wake-word model (openWakeWord/Porcupine, tiny) gating the large model [verify cost vs. accuracy]. Add "Pause when on battery" and "Pause during screen sharing" toggles. Measure idle power in Phase 3 with `powermetrics`/Activity Monitor Energy.

---

## 8. Signing, entitlements, notarization, DMG, updates

### 8.1 Accounts and cost
- **Apple Developer Program: US$99 per year** (individual or org) [web]. Required for a Developer ID Application certificate and notarization. Fee waivers exist for nonprofits/education/government. Notarization itself is free. An organization enrollment needs a D-U-N-S number and takes days to weeks; individual enrollment is usually quicker.
- Optional later: Sentry (free tier), domain (~$12/yr) for a landing page and appcast hosting (GitHub Pages is free), EV/other certs not needed on macOS.
- Not distributing through the Mac App Store: the app drives arbitrary shell and AppleScript for Claude, which is incompatible with App Sandbox, so **Developer ID + notarization outside the store** is the only viable path.

### 8.2 Hardened runtime and entitlements
Sign with `--options runtime --timestamp` and an entitlements plist. Candidate set for **Friday.app** (host) and the same file applied to the **embedded `python3.12` executable and every Mach-O in it**:

```xml
<key>com.apple.security.device.audio-input</key>            <true/>  <!-- microphone -->
<key>com.apple.security.automation.apple-events</key>       <true/>  <!-- Claude's osascript/System Events -->
<key>com.apple.security.cs.allow-jit</key>                  <true/>  <!-- numba/llvmlite JIT (see below) -->
<key>com.apple.security.cs.disable-library-validation</key> <true/>  <!-- only if some third-party dylib stays signed by another team -->
<!-- NOT needed: com.apple.security.network.client (that is an App Sandbox key; we are not sandboxed) -->
<!-- NOT sandboxed: com.apple.security.app-sandbox must be absent -->
```

Rationale and what to verify:
- **Mic**: `device.audio-input` + `NSMicrophoneUsageDescription` are mandatory under hardened runtime or macOS silently denies capture.
- **JIT/MLX**: MLX uses Metal (shaders in `mlx.metallib`, compiled via the Metal API) rather than a user-space JIT, so I expect it does *not* need `allow-jit`; **numba/llvmlite** (pulled by mlx-whisper) does JIT and needs `allow-jit` (and sometimes `allow-unsigned-executable-memory`). The cleanest outcome is to stop importing numba so no JIT entitlement is requested at all. Decide empirically: build with the minimal set, run the full pipeline under hardened runtime, add an entitlement only when a crash log proves it is needed. **[verify in Phase 0]**
- **disable-library-validation**: unnecessary if you re-sign every third-party `.so`/`.dylib` with your own identity (recommended), because then all code shares your Team ID. Keep it as a documented fallback only.
- **Apple Events / Screen Recording / Files**: the entitlement plus usage strings allow the *prompts*; the user still grants at runtime. Screen Recording has no entitlement; it is a TCC prompt.
- Child processes (`claude`, `bash`, `osascript`) are spawned by the sidecar and are not signed by you; hardened runtime does not restrict what they do, but their TCC requests are attributed to Friday as the responsible app **[verify]**.

### 8.3 Signing and notarization procedure (CI-scripted)
1. Import the Developer ID Application cert (.p12 from secrets) into a temporary keychain.
2. Sign inside-out: every `*.so`, `*.dylib`, `Mach-O` under `Resources/python` and `Frameworks`; then `Resources/python/bin/python3.12`; then Sparkle's XPC services/Autoupdate/Updater (in that order per Sparkle docs); then `Friday.app`. Verify with `codesign --verify --deep --strict --verbose=2` and `spctl -a -vv`.
3. `ditto -c -k --keepParent Friday.app Friday.zip` -> `xcrun notarytool submit --wait` using an **App Store Connect API key** (`--key`, `--key-id`, `--issuer`) rather than an Apple ID password. On rejection fetch `notarytool log` and fail the job with the log.
4. `xcrun stapler staple Friday.app`.
5. Build DMG (e.g. `create-dmg`: background image, Applications symlink), sign the DMG, notarize + staple the DMG too.
6. Gatekeeper test on a clean machine (Tart VM or a second Mac): download via Safari so the quarantine attribute is set, open, confirm no warnings.
Known trap from real-world Python+Tauri work: copying a bundle after signing invalidates path-dependent signatures; always sign last, in the final location [web].

### 8.4 Auto-update
- **Sparkle 2** in the Swift host: `SPUStandardUpdaterController`, EdDSA (`sparkle:edSignature`) signature on each archive, `SUFeedURL` pointing to an `appcast.xml` on GitHub Pages or S3/R2, update archives as the notarized `.zip`/`.dmg` in GitHub Releases. Delta updates (BinaryDelta) help here because the 600 MB runtime rarely changes; but note deltas diff against the previous version only, so measure.
- Because the model is outside the bundle, updates stay ~200 MB at worst (less with deltas).
- Check on launch and every 24 h; "install on quit" for non-disruptive updates; **do not interrupt an active conversation** (host asks the sidecar for `idle?` before relaunching).
- Channels: `stable` and `beta` appcasts. Keep Sparkle's private key in CI secret + offline backup (loss means you can never ship another update to existing installs).
- Update both pieces atomically: app version and sidecar protocol version are checked at `hello`; mismatch -> force restart.
- Alternatives if the shell were Tauri/Electron: Tauri updater (needs its own signing keypair) or `electron-updater` with GitHub Releases [web].

---

## 9. Packaging build pipeline

Repo layout to add (new top-level dirs, no change to existing modules until Phase 1):

```
desktop/
  FridayApp/            Xcode project (Swift)
  agent_pkg/            thin package: ipc.py, settings.py, __main__.py  (wraps existing modules)
  build/
    make_runtime.sh     download python-build-standalone, uv pip install --target, prune
    sign_all.sh         inside-out signing
    entitlements.plist
    notarize.sh
    make_dmg.sh
    make_appcast.sh
  requirements.app.lock  trimmed lock (no torch/kokoro/whisper extras)
.github/workflows/release.yml
```

Dependency trim: app extras = `elevenlabs`, `local`, `mlx-whisper`, `silero` only (+ `livekit` for AEC). Pin every version via lock; add `pip-audit`/Dependabot because the bundle freezes dependencies at release time and users will not `pip install -U`.

---

## 10. Security

1. **Secrets**: ElevenLabs key in Keychain only. Passed to sidecar in memory via the `configure` IPC message (or inherited env var for that process only, set by the host). **Scrub the `claude` child's environment** (item 4 in section 1). Log redaction: a loguru filter that masks anything matching the key pattern and never logs the `configure` payload.
2. **IPC**: 0600 socket in a 0700 dir, per-launch token, no network listener.
3. **Claude Code permissions are the real attack surface.** An open mic plus `--permission-mode auto` plus full shell, AppleScript, Chrome and all MCP connectors is a very high-privilege agent that can be steered by TV audio, a guest, or hostile web content read by the browser tool. Controls:
   - Ship three profiles. **Safe (default for new installs)**: `dontAsk` + the read-only allow-list; anything else is denied and Friday says what it could not do. **Balanced**: `auto` (Claude Code's own classifier), current default behavior. **Full**: `bypassPermissions`, behind a typed confirmation. Today's repo default is Balanced; keep that for Ronak's own install via migration, but default new users to Safe.
   - Hard deny list that cannot be disabled by the prompt: money movement and trading tools (existing Robinhood list, extend with generic patterns like `*place*order*`), `rm -rf` patterns, `sudo`, `curl | sh`, writing to `~/Library/Keychains`, reading `~/.ssh`/`~/.aws` via Bash deny rules.
   - Keep the "say what you're about to do and ask for a yes" rule, but treat it as a model-level soft control; for destructive classes add a **host-side confirmation** (menu bar notification with Approve/Deny, or require a spoken yes parsed by the VoiceCommandProcessor before the tool call is allowed via a permission-prompt tool). Prefer enforcement in the tool layer over the system prompt.
   - Voice-fingerprint/"only my voice" is out of scope for v1, but keep a **mute hotkey** and a **short conversation window default (20-30 s, not 60)** for new installs (HANDOFF open item 7).
   - Keep `disableAllHooks` so user hooks cannot run unexpectedly during voice use; document it.
4. **Privacy**: STT is local; only reply text goes to ElevenLabs; Claude gets transcripts. Provide "don't store transcripts" (default on for new users), log rotation (7 days), and a "Delete all Friday data" button (settings, models, logs, Keychain item).
5. **Supply chain**: pinned and audited dependencies, hashes in the lock, SBOM per release (`cyclonedx`), notarized artifacts only, signed appcast. The model download verifies hashes.
6. **TCC hygiene**: request permissions just-in-time with explanations; never ask for Full Disk Access by default.
7. **Prompt hygiene**: system prompt fragments are shipped read-only in the bundle; user text is appended, never allowed to remove the safety fragment (enforce in the composer, not the UI only).

---

## 11. Testing, CI, release

### 11.1 Test layers
1. **Unit (fast, pure Python)** [repo]: `extract_command`, `WAKE_RE`/`BARE_WAKE_RE`, `END_RE`, `STOP_RE`, `SENTENCE_RE`, `to_speech`, `_is_echo`, merge logic, settings schema/migrations, tool-profile composer. These are already pure functions; table-driven tests with real Whisper misheard variants ("Pay Friday", "Have Friday").
2. **Brain contract tests**: a fake `claude` executable (script emitting recorded stream-json: text -> tool_use -> result, interrupt, error, exit) to test interim speech, cancel, timeout, restart. A nightly job against the **real** `claude` with a trivial prompt to catch CLI protocol drift (needs a CI auth secret or a self-hosted Mac).
3. **IPC tests**: Swift XCTest against a mock sidecar; Python tests against a mock host; protocol version negotiation.
4. **Audio integration**: GitHub-hosted macOS runners have no mic/speaker. Use a virtual device (BlackHole/loopback) on a **self-hosted Apple Silicon Mac** and `say "hey Friday what time is it"` through it, assert on the event stream. This is the same method the HANDOFF recommends manually.
5. **Bundle smoke test (CI, per release)**: mount DMG on a clean macOS VM (Tart) -> copy to /Applications -> launch -> assert sidecar starts, `hello` handshake OK, MLX imports and runs a 1 s transcription (a tiny test model to keep CI fast), `codesign --verify`, `spctl --assess`, `stapler validate`. Catches missing metallib, unsigned dylib, and entitlement crashes.
6. **UI**: XCUITest for onboarding with stubbed probes; manual checklist for TCC prompts (cannot be automated reliably; reset with `tccutil reset Microphone ai.friday.app`).
7. **Soak**: 8-hour idle run (memory growth, thermal, battery), sleep/wake cycles, AirPods connect/disconnect.

### 11.2 CI/release (GitHub Actions, `macos-14` or newer arm64)
`on: push tag v*` -> checkout -> build runtime -> run tests -> build Xcode archive -> sign -> notarize -> staple -> DMG -> Sparkle sign -> upload to GitHub Release -> update `appcast.xml` on `gh-pages` -> post to Slack/Discord. Secrets: Developer ID cert (base64 .p12) + password, App Store Connect API key (.p8, key id, issuer), Sparkle EdDSA private key. Cache the `python-build-standalone` download and uv cache. Versioning: semver, `CFBundleVersion` = build number, changelog in appcast.

---

## 12. Risks and unknowns (ranked)

1. **Anthropic terms for third-party apps driving a consumer Claude subscription via the CLI.** The app spawns the user's own CLI and never touches credentials, which is the safest shape, but confirm current usage policy before distributing beyond personal use. Also decide the support story when the CLI protocol changes (stream-json fields, `--chrome`, `auto` mode). [unverified, high impact]
2. **TCC attribution of the sidecar and Claude's children** (mic, Automation, Screen Recording). Believed to attribute to the signed app; must be proven on a clean machine. Fallback: host captures audio and streams it. [verify, high]
3. **MLX under hardened runtime and relocation**: metallib lookup, Metal shader cache location, `allow-jit` need via numba. Search found upstream issues about metallib placement and Metal init crashes on some macOS versions but no packaged-app recipe. [verify, high]
4. **Bundle/DMG size reality** vs the estimate; model download UX (1.5 GB). Mitigate with quantized model option and own CDN.
5. **Wake detection quality and power**: continuous large-model STT, Whisper mishearing "Friday", AEC quality across devices (laptop speakers vs AirPods vs external). Needs device test matrix.
6. **ElevenLabs dependency**: cost per user (Starter ~68,500 chars/month per HANDOFF), quota failures, API changes. BYO-key keeps it out of your costs; fallback voice is required.
7. **Claude CLI install/login variability**: npm vs native vs Homebrew installs, PATH differences, interactive login needing a TTY, `claude auth` subcommand availability (not confirmed by search).
8. **Security perception**: a full-access agent with an open mic. Safe default profile and host-side confirmations are the answer; hard to retrofit, so build them in Phase 2.
9. **Notarization surprises** (one unsigned Mach-O fails the whole submission; first-time notarization can be slow) [web].
10. **macOS release churn** (Metal/MLX regressions on new OS builds, TCC behaviour changes): keep a beta channel and a "known good" pin.
11. **Pipecat API churn** (the repo pins >=1.15.0, a fast-moving library; `stt.py` already subclasses internals and `aec.py` monkeypatches `write_audio_frame`). Pin exact versions in the app lock.
12. **Scope creep from personal features** (Robinhood rules, `my-prs`, `claude-sessions`, Chrome) baked into the prompt; needs the integration/profile split.

---

## 13. Phased roadmap

Estimates assume one developer working with Claude doing most of the code, part time-ish calendar; ranges are calendar effort, not elapsed marketing time.

### Phase 0: Feasibility spike (3-5 days)
Goal: prove the risky parts on a **clean Mac user account / Tart VM** with no dev tools.
- Build embedded Python + trimmed deps; run `python -m agent --text "hi"` and a 1 s MLX transcription from inside a hand-made `.app`.
- Sign with Developer ID (enroll now, $99; enrollment can lag), hardened runtime, minimal entitlements; notarize; staple.
- Prove mic prompt attribution, metallib lookup, entitlement set, measured size.
- Exit criteria: signed notarized DMG launches on a clean VM, mic prompt reads "Friday", transcription works, size numbers recorded. **This decides PyInstaller vs embedded runtime and whether the host must own audio.**

### Milestone 0.5 (optional, 1 day, solves today's pain)
Not a product, just reliability for Ronak now: a LaunchAgent plist (`~/Library/LaunchAgents/ai.friday.agent.plist`, `RunAtLoad`, `KeepAlive`) running `uv run agent.py` from the repo with logs to `logs/agent.log`. Fixes HANDOFF "no auto start" and "stops when the Claude session closes". Separate from the app plan; throwaway.

### Phase 1: Minimum first milestone ("Friday.app alpha", 2-3 weeks)
Definition: a signed, notarized DMG that a technical friend can install on a clean Mac, paste an ElevenLabs key, grant mic, and talk to it.
- Swift menu bar host (status icon, Pause, Quit, Open logs), sidecar supervisor with restart, heartbeat, stdin-EOF suicide, socket IPC (`hello`, `configure`, `start/stop`, `state`, `warning/error`).
- Python: `friday_agent` wrapper with `Settings.load`, env scrubbing for the `claude` child, `CLAUDE_BIN` resolution, `HF_HOME`, rotating log file; trimmed dependencies (no torch).
- Minimal onboarding: Claude CLI detect (+ open Terminal for install/login), ElevenLabs key -> Keychain with test, mic permission, model download with progress.
- Fixed settings (file-based), no auto-update yet; manual DMG distribution.
- Exit: install -> configure -> "hey Friday" works as it does today; survives kill -9 of the sidecar; no secrets in env of `claude`.

### Phase 2: Product-quality setup and settings (2-3 weeks)
- Full onboarding (gh, optional permissions, device pickers + level meter, wake-word tester with alias suggestion, safety profiles).
- Complete Settings window per section 5; config hot-reload for the `hot` items; wake word regex refactor.
- Fallback TTS (system voice / kokoro-onnx), quota warnings, `tts_quota` UX.
- Launch at login, sleep/wake and device-change recovery, notifications for errors.
- Profiles and host-side confirmation for destructive actions; prompt fragment composer; integration toggles.
- Exit: a non-technical user completes setup in under 10 minutes without a terminal except Claude login.

### Phase 3: Release engineering and hardening (1-2 weeks)
- Sparkle + appcast + EdDSA keys; GitHub Actions pipeline (build, sign, notarize, DMG, appcast); channels.
- Test suites from section 11 (unit, fake-claude contract, bundle smoke on Tart, soak).
- Privacy controls, diagnostics zip, optional Sentry, landing page, README for users, uninstall instructions ("Delete all data").
- Exit: tag a version -> user gets update prompt, update installs, sidecar restarts cleanly.

### Phase 4: Private beta and polish (2 weeks, overlaps)
10-20 users across hardware/OS/audio setups; fix wake accuracy, AEC and power issues; decide on public release and the policy question (Risk 1).

### Phase 5: Optional upgrades (later)
- Swift-owned audio using `AVAudioEngine` with the **voice-processing I/O unit** (Apple's built-in echo cancellation and noise suppression) replacing livekit AEC and PyAudio, streaming PCM to the sidecar: cleaner permissions, fewer native deps, better barge-in.
- Dedicated wake-word model to cut power; streaming STT to reduce latency.
- Native Swift inference (WhisperKit/MLX Swift) if the Python sidecar is ever worth removing.
- Shortcuts/URL scheme integration, multiple voices/personas, a transcript history view.

**Total to a polished v1: about 6 to 8 weeks of effort**, with the first usable signed alpha at 3 to 4 weeks (Phase 0 + 1).

---

## 14. Decision summary

- **Shell**: native Swift menu bar app (SwiftUI, `LSUIElement`, `SMAppService`, Keychain, Sparkle 2).
- **Agent**: bundled python-build-standalone 3.12 + pre-installed pruned dependencies inside the app, not PyInstaller (PyInstaller `--onedir` is the documented fallback).
- **IPC**: Unix domain socket, JSON Lines, token auth; stdin-EOF dead-man switch.
- **Distribution**: Developer ID + notarization + DMG outside the Mac App Store; Apple Developer Program US$99/year; updates via Sparkle with a GitHub Pages appcast.
- **Size**: roughly 600 MB installed, 200-280 MB DMG (estimate, to be confirmed in Phase 0), plus a ~1.5 GB model downloaded on first run.
- **Biggest wins before any UI**: drop torch (about 570 MB), scrub the child process environment (secret leak), fix PATH resolution of `claude`, and add a Safe permission profile.
- **First step**: the Phase 0 spike on a clean VM, with Developer Program enrollment started the same day.

---

## Sources (web research)

- [Signing and Notarizing HOWTO](https://github.com/txoof/codesign/blob/main/Signing_and_Notarizing_HOWTO.md)
- [Four PRs to Sign One App: Debugging macOS Codesigning for ActivityWatch](https://timetobuildbob.github.io/blog/four-prs-to-sign-one-app)
- [PyInstaller: Notes about specific Features (macOS signing)](https://pyinstaller.org/en/v5.3/feature-notes.html)
- [Signing and notarizing a Python macOS UI application](https://haim.dev/posts/2020-08-08-python-macos-app)
- [Distributing a Python desktop app on Windows and Mac: the full release pipeline](https://dev.to/susumun/distributing-a-python-desktop-app-on-windows-and-mac-the-full-release-pipeline-1n4)
- [MLX issue: Cannot use mlx.metallib from Xcode macOS project](https://upd.dev/ml-explore/mlx/issues/1286)
- [MLX issue: Is it possible to restrict the dependencies of mlx.metallib at compile time?](https://upd.dev/ml-explore/mlx/issues/163)
- [MLX issue: Metal initialization crash on macOS 26.0.1](https://upd.dev/ml-explore/mlx/issues/2691)
- [Sparkle upgrading docs](https://sparkle-project.org/documentation/upgrading/)
- [tauri-plugin-sparkle-updater](https://lib.rs/crates/tauri-plugin-sparkle-updater)
- [Building a Secure Electron Auto-Updater](https://blog.doyensec.com/2026/02/16/electron-safe-updater.html)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice.md)
- [Apple forums: SMAppService - How does this work?](https://developer.apple.com/forums/thread/777520)
- [Apple forums: Honoring user's changed selection when registering mainApp](https://developer.apple.com/forums/thread/760186)
- [Claude Code install docs](https://code.claude.com/docs/en/install)
- [How to Install Claude Code on Mac (2026)](https://www.morphllm.com/install-claude-code-mac)
- [Apple Developer Program fee 2026 overview](https://ambsandigital.com/?p=11104)

Items the web search could not confirm and which are flagged **[verify]** above: `claude auth status` subcommand, TCC attribution of child processes, the exact entitlement set MLX needs under hardened runtime, and exact whisper-large-v3-turbo download size. Verify the $99 fee on developer.apple.com before budgeting.
