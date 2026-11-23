# Trackpad Speaker Mode

NoSpeaker Studio provides two speaker-style workflows.

## 1. File Speaker

Drop or select WAV, AIFF, MP3, M4A or other AVFoundation-readable audio. Studio converts short windows of audio into a small set of haptic tones inside the trackpad's measured useful range.

Profiles:

- **Melody** — follows one dominant tonal component.
- **Rhythm** — emphasizes transient/noise character and low-frequency pulse.
- **Voice** — prioritizes a small speech-oriented resonance set.
- **Full Mix** — retains several dominant components per frame.

This is intentionally lossy. A Force Touch actuator is not a hi-fi speaker.

## 2. Live System Audio → Trackpad

Studio uses ScreenCaptureKit to request macOS system audio, excludes Studio's own process audio, converts captured PCM to haptic frames, and plays the result through the Force Touch actuator.

macOS requires Screen Recording permission for this capture path. The permission is controlled by the user in System Settings.

## What this mode is not

The current Studio app does **not** install an AudioServerPlugIn or DriverKit virtual audio device. Therefore it does not appear as a normal selectable output device in **System Settings → Sound**. That is a separate driver-level project with a different signing, deployment and maintenance burden.

The live system-capture mode provides the practical user experience of "send what the Mac is playing to the trackpad" without installing a system audio driver.

## Safety

- Master level is clamped to the normal upstream ceiling.
- Per-frame levels are limited to 1.0.
- Frequencies are clamped to 98–3951 Hz by default.
- Tone count and frame duration are bounded.
- **PANIC STOP** closes Studio playback paths and the actuator; Reconnect explicitly reopens it.

NoSpeaker Studio does not claim that long-duration haptic audio is endorsed by Apple. `MultitouchSupport` is private and can change between macOS releases.
