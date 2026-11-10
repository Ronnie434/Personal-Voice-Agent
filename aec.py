"""Echo cancellation: removes the agent's own voice from what the microphone hears.

Without it, on laptop speakers the mic hears the agent talking as one unbroken
stretch of speech, so nothing the user says over it gets through until the
agent has finished. With it, the user can cut in mid-sentence.

Uses the WebRTC audio processing module that ships with the `livekit` package.
It needs two streams in 10 ms frames: what is about to be played (the
reference) and what the microphone captured (which gets cleaned).
"""

from livekit import rtc
from loguru import logger
from pipecat.audio.filters.base_audio_filter import BaseAudioFilter
from pipecat.frames.frames import FilterControlFrame, OutputAudioRawFrame


class EchoCanceller(BaseAudioFilter):
    """Pipecat input filter that cancels speaker echo out of the mic signal."""

    def __init__(self):
        self._apm = rtc.AudioProcessingModule(
            echo_cancellation=True,
            noise_suppression=True,
            high_pass_filter=True,
            auto_gain_control=False,
        )
        self._mic_rate = 16000
        self._mic_pending = bytearray()
        self._speaker_pending = bytearray()

    async def start(self, sample_rate: int):
        self._mic_rate = sample_rate

    async def stop(self):
        pass

    async def process_frame(self, frame: FilterControlFrame):
        pass

    async def filter(self, audio: bytes) -> bytes:
        """Clean one chunk of microphone audio (16-bit mono PCM)."""
        self._mic_pending += audio
        frame_bytes = self._mic_rate // 100 * 2
        out = bytearray()
        while len(self._mic_pending) >= frame_bytes:
            chunk = bytearray(self._mic_pending[:frame_bytes])
            del self._mic_pending[:frame_bytes]
            frame = rtc.AudioFrame(chunk, self._mic_rate, 1, frame_bytes // 2)
            try:
                self._apm.process_stream(frame)
                out += bytes(frame.data)
            except Exception as e:  # never lose mic audio over a filter error
                logger.warning(f"Echo cancellation failed on a mic frame: {e}")
                out += chunk
        return bytes(out)

    def feed_speaker(self, audio: bytes, sample_rate: int):
        """Tell the canceller what is about to come out of the speaker."""
        self._speaker_pending += audio
        frame_bytes = sample_rate // 100 * 2
        while len(self._speaker_pending) >= frame_bytes:
            chunk = bytearray(self._speaker_pending[:frame_bytes])
            del self._speaker_pending[:frame_bytes]
            try:
                self._apm.process_reverse_stream(
                    rtc.AudioFrame(chunk, sample_rate, 1, frame_bytes // 2)
                )
            except Exception as e:
                logger.warning(f"Echo cancellation failed on a speaker frame: {e}")

    def attach_to_output(self, output_transport):
        """Feed every audio frame the transport plays into the canceller first."""
        write = output_transport.write_audio_frame

        async def write_and_feed(frame: OutputAudioRawFrame) -> bool:
            self.feed_speaker(frame.audio, frame.sample_rate)
            return await write(frame)

        output_transport.write_audio_frame = write_and_feed
