# Friday for Mac: Development Plan (v2)

_10 Nov 2026 · replaces v1 · Apple Silicon, macOS 14+_

Friday becomes a signed, auto-updating menu bar app: download, open, connect
Claude, grant the mic, say "hey Friday". v1 of this doc answered *can we
package it*. This version answers *how we build it, in what order, and what it
looks like*.

**What changed from v1**

- Apple Developer Program is already in place (team `JRBD76VZ75`, the same team
  OfferBee ships under). Enrollment, cost and account steps are gone; what is
  left is two one-time items in that account (section 7).
- New: a design system for a modern, minimal app (section 3).
- New: milestones broken into tasks with exit criteria, a repo layout, and
  engineering rules (sections 5 and 6).
- Architecture and security decisions from v1 stand, condensed (section 4).

---

## 1. Decisions

| Area | Decision |
|---|---|
| Shell | Native Swift + SwiftUI menu bar app (`MenuBarExtra`, window style). No Dock icon. |
| Engine | Today's Python pipeline, wrapped as `friday_engine`, run as a supervised child process. |
| Python runtime | python-build-standalone 3.12 embedded in the bundle. PyInstaller `--onedir` only as fallback. |
| Host ↔ engine | Unix socket in Application Support, JSON lines, per-launch token, versioned protocol. |
| Distribution | Developer ID + notarization, DMG, Sparkle 2 updates. Not the Mac App Store (sandbox forbids what Claude does). |
| Look | VoiceOS-style: SF Pro, DM Mono labels, ink-on-white neutrals, black pill buttons, glass panels. Liquid Glass on macOS 26+, materials on 14–15. |
| Minimum OS | macOS 14 Sonoma, Apple Silicon only. |
| Bundle id | `com.ronnie434.Friday` (proposal, decide in M0). |
| Voice fallback | macOS system voice (zero size) replaces Kokoro in the app; torch is dropped. |

## 2. What v1 of the app is (and is not)

**Is:** a hands-free assistant that lives in the menu bar, listens for its name,
does things through your own Claude Code, and talks back. Set up in under
10 minutes by someone who has never opened Terminal, except to sign in to Claude.

**Is not (v1):** a chat window, a transcript app, a Windows/Intel build, a
plugin system, an App Store app, a hosted service. Friday never sees Claude
credentials; it drives the user's own `claude` CLI.

**Experience principles**

1. *Invisible until called.* No windows on launch. The menu bar icon is the
   whole UI most of the day.
2. *Always honest about the mic.* When Friday is listening for a command, it is
   visibly so. One keystroke mutes it.
3. *Never silent on failure.* Every failure ends in a spoken or visible
   sentence that says what broke and the one thing to do.
4. *Fast is a feature.* Measured latency budgets (section 8) gate releases.
5. *Native over custom.* System controls, system fonts, system sounds. Custom
   only where Friday is genuinely different: the orb.

---

## 3. Design system: modern and minimal

### 3.1 Surfaces

There are only five:

| Surface | When | What it is |
|---|---|---|
| **Menu bar icon** | Always | A 16 pt monochrome glyph (template image). State through shape and motion, not colour, except amber/red for problems. |
| **Popover** | Click the icon | 320 pt wide panel: status, last exchange, three actions. |
| **Orb HUD** | While Friday is in a conversation | A small floating pill under the menu bar (centred, beside the notch on notched Macs). Shows hearing / thinking / speaking. Click-through, never takes focus. |
| **Setup** | First run, and "Fix" actions | One 560 × 640 window, one step per screen. |
| **Settings** | ⌘, from the popover | Standard macOS settings window, sidebar of six panes. |

No other windows. Logs open in Console.app; the diagnostics zip goes to Finder.

### 3.2 Layouts

**Popover** (top to bottom, 16 pt padding, 12 pt between groups):

```
┌──────────────────────────────────────┐
│ ● Listening                    ⏸  ⚙  │  status line, pause, settings
│                                      │
│ “what's on my calendar today?”       │  last thing heard (secondary)
│ You have two meetings, the first…    │  last reply, 3 lines max (primary)
│                                      │
│ [ Ask Friday… ⌘⇧Space ]              │  type instead of talk
│──────────────────────────────────────│
│ ⚠ Voice using backup — Fix           │  only when a warning exists
└──────────────────────────────────────┘
```

**Orb HUD** — a 36 pt tall capsule. Left: the orb (20 pt). Right, optional: a
few words of what Friday heard, fading after 2 s. Width animates with content,
max 360 pt. Hidden whenever Friday is idle, so the screen is empty most of the
time.

