"""
File-based audio transcription with chunked processing and progress reporting.

Converts audio files to 16kHz mono WAV via macOS afconvert,
splits into 30-second chunks, and transcribes each chunk sequentially.
"""

from __future__ import annotations

import logging
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import numpy as np
import soundfile as sf

from src.transcriber import Transcriber

logger = logging.getLogger(__name__)

CHUNK_DURATION_SEC = 30
SAMPLE_RATE = 16000
SAMPLE_CHUNK_SEC = 2


@dataclass
class FileInfo:
    """Metadata about the source audio file."""

    path: Path
    duration_sec: float
    sample_rate: int
    channels: int


@dataclass
class TranscriptionProgress:
    """Progress update emitted after each chunk."""

    chunks_done: int
    total_chunks: int
    elapsed_sec: float
    estimated_remaining_sec: float
    text_so_far: str


class FileTranscriber:
    """Converts and transcribes audio files in chunks with progress reporting."""

    def __init__(self, transcriber: Transcriber) -> None:
        self._transcriber = transcriber
        self._cancelled = False
        self._temp_wav: Optional[str] = None

    def cancel(self) -> None:
        """Request cancellation. Takes effect after the current chunk finishes."""
        logger.info("File transcription cancellation requested")
        self._cancelled = True

    @property
    def is_cancelled(self) -> bool:
        return self._cancelled

    def convert_to_wav(self, input_path: Path) -> Path:
        """Convert any supported audio file to 16kHz mono WAV using afconvert.

        Returns path to temporary WAV file. Caller must clean up via cleanup().
        """
        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        self._temp_wav = tmp_path

        cmd = [
            "afconvert",
            "-f", "WAVE",
            "-d", "LEF32@16000",
            "-c", "1",
            str(input_path),
            tmp_path,
        ]
        logger.info("Converting audio: %s", " ".join(cmd))
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(f"afconvert failed: {result.stderr.strip()}")

        logger.info("Conversion complete: %s -> %s", input_path, tmp_path)
        return Path(tmp_path)

    def get_file_info(self, wav_path: Path) -> FileInfo:
        """Read duration and metadata from a WAV file (header only)."""
        info = sf.info(str(wav_path))
        logger.debug(
            "File info: duration=%.1fs, sr=%d, channels=%d",
            info.duration, info.samplerate, info.channels,
        )
        return FileInfo(
            path=wav_path,
            duration_sec=info.duration,
            sample_rate=info.samplerate,
            channels=info.channels,
        )

    def estimate_speed(self, wav_path: Path, file_info: FileInfo) -> float:
        """Transcribe a 2-second sample and extrapolate total processing time.

        Returns estimated total transcription time in seconds.
        Runs synchronously — caller should invoke from a background thread.
        """
        max_frames = int(file_info.duration_sec * SAMPLE_RATE)
        sample_frames = min(SAMPLE_CHUNK_SEC * SAMPLE_RATE, max_frames)
        audio, _ = sf.read(str(wav_path), frames=sample_frames, dtype="float32")
        if audio.ndim > 1:
            audio = audio[:, 0]

        t0 = time.monotonic()
        self._transcriber.transcribe(audio, SAMPLE_RATE)
        sample_wall_sec = time.monotonic() - t0

        sample_audio_sec = len(audio) / SAMPLE_RATE
        if sample_audio_sec <= 0:
            return 0.0

        speed_ratio = sample_wall_sec / sample_audio_sec
        estimated_total = speed_ratio * file_info.duration_sec
        logger.info(
            "Speed estimate: %.2fs sample took %.2fs (ratio=%.2fx), "
            "total estimated=%.1fs for %.1fs audio",
            sample_audio_sec, sample_wall_sec, speed_ratio,
            estimated_total, file_info.duration_sec,
        )
        return estimated_total

    def transcribe_file(
        self,
        wav_path: Path,
        on_progress: Callable[[TranscriptionProgress], None],
        on_complete: Callable[[str], None],
        on_error: Callable[[str], None],
    ) -> None:
        """Transcribe the entire WAV file in 30-second chunks.

        Runs synchronously — caller should invoke from a background thread.
        Calls on_progress after each chunk. Calls on_complete with full text,
        or on_error with error message. If cancelled, on_complete is called
        with partial text.
        """
        self._cancelled = False
        try:
            info = sf.info(str(wav_path))
            total_frames = info.frames
            chunk_frames = CHUNK_DURATION_SEC * SAMPLE_RATE
            total_chunks = max(1, -(-total_frames // chunk_frames))  # ceil div

            logger.info(
                "Starting file transcription: %d frames, %d chunks of %ds",
                total_frames, total_chunks, CHUNK_DURATION_SEC,
            )

            texts: list[str] = []
            t_start = time.monotonic()

            for i in range(total_chunks):
                if self._cancelled:
                    logger.info(
                        "Transcription cancelled at chunk %d/%d",
                        i + 1, total_chunks,
                    )
                    break

                start_frame = i * chunk_frames
                frames_to_read = min(chunk_frames, total_frames - start_frame)
                audio, _ = sf.read(
                    str(wav_path),
                    start=start_frame,
                    frames=frames_to_read,
                    dtype="float32",
                )
                if audio.ndim > 1:
                    audio = audio[:, 0]

                chunk_text = self._transcriber.transcribe(audio, SAMPLE_RATE)
                if chunk_text:
                    texts.append(chunk_text)

                elapsed = time.monotonic() - t_start
                chunks_done = i + 1
                sec_per_chunk = elapsed / chunks_done
                remaining = sec_per_chunk * (total_chunks - chunks_done)

                logger.debug(
                    "Chunk %d/%d done (%.1fs elapsed, ~%.1fs remaining)",
                    chunks_done, total_chunks, elapsed, remaining,
                )

                on_progress(TranscriptionProgress(
                    chunks_done=chunks_done,
                    total_chunks=total_chunks,
                    elapsed_sec=elapsed,
                    estimated_remaining_sec=remaining,
                    text_so_far=" ".join(texts),
                ))

            full_text = " ".join(texts)
            logger.info(
                "File transcription %s: %d chars from %d/%d chunks",
                "cancelled" if self._cancelled else "complete",
                len(full_text), len(texts), total_chunks,
            )
            on_complete(full_text)

        except Exception as e:
            logger.exception("File transcription failed")
            on_error(str(e))

    def cleanup(self) -> None:
        """Remove temporary WAV file if it exists."""
        if self._temp_wav and os.path.exists(self._temp_wav):
            try:
                os.unlink(self._temp_wav)
                logger.debug("Cleaned up temp WAV: %s", self._temp_wav)
            except OSError:
                logger.warning("Failed to clean up temp WAV: %s", self._temp_wav)
            self._temp_wav = None
