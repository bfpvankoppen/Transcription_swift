"""
Transcription engine using NVIDIA Parakeet TDT 0.6B v3 (INT8 ONNX).

Multilingual (25 languages) with automatic language detection.
Uses sherpa-onnx for lightweight, offline inference on Apple Silicon.
"""

from __future__ import annotations

import logging
import os
import tarfile
import time as _time
import urllib.request

import numpy as np
import sherpa_onnx

logger = logging.getLogger(__name__)

# Model directory relative to project root
_PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_MODELS_DIR = os.path.join(_PROJECT_DIR, "models")
_MODEL_NAME = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
_MODEL_DIR = os.path.join(_MODELS_DIR, _MODEL_NAME)
_MODEL_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
    f"{_MODEL_NAME}.tar.bz2"
)


class Transcriber:
    """Wraps the Parakeet TDT model for multilingual speech-to-text."""

    def __init__(self) -> None:
        self._recognizer: sherpa_onnx.OfflineRecognizer | None = None

    @property
    def is_loaded(self) -> bool:
        return self._recognizer is not None

    @staticmethod
    def is_model_cached() -> bool:
        """Check if the model files are already downloaded."""
        encoder = os.path.join(_MODEL_DIR, "encoder.int8.onnx")
        return os.path.isfile(encoder)

    def load_model(self, on_status: callable = None) -> None:
        """Download (if needed) and load the Parakeet model.

        Args:
            on_status: Optional callback(message: str) for progress updates.
        """
        if not self.is_model_cached():
            logger.info("Model not cached, downloading...")
            if on_status:
                on_status("Downloading model (~640MB)...")
            self._download_model(on_status)
        else:
            logger.info("Loading model from cache")
            if on_status:
                on_status("Loading model from cache...")

        if on_status:
            on_status("Initializing speech recognizer...")

        t0 = _time.monotonic()
        self._recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=os.path.join(_MODEL_DIR, "encoder.int8.onnx"),
            decoder=os.path.join(_MODEL_DIR, "decoder.int8.onnx"),
            joiner=os.path.join(_MODEL_DIR, "joiner.int8.onnx"),
            tokens=os.path.join(_MODEL_DIR, "tokens.txt"),
            num_threads=4,
            sample_rate=16000,
            feature_dim=80,
            decoding_method="greedy_search",
            model_type="nemo_transducer",
        )
        logger.info("Model loaded in %.1fs", _time.monotonic() - t0)

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        """Transcribe a 1-D numpy float32 audio array to text."""
        if self._recognizer is None:
            raise RuntimeError("Model not loaded. Call load_model() first.")

        if len(audio) == 0:
            logger.warning("Transcribe called with empty audio")
            return ""

        t0 = _time.monotonic()
        stream = self._recognizer.create_stream()
        stream.accept_waveform(sample_rate, audio)
        self._recognizer.decode_stream(stream)
        text = stream.result.text.strip()
        elapsed = _time.monotonic() - t0
        logger.info("Transcription done in %.2fs: %d chars", elapsed, len(text))
        return text

    @staticmethod
    def _download_model(on_status: callable = None) -> None:
        """Download and extract the model archive."""
        os.makedirs(_MODELS_DIR, exist_ok=True)
        archive_path = os.path.join(_MODELS_DIR, f"{_MODEL_NAME}.tar.bz2")

        # Download with progress
        def _reporthook(block_num, block_size, total_size):
            if on_status and total_size > 0:
                downloaded = block_num * block_size
                pct = min(100, int(downloaded * 100 / total_size))
                mb = downloaded / (1024 * 1024)
                total_mb = total_size / (1024 * 1024)
                on_status(f"Downloading model... {mb:.0f}/{total_mb:.0f}MB ({pct}%)")

        urllib.request.urlretrieve(_MODEL_URL, archive_path, _reporthook)

        if on_status:
            on_status("Extracting model...")

        with tarfile.open(archive_path, "r:bz2") as tar:
            tar.extractall(path=_MODELS_DIR)

        # Clean up archive
        os.unlink(archive_path)


if __name__ == "__main__":
    import time

    print("Loading Parakeet model (first run downloads ~640MB)...")
    t0 = time.time()
    transcriber = Transcriber()
    transcriber.load_model(on_status=lambda msg: print(f"  {msg}"))
    print(f"Model loaded in {time.time() - t0:.1f}s")

    # Quick test with a short silence
    silence = np.zeros(16000, dtype=np.float32)  # 1 second of silence
    result = transcriber.transcribe(silence)
    print(f"Silence transcription: '{result}'")
    print("Transcriber is ready.")
