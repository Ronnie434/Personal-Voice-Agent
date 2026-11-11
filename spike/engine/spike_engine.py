"""M0 spike engine: runs inside the embedded CPython as a child of the Swift host.

Modes:
  transcribe <wav> <model>   import mlx_whisper, transcribe twice (cold, warm)
  mic                        open the default input for 3 s and report level
Prints one JSON line on stdout.
"""
import json
import sys
import time

t0 = time.time()
mode = sys.argv[1]
out = {"mode": mode, "python": sys.version.split()[0], "executable": sys.executable}

try:
    if mode == "transcribe":
        wav, model = sys.argv[2], sys.argv[3]
        import wave

        import mlx.core as mx
        import mlx_whisper
        import numpy as np

        # Same as the real engine: hand Whisper samples, not a path (a path needs ffmpeg).
        with wave.open(wav) as w:
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        wav = pcm.astype(np.float32) / 32768.0
        out["clip_s"] = round(len(wav) / 16000, 2)

        out["import_s"] = round(time.time() - t0, 3)
        out["metal"] = bool(mx.metal.is_available())
        out["torch_loaded"] = "torch" in sys.modules
        out["numba_loaded"] = "numba" in sys.modules
        t1 = time.time()
        r = mlx_whisper.transcribe(wav, path_or_hf_repo=model, language="en")
        out["cold_transcribe_s"] = round(time.time() - t1, 3)
        t2 = time.time()
        r = mlx_whisper.transcribe(wav, path_or_hf_repo=model, language="en")
        out["warm_transcribe_s"] = round(time.time() - t2, 3)
        out["text"] = r["text"].strip()
        if "--words" in sys.argv:
            t3 = time.time()
            r = mlx_whisper.transcribe(
                wav, path_or_hf_repo=model, language="en", word_timestamps=True
            )
            out["word_timestamps_s"] = round(time.time() - t3, 3)
            out["words"] = sum(len(s.get("words", [])) for s in r["segments"])
    elif mode == "mic":
        import numpy as np
        import sounddevice as sd

        out["device"] = sd.query_devices(kind="input")["name"]
        rec = sd.rec(int(3 * 16000), samplerate=16000, channels=1, dtype="float32")
        sd.wait()
        out["rms"] = float(np.sqrt((rec**2).mean()))
        out["peak"] = float(np.abs(rec).max())
        out["got_audio"] = out["peak"] > 0
    out["ok"] = True
except BaseException as e:  # report everything, this is a spike
    import traceback

    out["ok"] = False
    out["error"] = f"{type(e).__name__}: {e}"
    out["trace"] = traceback.format_exc()[-1500:]

out["total_s"] = round(time.time() - t0, 3)
print(json.dumps(out), flush=True)
