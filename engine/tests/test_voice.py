"""Backup voice and device choice. Nothing here plays sound."""

from friday_engine import voice


async def test_system_voice_makes_audio_without_playing_it():
    tts = voice.SystemVoiceTTS()
    pcm = await tts.synthesize("--version is not an option here")
    seconds = len(pcm) / 2 / tts.RATE
    assert 1.0 < seconds < 6.0
    assert any(pcm)


def test_pick_device():
    devices = [{"index": 0, "name": "MacBook Pro Microphone"}, {"index": 3, "name": "CMTECK"},
               {"index": 5, "name": "AirPods Pro"}]
    assert voice.pick_device("", devices) is None
    assert voice.pick_device("CMTECK", devices) == 3
    assert voice.pick_device("airpods", devices) == 5
    assert voice.pick_device("5", devices) == 5
    assert voice.pick_device("Blue Yeti", devices) is None


def test_elevenlabs_failures_map_to_warnings():
    assert voice.elevenlabs_warning("401 Unauthorized: invalid api key") == "tts_auth"
    assert voice.elevenlabs_warning("quota_exceeded: no credits left") == "tts_quota"
