# Additional Turkish voice profiles (opt-in, fully local)

The app uses Apple's installed `say` and AVSpeech voices. On macOS, an available voice like **Yelda** remains supported. To add more female/male models, the experimental branch also supports local **Piper VITS ONNX** voice files.

## Local model discovery

1. Install a compatible **Piper CLI** for your own Mac using its official installation instructions (for example `pipx install piper-tts` if available for your platform, or a locally supported binary). The app looks for `piper` at `/opt/homebrew/bin/piper`, `/usr/local/bin/piper`, `~/.local/bin/piper`, or an explicit `TIHULU_PIPER_BINARY` environment variable.
2. In **Voice**, choose Turkish and click **Open Local Voice Folder**.
3. Put each downloaded model's **`.onnx` plus corresponding `.onnx.json`** in this folder. Files must keep the matching filenames: `model.onnx` / `model.onnx.json`.
4. Click **Refresh Profiles**. Each installed model appears in the Voice picker as **Piper (local)**. Select it and choose **Speak on Trackpad**.

The local folder is within `~/Library/Application Support/Tihulu Trackpad & M. Mouse Instrument/Voices/tr_TR/`. No private recordings or typed speech are uploaded.

## Example third-party Turkish models

- **Ilkiz (female, author's MIT label):** https://huggingface.co/ilkeraktuna/piper-tts-tr-ilkiz-medium
- **Fahrettin (male, community voice):** https://huggingface.co/Derur/piper-tts-models/tree/main/tr/fahrettin
- **Dfki (male):** https://huggingface.co/rhasspy/piper-voices/tree/main/tr/tr_TR/dfki/medium — *its dataset Model Card declares CC BY-NC-SA 4.0*, so check usage restrictions carefully before choosing it.

Model origin, license and fit vary; these are discovery links, not automatically installed or redistributed assets. The app does **not** automatically download voice weights, nor claim any model's third-party license as the application's own.

## Runtime details

Selected Piper binary receives text only via standard input. The voice is rendered into a temporary WAV, resampled to 16 kHz locally, then passed to the original haptic speech analyzer. The temporary WAV is removed when processing ends. If the Piper executable or matching ONNX configuration is missing, the application provides an actionable error rather than claiming the voice is installed.

## Acceptance

Test an installed male and female model on the target Mac and verify both produce distinct local audio and haptic events. Check licensing/attribution separately before packaging any voice weights. macOS CI validates the Swift build but cannot certify a particular user-provided model or installed Piper binary.
