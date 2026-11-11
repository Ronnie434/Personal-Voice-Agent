"""Friday's voices: ElevenLabs when there is a key, a local voice otherwise or as backup."""

import asyncio
import re
import tempfile
import wave
from collections.abc import AsyncGenerator
from pathlib import Path

from loguru import logger
from pipecat.audio.utils import create_stream_resampler
from pipecat.frames.frames import ErrorFrame, Frame, TTSAudioRawFrame
from pipecat.services.tts_service import TTSService

from . import config

# ElevenLabs reports running out of credits, a bad key or a blocked account as
# ordinary errors it might recover from, so the service keeps retrying and
# Friday goes silent. These say it won't come back on its own.
_ELEVENLABS_DEAD = re.compile(
    r"quota|credits|unauthori[sz]ed|invalid.?api.?key|payment.?required|\b40[12]\b|"
    r"\b429\b|rate.?limit|too many (concurrent )?requests|detected_unusual_activity",
    re.IGNORECASE,
)
_ELEVENLABS_AUTH = re.compile(r"unauthori[sz]ed|invalid.?api.?key|\b401\b", re.IGNORECASE)


def elevenlabs_warning(error_text: str) -> str:
    """The protocol warning code for an ElevenLabs failure."""
    return "tts_auth" if _ELEVENLABS_AUTH.search(error_text) else "tts_quota"


def make_elevenlabs_tts():
    """ElevenLabs TTS that gives up for good on errors retrying can't fix,
    so the voice switcher fails over to the backup voice instead of going silent."""
    from pipecat.services.elevenlabs.tts import ElevenLabsTTSService

    class ElevenLabsWithFailover(ElevenLabsTTSService):
        last_error = ""

        async def push_error_frame(self, error, force_treat_as_permanent=False):
            text = f"{error.error} {error.exception or ''}"
            if _ELEVENLABS_DEAD.search(text):
                force_treat_as_permanent = True
                type(self).last_error = text
            await super().push_error_frame(error, force_treat_as_permanent)

    return ElevenLabsWithFailover(
        api_key=config.ELEVENLABS_API_KEY,
        settings=ElevenLabsTTSService.Settings(
            voice=config.ELEVENLABS_VOICE_ID, model=config.ELEVENLABS_MODEL
        ),
    )


class SystemVoiceTTS(TTSService):
    """The Mac's own voice, through `say`. Needs no download, key or network."""

    RATE = 22050

    def __init__(self, *, voice: str = "", **kwargs):
        super().__init__(push_start_frame=True, push_stop_frames=True, **kwargs)
        self._voice = voice
        self._resampler = create_stream_resampler()

    def can_generate_metrics(self) -> bool:
        return False

    async def synthesize(self, text: str) -> bytes:
        """Return `text` spoken as 16-bit mono PCM at RATE. Plays nothing."""
        with tempfile.TemporaryDirectory(prefix="friday-say-") as folder:
            out = Path(folder) / "speech.wav"
            cmd = ["/usr/bin/say", "-o", str(out), f"--data-format=LEI16@{self.RATE}"]
            if self._voice:
                cmd += ["-v", self._voice]
            # After "--" nothing in the text can be taken for an option.
            proc = await asyncio.create_subprocess_exec(
                *cmd, "--", text, stderr=asyncio.subprocess.PIPE
            )
            _, err = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError(f"say failed: {err.decode(errors='replace').strip()[:200]}")
            with wave.open(str(out)) as clip:
                return clip.readframes(clip.getnframes())

    async def run_tts(self, text: str, context_id: str) -> AsyncGenerator[Frame, None]:
        try:
            pcm = await self.synthesize(text)
            audio = await self._resampler.resample(pcm, self.RATE, self.sample_rate)
            # In pieces, so an interruption stops it mid-sentence.
            step = self.sample_rate // 5 * 2
            for start in range(0, len(audio), step):
                yield TTSAudioRawFrame(
                    audio=audio[start : start + step],
                    sample_rate=self.sample_rate,
                    num_channels=1,
                    context_id=context_id,
                )
        except Exception as e:
            yield ErrorFrame(error=f"System voice failed: {e}")


def make_backup_tts() -> tuple[TTSService, str]:
    """The local voice and what to call it in the log."""
    if config.BACKUP_VOICE == "kokoro":
        try:
            from pipecat.services.kokoro.tts import KokoroTTSService

            return (
                KokoroTTSService(
                    settings=KokoroTTSService.Settings(voice=config.KOKORO_VOICE),
                    # Default is 3s to first audio, which a busy machine can
                    # miss; the reply is then dropped in silence.
                    stop_frame_timeout_s=20.0,
                ),
                f"local Kokoro {config.KOKORO_VOICE}",
            )
        except Exception as e:  # not installed (the app bundle), or its model is missing
            logger.warning(f"Kokoro voice unavailable ({e}), using the system voice")
    return (
        SystemVoiceTTS(voice=config.SYSTEM_VOICE, stop_frame_timeout_s=20.0),
        f"system voice {config.SYSTEM_VOICE or '(default)'}",
    )


def list_devices() -> dict:
    """Microphones and speakers by name, and which are the defaults."""
    import pyaudio

    audio = pyaudio.PyAudio()
    try:
        inputs, outputs = [], []
        for index in range(audio.get_device_count()):
            info = audio.get_device_info_by_index(index)
            entry = {"index": index, "name": info["name"]}
            if info.get("maxInputChannels", 0) > 0:
                inputs.append(entry)
            if info.get("maxOutputChannels", 0) > 0:
                outputs.append(entry)

        def default(getter):
            try:
                return getter()["name"]
            except OSError:
                return None

        return {
            "inputs": inputs,
            "outputs": outputs,
            "default_input": default(audio.get_default_input_device_info),
            "default_output": default(audio.get_default_output_device_info),
        }
    finally:
        audio.terminate()


def pick_device(wanted: str, devices: list[dict]) -> int | None:
    """Index of the device called `wanted` (exact, else containing it), None for the default."""
    wanted = wanted.strip().lower()
    if not wanted:
        return None
    if wanted.isdigit() and any(d["index"] == int(wanted) for d in devices):
        return int(wanted)
    for exact in (True, False):
        for device in devices:
            name = device["name"].lower()
            if name == wanted if exact else wanted in name:
                return device["index"]
    logger.warning(f"No audio device matching {wanted!r}, using the system default")
    return None