**Setup** — large title (one line), one sentence, one primary control, a live
check (✓ / spinner / ✕ with a fix button), Continue at bottom right. A thin
progress bar at the top, no step numbers.

**Settings panes** — General, Voice, Listening, Claude, Privacy & Safety,
Advanced. Native grouped `Form`. Every pane fits without scrolling at default
size, except Advanced.

### 3.3 Tokens

The visual language follows voiceos.com: system type with tight tracking, a
mono face for small labels, near-black ink on white, glass surfaces, black
pill buttons, and blue used sparingly. We take the fonts, colours and feel,
not its layouts, logo, illustrations or copy.

**Colour** (light / dark)

| Token | Light | Dark | Use |
|---|---|---|---|
| `ink` | `#111827` | `#F3F4F6` | Primary text, primary pill fill (dark mode inverts it) |
| `ink-2` | `#1F2937` | `#D1D5DB` | Headings on glass, strong secondary |
| `muted` | `#6B7280` | `#9CA3AF` | Secondary text, captions |
| `line` | `#F3F4F6` | `#1F2937` | Hairlines, input borders, chips |
| `surface` | `#FFFFFF` | `#0C0E12` | Window and setup background |
| `glass` | `#FFFFFF` at 48–80 % + blur | `#0C0E12` at 52 % + blur | Popover, settings sidebar |
| `hud` | `#0C0E12` at 52 % + blur, white text | same | Orb HUD, in both appearances |
| `accent` | `#007AFF` | `#0A84FF` | Focus, links, the orb's core, toggles. Never large fills. |
| `alert` | `#FB4268` | `#FF5A7A` | Errors, mic-muted dot |
| `warn` | system orange | system orange | Degraded states |

**Type**

| Role | Face | Size / weight / tracking |
|---|---|---|
| Setup title | SF Pro Display | 28 pt / 600 / −3 % |
| Section heading | SF Pro Display | 17 pt / 600 / −1 % |
| Body | SF Pro Text | 13 pt / 400 |
| Button, menu | SF Pro Text | 13 pt / 500 |
| Label, eyebrow, shortcut, status | **DM Mono** | 11 pt / 400–500 / +2 %, uppercase for eyebrows |
| Keys, paths | DM Mono | 12 pt / 400 |

DM Mono is open source (SIL OFL) and ships inside the app. SF Pro is the
system font, so nothing else is bundled.

**Shape and depth**

- Buttons are pills (`cornerRadius` = height / 2). Primary: `ink` fill, white
  text. Secondary: glass fill, 1 pt `line` border, `ink` text.
- Panels 16 pt radius, inputs 10 pt, chips 8 pt. 4 pt spacing grid
  (8 / 12 / 16 / 24 / 32).
- Glass panels get a 1 pt inner highlight (white 75 % top edge) and a soft
  shadow (0 8 24, black 8 %). Nothing else casts shadows.
- Icons: SF Symbols, regular weight, `ink` or `muted`. One custom template
  glyph for the menu bar.

### 3.4 Motion

Motion carries state, so it must be exact and calm.

| State | Orb | Menu bar glyph |
|---|---|---|
| Idle / listening for name | hidden | static |
| Hearing (conversation open, user speaking) | breathes with mic level, 0.9–1.1 scale | filled |
| Thinking | slow 1.6 s blue-to-white sweep | three-dot pulse |
| Speaking | ripples with output level | filled, wave |
| Paused | hidden | slashed |
| Warning / error | — | amber / red dot badge |

- Durations 150–250 ms, spring (response 0.3, damping 0.85). No bounces.
- Honour Reduce Motion: replace scale and sweep with opacity changes.
- Sounds: system "Pop" when a conversation opens, "Bottle" when it closes,
  both off by default except the open chime, both in Settings.

### 3.5 Voice and copy

Short, plain, first person for Friday, second person for the user. Sentence
case everywhere. Errors say what happened and what to do: "Claude is signed
out. Sign in" — never codes. No exclamation marks, no emoji in UI.

### 3.6 Accessibility and quality bar

- Full keyboard path through setup and settings; VoiceOver labels on every
  control; HUD announces state changes as polite notifications.
- Contrast ≥ 4.5:1 for text in both appearances; verified with Accessibility
  Inspector in M3.
- Works in Light, Dark, Increase Contrast, Reduce Transparency (materials fall
  back to solid `windowBackgroundColor`).
- Design review gate per milestone: screenshots of every surface in light and
  dark, checked against this section, before the milestone closes.

