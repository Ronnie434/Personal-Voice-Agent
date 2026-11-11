# M0 spike: results

_10 Nov 2026 · MacBook, Apple Silicon, macOS 27.0.1, Xcode 27.0 · branch `desktop/m0-spike`_

The spike is a hand-built `Friday.app` (Swift host, `LSUIElement`) that runs an
embedded CPython 3.12 as a child process. Rebuild it with `spike/build.sh`, sign
it with `spike/sign.sh`. Raw run reports are in `~/Library/Logs/FridaySpike/`.

## Verdicts

| Question | Answer |
|---|---|
| Embedded runtime or PyInstaller? | **Go: embedded python-build-standalone.** It runs MLX Whisper on Metal under the hardened runtime with no workarounds. PyInstaller is not needed. |
| Who owns the mic? | **The Python child can keep it.** macOS attributes the request to Friday, so the prompt says "Friday". The host does not need to capture audio. |
| `allow-jit` needed? | **No.** No JIT entitlement at all, once numba is replaced by a stand-in. |
| Minimal entitlements | Host: `device.audio-input` (proven) and `automation.apple-events` (policy seen, not exercised). Python binary: **none**. |
| Signed and notarized on a clean Mac? | **Not done yet.** Blocked on a Developer ID certificate for team `JRBD76VZ75` (see "Open"). |

## What was tested

Signed with the team's Apple Development certificate (`JRBD76VZ75`), hardened
runtime on every Mach-O (143 libraries, the Python binary, the host).

| Run | Signing | Result |
|---|---|---|
| Transcribe, real numba | ad-hoc, no hardened runtime | Works |
| Transcribe, real numba | hardened, no entitlements | **Killed**: `SIGKILL (Code Signature Invalid)` in llvmlite's `LLVMPY_TryAllocateExecutableMemory`, at `import mlx_whisper` |
| Same | hardened, `cs.allow-jit` on Python | Killed (llvmlite does not use `MAP_JIT`) |
| Same | hardened, `cs.allow-unsigned-executable-memory` on host only | Killed (entitlements are per executable, the child does not inherit) |
| Same | hardened, `cs.allow-unsigned-executable-memory` on Python | Works |
| Transcribe, **numba stand-in** | hardened, **no entitlements** | **Works**, Metal available, correct text, word timestamps also work |
| Mic from Python child | hardened, no entitlements | No prompt, silence. tccd: "requires entitlement `device.audio-input` but it is missing" for the **responsible** process, Friday |
| Mic from Python child | hardened, `device.audio-input` on **host only** | tccd: `AUTHREQ_PROMPTING … subject=com.ronnie434.Friday.spike`. The prompt is Friday's |

Findings that change the plan:

1. **numba must go.** `mlx_whisper` imports numba only to speed up word
   timestamps, which Friday does not use. Its JIT is killed by the hardened
   runtime unless we add `allow-unsigned-executable-memory`, a broad entitlement.
   A 10-line no-op `numba` package fixes it and removes numba + llvmlite
   (143 MB). Risk: an `mlx-whisper` update could use numba elsewhere; the
   bundled-app smoke test catches that.
2. **torch is not needed** for transcription. `mlx-whisper` lists it as a
   dependency but only uses it for model conversion. Install with `--no-deps`.
3. **ffmpeg is not needed** as long as the engine hands Whisper sample arrays
   (it does today). Passing a file path shells out to `ffmpeg`.
4. **Entitlements are not inherited.** Runtime exceptions (JIT and friends) must
   be on the Python binary. Privacy entitlements (mic, Apple Events) are checked
   on the responsible process, which is the host app. So privacy entitlements go
   on `Friday`, and nothing goes on Python.
5. **Never write into the bundle.** The child runs with `-I -B`, bytecode is
   compiled at build time, and caches point at Application Support.
6. **MLX's `mlx.metallib` is 204 MB**, half of the bundle. It loads fine from
   inside the signed bundle; no lookup problem.

## Numbers

| Metric | Value |
|---|---|
| `Friday.app`, MLX Whisper stack only, real numba | 546 MB |
| `Friday.app`, numba stand-in | **404 MB** (mlx 238, scipy 67, CPython ~60, numpy 19) |
| DMG (LZMA) of the 404 MB app | **117 MB** (budget 300 MB) |
| Speech model (`whisper-large-v3-turbo`), downloaded on first run | 1.5 GB |
| Files in bundle / Mach-O files to sign | 5,038 / 145 |
| Build from scratch (uv cache warm) | ~9 s |
| Launch → first transcription done, first run after signing | 3.95 s |
| Launch → first transcription done, later runs | **1.8 s** (budget for launch → listening: 8 s) |
| Import `mlx_whisper` (later runs) | 0.55 s |
| Model load + first transcription of a 1.7 s clip | 0.6–0.8 s |
| Warm transcription of the same clip | 0.40–0.43 s |

Not measured: size with the full engine (pipecat, Silero VAD, ElevenLabs
client, PortAudio). Expect roughly +80–120 MB unpacked; M1 measures it.
Start-up after a reboot (cold disk cache) and the dev build's latency baseline
were also not measured, because the live Friday must not be restarted.

## Decisions

- **Runtime:** embedded python-build-standalone 3.12, taken from `uv python`.
- **Mic:** stays in the engine process.
- **Entitlements:** `device.audio-input`, `automation.apple-events` on the host.
  Nothing on Python. No JIT, no `disable-library-validation`.
- **Signing layout:** sign each `.so`/`.dylib`, then `python3.12` with its own
  identifier (`<bundle id>.python`), then the app. `codesign --verify --deep
  --strict` passes.
- **Bundle id:** spike used `com.ronnie434.Friday.spike`. Proposal stays
  `com.ronnie434.Friday`; Ronak to confirm.

## Open

1. **Developer ID certificate.** The keychain has an Apple Development
   certificate for `JRBD76VZ75`, and a Developer ID Application certificate
   that belongs to a different, unrelated team, which Friday must not use.
   A Developer ID Application certificate for `JRBD76VZ75` is needed before
   notarizing.
2. **Notarization credentials.** No App Store Connect API key is on this Mac.
   A new team key for Friday is needed (plan, section 7).
3. **Clean-Mac test** after 1 and 2: notarize, staple, download through Safari
   on a Mac or VM that has never seen the app.
4. **Real capture after "Allow".** The prompt was confirmed in the tccd log and
   then dismissed. Recording non-silent audio after allowing is still to be
   seen once.
5. **PortAudio.** The spike used `sounddevice` (ships its own PortAudio). The
   engine uses PyAudio through pipecat; M1 picks one and bundles the library.
