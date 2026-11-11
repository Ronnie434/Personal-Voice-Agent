#!/bin/bash
# M0 spike: hand-build Friday.app with an embedded CPython 3.12 + mlx-whisper.
# Usage: spike/build.sh   (output: build/spike/Friday.app, unsigned)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/spike; APP=$OUT/Friday.app; RES=$APP/Contents/Resources
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$RES/engine"

# 1. Runtime: uv's managed CPython is python-build-standalone.
uv python install 3.12 >/dev/null
SRC=$(dirname "$(dirname "$(uv python find --managed-python 3.12)")")
cp -R "$(cd "$SRC" && pwd -P)" "$RES/python"
PY=$RES/python/bin/python3.12

# 2. Packages. No torch: mlx-whisper lists it but only uses it to convert models.
uv pip install -q --python "$PY" --break-system-packages --no-deps mlx-whisper
uv pip install -q --python "$PY" --break-system-packages \
  mlx numpy scipy tqdm more-itertools tiktoken huggingface_hub sounddevice

# numba is only used to speed up word timestamps, which Friday does not use, and
# its JIT cannot run under the hardened runtime without an extra entitlement.
# A no-op stand-in keeps mlx_whisper importable and saves ~145 MB.
mkdir -p "$RES/python/lib/python3.12/site-packages/numba"
cat > "$RES/python/lib/python3.12/site-packages/numba/__init__.py" <<'PYEOF'
"""Stand-in for numba inside Friday.app: decorators run the plain Python function."""


def jit(*args, **kwargs):
    if args and callable(args[0]) and not kwargs:
        return args[0]
    return lambda fn: fn


njit = jit
PYEOF

# 3. Prune what a shipped app never needs.
SP=$RES/python/lib/python3.12
rm -rf "$SP"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} "$SP"/site-packages/{pip,setuptools}* \
  "$RES"/python/lib/{tcl*,tk*,itcl*,thread*,libtcl*,libtk*,pkgconfig} "$RES"/python/{include,share} \
  "$SP"/config-3.12-darwin "$SP"/lib-dynload/_tkinter*.so
find "$RES/python" -name tests -type d -path '*site-packages*' -prune -exec rm -rf {} +
find "$RES/python" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$RES/python/bin" -type f ! -name 'python3.12' -delete
find "$RES/python/bin" -type l ! -name 'python3' -delete

# 4. Precompile so the signed bundle is never written to at run time.
"$PY" -I -m compileall -q -j 0 "$RES/python/lib" >/dev/null || true

# 5. Engine, test clip, host.
cp spike/engine/spike_engine.py "$RES/engine/"
say -o "$OUT/hello.aiff" "Hey Friday, what time is it"
afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/hello.aiff" "$RES/engine/hello.wav"
cp spike/Info.plist "$APP/Contents/Info.plist"
swiftc -O -target arm64-apple-macos14.0 spike/host/main.swift -o "$APP/Contents/MacOS/Friday"
du -sh "$APP" "$RES/python"
