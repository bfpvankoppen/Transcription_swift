# Semantic Search for Transcription History

> **Status:** Design — not yet implemented

## Goal

Replace the simple substring search in History with semantic search powered by a small local embedding model. Users can search by meaning, not just exact words — e.g., searching "meeting about budget" finds transcriptions that discuss finances even if "budget" never appears.

## Model

**all-MiniLM-L6-v2** (INT8 quantized ONNX)
- ~6MB model file
- 384-dimensional embeddings
- Runs on CPU via ONNX Runtime (already linked in the app)
- Strong sentence similarity quality for its size
- Source: Hugging Face (ONNX format available)

## How It Works

1. When a transcription is saved to history, embed the text → 384-dim float vector
2. Store the embedding alongside the history entry
3. When the user types a search query, embed the query → 384-dim vector
4. Compute cosine similarity between query vector and all stored vectors
5. Rank results by similarity score, show top matches

## Key Components Needed

### 1. WordPiece Tokenizer (Swift)
- MiniLM requires WordPiece tokenization before inference
- Need `vocab.txt` (~230KB) bundled with the model
- Implement: lowercase → split → subword tokenize → token IDs
- Add `[CLS]` and `[SEP]` special tokens, pad/truncate to max length (128 tokens is fine for short transcriptions)

### 2. Embedding Engine
- Load ONNX model via ONNX Runtime C API (already linked via sherpa-onnx)
- Input: token IDs + attention mask → Output: 384-dim embedding
- Mean pooling over token outputs to get sentence embedding
- Normalize to unit vector for fast cosine similarity (dot product)

### 3. Embedding Storage
- Store embeddings in a separate file: `~/.config/parkeet/embeddings.json`
- Map: `entry UUID → [Float]` (384 floats per entry)
- Purge embeddings when history entries are purged
- Re-embed on model upgrade (version-stamp the file)

### 4. Search Integration
- Enhance existing search bar in HistoryView — no extra UI
- Keyword matches (substring) shown first, semantic matches below
- Show similarity score as subtle indicator (e.g., "92% match")
- Embed query on each keystroke (debounced ~300ms) — MiniLM inference is fast enough

## Files to Bundle

| File | Size | Purpose |
|------|------|---------|
| `all-MiniLM-L6-v2-int8.onnx` | ~6MB | Embedding model |
| `vocab.txt` | ~230KB | WordPiece vocabulary |

## Integration Points

- **HistoryStore.swift** — trigger embedding on `add(entry:)`, store/load embeddings
- **HistoryView.swift** — replace substring filter with semantic ranking
- **New: EmbeddingEngine.swift** — ONNX model loading, tokenization, inference
- **Package.swift** — no new dependencies (uses existing onnxruntime link)

## Open Design Questions (for next session)

- Search UX: smart unified bar vs toggle vs separate page?
- Should long texts (meetings) be chunked into multiple embeddings per entry?
- Fallback behavior when model hasn't loaded yet?
- Background embedding vs synchronous on save?

## Resources

- Model: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- ONNX export: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/tree/main/onnx