### 3.7 Design deliverables

M1 starts with a clickable SwiftUI prototype (previews only, fake engine) of
all five surfaces, so the look is approved before plumbing exists. Figma is
optional; SwiftUI previews are the source of truth.

---

## 4. Architecture (condensed)

```
Friday.app  (Developer ID, hardened runtime, notarized, LSUIElement)
├─ Contents/MacOS/Friday                Swift host: UI, supervisor, settings, keychain
├─ Contents/Frameworks/Sparkle.framework
├─ Contents/Resources/engine/           friday_engine package (today's agent code)
├─ Contents/Resources/python/           CPython 3.12 + pruned site-packages
└─ Contents/Resources/bin/              my-prs, claude-sessions (bundled Python shebang)

~/Library/Application Support/Friday/  settings.json, models/, run/friday.sock (0600)
~/Library/Logs/Friday/                 engine.log, host.log (rotated, 7 days)
Keychain "com.ronnie434.Friday"        ElevenLabs key
```

Process chain: Friday (Swift) → engine (Python: audio, VAD, STT, TTS) →
`claude` (kept warm) → whatever Claude runs. Host owns the lifecycle: it
listens on the socket, holds the engine's stdin open as a dead-man switch, and
runs the engine in its own process group so Quit kills the whole tree.

**Protocol v1** (JSON lines, `{"v":1,"type":...}`)
- Host → engine: `hello`, `configure`, `start`, `stop`, `pause`, `resume`,
  `interrupt`, `ask` (typed text), `say`, `probe`, `download_model`, `shutdown`.
- Engine → host: `state` (starting, loading, warming_claude, listening,
  hearing, thinking, speaking, paused, error), `levels` (mic/out, 20 Hz, for the
  orb), `heard`, `reply`, `tool_activity`, `warning` (tts_quota, tts_auth,
  claude_auth, claude_missing, mic_denied, device_lost, model_missing),
  `download`, `heartbeat` (2 s).

**Already fixed in the repo** (commit `4340031`): Claude's environment no
longer carries the ElevenLabs key, and voice fails over instead of going
silent. **Still to fix in the engine** (M1): `.env` next to code, `claude`
found via PATH, `/usr/bin/env python3` in `bin/`, torch via Kokoro, personal
prompt and Robinhood list hard-coded, no device picker.

Full reasoning for these choices (Electron/Tauri comparison, PyInstaller
pitfalls with `mlx.metallib`, size math) is in v1, in git history of this file.

---

## 5. Repository and engineering workflow

```
Personal-Voice-Agent/
├─ engine/                     Python package friday_engine (moved from repo root)
│  ├─ friday_engine/{agent,brain,config,stt,aec,ipc,voice}.py
│  ├─ tests/                   pytest: wake word, echo, brain contract, ipc
│  └─ pyproject.toml           pinned, hashed; extras: dev
├─ app/
│  ├─ Friday.xcodeproj
│  ├─ Friday/                  SwiftUI: App, MenuBar, HUD, Setup, Settings, Engine (supervisor + IPC)
│  ├─ FridayTests/             XCTest: IPC codec, settings migration, supervisor
│  └─ FridayUITests/           XCUITest: setup with stubbed probes
├─ packaging/
│  ├─ build_runtime.sh         python-build-standalone + uv install + prune
│  ├─ sign.sh                  inside-out codesign
│  ├─ notarize.sh, make_dmg.sh, appcast.sh
│  └─ entitlements.plist
├─ docs/                       this plan, protocol.md, design.md, release.md
├─ bin/                        dev helpers, unchanged
└─ agent.py                    thin shim so `uv run agent.py` keeps working
```

- **Dev mode stays.** `uv run agent.py` runs the engine without the app, reading
  `.env`, exactly as today, so the live Friday server is never blocked by app
  work. The app in Debug can point at the repo's engine instead of the bundled
  one (`FRIDAY_ENGINE_DIR`).
- **Branches.** Feature branch → PR → `main`. `main` always builds. Releases
  are tags `v0.x.y`.
- **CI** (GitHub Actions, `macos-15` arm64 runner): ruff + pytest for the
  engine, `xcodebuild test` for the app, on every PR. Release workflow on tags.
- **Definition of done** for any task: tests for new logic, works in dev mode
  and in the bundled app, light and dark screenshots for UI, no new
  entitlements without a crash log that proves the need.

---

## 6. Milestones

Estimates assume one developer working with Claude, part time. Each milestone
ends with something runnable.

### M0 · Spike: prove the risky parts (3–5 days)

