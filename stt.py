"""Local Whisper speech-to-text, with Pipecat's hallucination filter replaced."""

import asyncio
from collections.abc import AsyncGenerator

import numpy as np
from loguru import logger
from pipecat.frames.frames import ErrorFrame, Frame, TranscriptionFrame
from pipecat.services.whisper.stt import WhisperSTTServiceMLX
from pipecat.utils.time import time_now_iso8601

# Past this, Whisper is close to sure the clip is noise rather than speech.
NO_SPEECH_PROB = 0.9


class WakeFriendlyWhisperSTT(WhisperSTTServiceMLX):
    """WhisperSTTServiceMLX that doesn't drop the bare wake phrase.

    Pipecat's version skips any segment whose compression ratio is exactly
    0.5555555555555556, meant to catch one known hallucination. That ratio is
    10 / 18, which every 10-character transcript produces, and " Hey agent" is
    10 characters, so a bare wake phrase was thrown away most of the time.
    This transcribes the same way without that test.
    """

    async def run_stt(self, audio: bytes) -> AsyncGenerator[Frame, None]:
        try:
            import mlx_whisper

            await self.start_processing_metrics()
            samples = np.frombuffer(audio, dtype=np.int16).astype(np.float32) / 32768.0
            result = await asyncio.to_thread(
                mlx_whisper.transcribe,
                samples,
                path_or_hf_repo=self._settings.model,
                temperature=0.0,
                language="en",
            )
            await self.stop_processing_metrics()

            text = " ".join(
                segment.get("text", "").strip()
                for segment in result.get("segments", [])
                if segment.get("no_speech_prob", 0.0) < NO_SPEECH_PROB
            ).strip()
            if text:
                logger.debug(f"Transcription: [{text}]")
                yield TranscriptionFrame(text, self._user_id, time_now_iso8601())
        except Exception as e:
            yield ErrorFrame(error=f"Whisper failed: {e}")
