"""
Transcription engine using NVIDIA Parakeet 1.1b RNNT Multilingual ASR.

Loads the model once at startup and keeps it in memory.
Transcribes numpy audio arrays to text.
"""

from __future__ import annotations

import os
import tempfile

import numpy as np
import soundfile as sf
import torch


class Transcriber:
    """Wraps the Parakeet RNNT model for speech-to-text."""

    MODEL_NAME = "nvidia/parakeet-1.1b-rnnt-multilingual-asr"

    def __init__(self) -> None:
        self._model = None

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    @staticmethod
    def is_model_cached() -> bool:
        """Check if the model is already downloaded in the HuggingFace cache."""
        try:
            from huggingface_hub import try_to_load_from_cache
            result = try_to_load_from_cache(
                "nvidia/parakeet-1.1b-rnnt-multilingual-asr",
                filename="model_config.yaml",
            )
            return result is not None and isinstance(result, str)
        except Exception:
            return False

    def load_model(self, on_status: callable = None) -> None:
        """Download (if needed) and load the Parakeet model.

        Args:
            on_status: Optional callback(message: str) for progress updates.
        """
        import nemo.collections.asr as nemo_asr

        if on_status:
            if self.is_model_cached():
                on_status("Loading model from cache...")
            else:
                on_status("Downloading model (~500MB)...")

        self._model = nemo_asr.models.EncDecRNNTBPEModel.from_pretrained(
            model_name=self.MODEL_NAME
        )
        self._model.eval()

        if on_status:
            on_status("Optimizing model for Apple Silicon...")

        # Try MPS (Metal) for Apple Silicon acceleration, fall back to CPU
        if torch.backends.mps.is_available():
            try:
                self._model = self._model.to(torch.device("mps"))
            except Exception:
                self._model = self._model.to(torch.device("cpu"))
        else:
            self._model = self._model.to(torch.device("cpu"))

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        """Transcribe a 1-D numpy float32 audio array to text."""
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load_model() first.")

        if len(audio) == 0:
            return ""

        # NeMo transcribe() expects file paths, so write a temp WAV
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            sf.write(f.name, audio, sample_rate)
            tmp_path = f.name

        try:
            results = self._model.transcribe([tmp_path], batch_size=1)
            # Handle both NeMo 1.x (List[str]) and 2.x (List[Hypothesis])
            if isinstance(results[0], str):
                return results[0]
            return results[0].text if hasattr(results[0], "text") else str(results[0])
        finally:
            os.unlink(tmp_path)


if __name__ == "__main__":
    import time

    print("Loading Parakeet model (first run downloads ~500MB)...")
    t0 = time.time()
    transcriber = Transcriber()
    transcriber.load_model()
    print(f"Model loaded in {time.time() - t0:.1f}s")

    # Quick test with a short silence
    silence = np.zeros(16000, dtype=np.float32)  # 1 second of silence
    result = transcriber.transcribe(silence)
    print(f"Silence transcription: '{result}'")
    print("Transcriber is ready.")
