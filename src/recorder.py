"""
Audio recorder using sounddevice.

Records from the default microphone at 16 kHz mono float32.
Provides real-time amplitude levels for driving the waveform overlay.
"""

from __future__ import annotations

import threading

import numpy as np
import sounddevice as sd


class AudioRecorder:
    """Callback-based audio recorder with real-time level metering."""

    def __init__(self, sample_rate: int = 16000, channels: int = 1) -> None:
        self._sample_rate = sample_rate
        self._channels = channels
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._current_levels: list[float] = []
        self._lock = threading.Lock()

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    def start(self) -> None:
        """Start recording from the default microphone."""
        self._chunks = []
        self._current_levels = []
        self._stream = sd.InputStream(
            samplerate=self._sample_rate,
            channels=self._channels,
            dtype="float32",
            blocksize=int(self._sample_rate / 30),  # ~33ms blocks for 30fps
            callback=self._audio_callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        """Stop recording and return the complete audio as a 1-D numpy array."""
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        if self._chunks:
            audio = np.concatenate(self._chunks, axis=0)
            # Flatten to 1-D mono
            if audio.ndim > 1:
                audio = audio[:, 0]
            return audio
        return np.zeros((0,), dtype=np.float32)

    def get_levels(self, num_bars: int = 28) -> list[float]:
        """Return the most recent amplitude levels for the waveform display."""
        with self._lock:
            return list(self._current_levels)

    def _audio_callback(self, indata, frames, time_info, status) -> None:
        self._chunks.append(indata.copy())

        mono = indata[:, 0] if indata.ndim > 1 else indata.flatten()
        num_bars = 28
        segment_size = max(1, len(mono) // num_bars)
        levels = []
        for i in range(num_bars):
            start = i * segment_size
            end = min(start + segment_size, len(mono))
            segment = mono[start:end]
            rms = float(np.sqrt(np.mean(segment ** 2)))
            # Scale up for visibility (typical speech RMS is 0.01-0.1)
            scaled = min(1.0, rms * 8.0)
            levels.append(scaled)
        with self._lock:
            self._current_levels = levels


if __name__ == "__main__":
    import time

    print("Recording for 3 seconds... speak into your mic.")
    rec = AudioRecorder()
    rec.start()

    for _ in range(90):  # 3 seconds at 30fps
        time.sleep(1 / 30)
        levels = rec.get_levels()
        if levels:
            bar = "".join("█" if v > 0.1 else "░" for v in levels)
            print(f"\r  {bar}", end="", flush=True)

    audio = rec.stop()
    print(f"\n\nCaptured {len(audio)} samples ({len(audio)/16000:.1f}s)")