Goal: kill or confirm the three HIGH risks before building anything.

- [ ] Hand-made `Friday.app` with embedded CPython 3.12 + `mlx` + `mlx-whisper`;
      transcribe a 1 s WAV under hardened runtime.
- [ ] Sign inside-out with the team's Developer ID Application certificate,
      notarize, staple; launch on a clean macOS VM after a Safari download.
- [ ] Mic prompt says "Friday" when the **Python child** opens the mic. If
      not, decide: host captures audio and streams PCM to the engine.
- [ ] Find the minimal entitlement set (expect `audio-input`,
      `automation.apple-events`; prove whether `allow-jit` is needed).
- [ ] Measure real bundle size, DMG size, cold start to first transcription.
- [ ] Decide the bundle id.

**Exit:** a one-page `docs/spike.md` with the answers and numbers, and a go/no-go
on embedded runtime vs PyInstaller and on who owns the mic.

### M1 · Engine refactor + design prototype (1.5–2 weeks, two tracks)

Engine track:
- [ ] Move code into `engine/friday_engine`, keep `agent.py` shim; CI green.
- [ ] Config from a single `configure` payload (secrets in-memory), `.env` only in dev.
- [ ] Resolve `claude` absolute path from the host; contract-test it at start.
- [ ] `ipc.py`: socket client, protocol v1, heartbeat, `levels` stream.
- [ ] System-voice fallback (`AVSpeechSynthesizer` via host `say` message or
      `NSSpeechSynthesizer` from Python); drop Kokoro and torch.
- [ ] Prompt profiles and integration toggles replace hard-coded personal text.
- [ ] Input/output device selection.
- [ ] pytest suite: wake word with real mishearings, echo, merge, brain
      contract against a fake `claude`.

Design track:
- [ ] SwiftUI prototype of the five surfaces against a fake engine; review
      light/dark screenshots and the orb motion. **Design sign-off gate.**

**Exit:** engine runs headless under a test host script; prototype approved.

### M2 · Alpha app (2 weeks)

- [ ] Swift supervisor: launch, socket, token, heartbeat watchdog, backoff
      restarts (1, 2, 4, 8, 30 s), crash loop stop after 5 in 10 min.
- [ ] Menu bar icon + popover wired to real state; pause hotkey; typed `ask`.
- [ ] Orb HUD driven by `state` and `levels`.
- [ ] Keychain storage for the ElevenLabs key; settings.json v1 with migrations.
- [ ] Minimal setup: Claude check, key, mic, model download.
- [ ] `packaging/` scripts produce a signed, notarized DMG locally.

**Exit:** Ronak runs the alpha DMG as his daily Friday instead of `uv run`
for one full week, with no restart needed.

### M3 · Product-quality setup and settings (2 weeks)

- [ ] Full setup flow with live checks and Fix buttons, resumable: Welcome →
      Claude Code (find, install with consent, sign in) → ElevenLabs key
      (skippable, system voice otherwise) → Microphone with level meter and
      device pickers → Speech model download (progress, resume, hash check,
      warm-up) → Wake word test ("say it three times") → Safety profile →
      Done, with "launch at login" offered. Optional access (Accessibility,
      Automation, Screen Recording, GitHub CLI, Chrome) is asked only when
      first needed.
- [ ] All six settings panes; hot vs restart settings, with the "this clears
      Friday's memory" confirm.
- [ ] Safety profiles: Safe (default for new installs), Balanced, Full; hard
      deny list; host-side Approve/Deny notification for destructive actions.
- [ ] Sleep/wake and audio device change recovery; launch at login via
      `SMAppService`.
- [ ] Accessibility pass (VoiceOver, keyboard, contrast, Reduce Motion).
- [ ] Battery: skip sub-300 ms blips, pause on battery option, pause during
      screen sharing.

**Exit:** a non-technical tester finishes setup in under 10 minutes, unaided,
on a clean Mac.

### M4 · Release pipeline (1 week)

- [ ] Sparkle 2 with EdDSA key (private key in GitHub secrets + offline backup),
      appcast on GitHub Pages, stable and beta channels.
- [ ] Tag-triggered GitHub Actions release: build runtime → tests → archive →
      sign → notarize → staple → DMG → appcast → GitHub Release.
- [ ] Updates wait for idle; never interrupt a conversation.
- [ ] Opt-in diagnostics zip (logs redacted).
- [ ] Clean-VM smoke test in CI: mount, launch, handshake, 1 s transcription,
      `codesign --verify --deep --strict`, `spctl -a`, `stapler validate`.

