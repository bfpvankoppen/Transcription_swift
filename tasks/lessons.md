# Lessons Learned

## 2026-02-23: Model naming confusion
- **Mistake**: Used NVIDIA NIM API model name (`parakeet-1.1b-rnnt-multilingual-asr`) instead of HuggingFace repo name
- **Fix**: NIM API names and HuggingFace repo names are different. Always verify the exact repo exists on HuggingFace before using it
- **Rule**: When referencing models, verify the download source URL is accessible before writing code that depends on it

## 2026-02-23: NeMo model too large (2.5GB vs expected 500MB)
- **Mistake**: Assumed NeMo model would be ~500MB like the CoreML version SuperWhisper uses
- **Fix**: NeMo stores full-precision float32 weights. Switched to sherpa-onnx INT8 quantized version (642MB)
- **Rule**: Always check actual model file sizes on the download page before committing to a model/framework

## 2026-02-23: sherpa-onnx API differences
- **Mistake**: Used `recognizer.decode(stream)` — correct method is `decode_stream(stream)`
- **Mistake**: Didn't set `model_type="nemo_transducer"` — caused "vocab_size not in metadata" error
- **Rule**: Always check the actual API with `help()` or docs before assuming method names

## 2026-02-23: Qt Tool windows and macOS Spaces
- **Mistake**: Set `NSWindowCollectionBehaviorCanJoinAllSpaces` but Qt's NSPanel also had `MoveToActiveSpace` set (mutually exclusive bits)
- **Fix**: Must clear `MoveToActiveSpace` bit and apply AFTER `show()` since Qt resets behavior during window creation
- **Rule**: When overriding native window properties from Qt, always read-modify-write (don't blindly OR new flags) and apply AFTER show()

## 2026-02-25: macOS 26 activation policy vs all-Spaces overlay
- **Mistake**: Switched from `NSApplicationActivationPolicyAccessory` to `Regular` for Dock icon + Force Quit visibility. This broke the overlay — it no longer appeared on all Spaces.
- **Investigation**: Diagnostic proved that under Regular policy on macOS 26, NO window type (Qt Window, Qt Tool, native NSWindow) follows to other Spaces, regardless of `CanJoinAllSpaces` or any combination of behavior flags. The activation policy overrides all per-window Space behavior.
- **Fix**: Reverted to Accessory policy. Dock icon and all-Spaces overlay are mutually exclusive on macOS 26.
- **Rule**: On macOS 26, `NSApplicationActivationPolicyRegular` pins ALL app windows to one Space. If your app needs an overlay on all Spaces, you MUST use Accessory policy. Do not attempt to fix this with behavior flags — it's an OS-level restriction.

## 2026-02-25: pynput TSMGetInputSourceProperty crash on macOS 26
- **Mistake**: Stopped and restarted pynput listener when hotkey changed, which called `TSMGetInputSourceProperty` from a background thread
- **Fix**: Added `update_modifiers()` to hot-swap config on existing listener without restart
- **Rule**: On macOS 26+, never stop/restart a pynput listener at runtime. Hot-swap configuration instead.