**Exit:** `git tag v0.9.0 && git push --tags` produces an installable,
auto-updating build with no manual steps.

### M5 · Private beta (2 weeks, overlaps M4)

- [ ] 10–20 testers across MacBook Air/Pro, external mics, AirPods, speakers.
- [ ] Device test matrix for wake accuracy and echo; tune defaults.
- [ ] 8-hour soak, sleep/wake cycles, battery draw report.
- [ ] Check Anthropic's current terms for third-party apps that drive the
      user's own Claude Code before any public release.

**Exit:** go/no-go for a public 1.0.

**Timeline:** M0 week 1 · M1 weeks 2–3 · M2 weeks 4–5 · M3 weeks 6–7 ·
M4 week 8 · M5 weeks 8–9. About 9 weeks to a public-ready 1.0.

**Do today, separately:** a LaunchAgent that starts the current repo at login
and restarts it on crash. Not product work, but it removes today's manual
starts while the app is being built.

---

## 7. Signing and release with the existing account

Team `JRBD76VZ75` already ships OfferBee to the App Store through Xcode Cloud
with automatic signing. A Developer ID Mac app outside the store needs two
things that iOS doesn't, both one-time:

1. **Developer ID Application certificate** for the team (Xcode → Settings →
   Accounts → Manage Certificates → + → Developer ID Application). Requires the
   Account Holder role. Export a `.p12` for CI into GitHub secrets.
2. **App Store Connect API key for notarization** (Users and Access → Integrations
   → Team Keys, role Developer). Use a new key just for Friday rather than
   reusing OfferBee's, so either can be revoked alone.

Then add a Friday bundle id in the same team. No App Store Connect app record
is needed; Developer ID apps don't have one.

**Why not Xcode Cloud here:** it can notarize Developer ID apps, but our
embedded Python runtime needs a custom inside-out signing pass over hundreds of
`.so` files, which is simpler to own in a script on GitHub Actions.

**Entitlements** (start minimal, add only with proof): `device.audio-input`,
`automation.apple-events`; `cs.allow-jit` only if M0 shows numba/MLX needs it;
never `disable-library-validation` (we re-sign everything ourselves).

**Release rules:** sign last, in the final location; never copy the bundle
after signing; test every release DMG on a clean VM downloaded through Safari.

## 8. Quality budgets (release gates from M2)

| Metric | Budget |
|---|---|
| End of speech → first spoken word, simple question | ≤ 1.8 s (p50), ≤ 3 s (p90) |
| Wake phrase → conversation chime | ≤ 700 ms |
| Idle CPU while listening for name | ≤ 4 % avg on M1 Air |
| Host process memory | ≤ 80 MB |
| Launch → listening (model cached) | ≤ 8 s |
| Crash-free sessions in beta | ≥ 99 % |
| DMG size | ≤ 300 MB |

M0 records today's numbers from the dev build so every budget has a baseline.

## 9. Security (unchanged from v1, summarised)

The real risk is an open mic driving an agent with shell, AppleScript and
browser access. New installs default to the Safe profile, with a short
conversation window (20–30 s) and a mute hotkey. Money movement and trading
tools, `sudo`, destructive shell patterns and credential paths are on a hard
deny list the prompt cannot lift. Destructive actions need a host-side
confirmation. Secrets live in Keychain, are scrubbed from Claude's environment
(done) and masked in logs. Transcripts aren't stored by default for new users.

## 10. Risks and open decisions

| Risk | Level | Handling |
|---|---|---|
| Mic/Automation prompts don't attribute to Friday from a child process | High | M0; fallback: host owns audio |
| MLX under hardened runtime (metallib lookup, JIT) | High | M0 |
| Anthropic terms for an app driving the user's Claude Code | High | Check before public release (M5) |
| Bundle/model size above estimate | Med | Quantized Whisper option, own CDN |
| Wake accuracy and battery across hardware | Med | M3 battery work, M5 device matrix, later a dedicated wake-word model |
| Claude CLI protocol drift | Med | Contract test at start, nightly test against real CLI |

**Open decisions for Ronak**
1. Bundle id: `com.ronnie434.Friday`, or a domain you own?
2. Name in the menu bar and on the DMG: "Friday", or something more unique for a
   public release?
3. Public 1.0 or personal and friends only? It changes how hard M5 and the
   terms check need to be.

**Later:** Swift-owned audio with Apple's voice processing (better echo
cancellation), a dedicated wake-word model, streaming transcription, Shortcuts
actions, Intel never.
