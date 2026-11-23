# NoSpeaker Studio

A native macOS haptic-audio workstation built on top of **[os6/nospeaker](https://github.com/os6/nospeaker)** by **Cody Collier**.

> **Upstream credit is permanent:** the original trackpad-audio technique and `nospeaker` implementation come from Cody Collier's MIT-licensed project. NoSpeaker Studio preserves that attribution in the repository, application UI, About page, bundled resources and release workflow. See [ATTRIBUTION.md](ATTRIBUTION.md), [NOTICE](NOTICE) and [LICENSE](LICENSE).

## What Studio adds

Each mode opens independently in the native SwiftUI application:

- **Voice** — type text and speak it through the Force Touch haptic motor using the upstream-style macOS `say` + LPC/formant pipeline.
- **Touch Instrument** — play notes directly with a finger on the physical trackpad; horizontal position controls pitch, vertical position controls vibrato and contact size influences level.
- **Note Sequencer** — create and loop 16-step melodic haptic patterns.
- **Drum Sequencer** — sequence haptic kick, snare, closed/open hats, clap and tom voices.
- **MIDI / Logic Pro** — expose `NoSpeaker Haptic MIDI`, receive live CoreMIDI, map channel 10 to drums, and import Standard MIDI Files.
- **Audio File** — drag/drop or open audio and convert it locally into haptic events using Melody, Rhythm, Voice or Full Mix profiles.
- **Trackpad Speaker** — play audio files as haptic sound or capture macOS system audio with ScreenCaptureKit and convert it to the trackpad in real time.
- **Diagnostics** — test a single frequency, run a 100 Hz → 4 kHz sweep, reconnect the actuator, and use a global panic stop.

## Upstream baseline

The initial compatibility baseline is **nospeaker v1.0**:

`64c5fbf493fab0a79382c8e101de8d80083b0d5c`

The downstream haptic device discovery, actuation dictionary shape, touch-record interpretation and speech-analysis behavior intentionally stay close to that baseline where private-framework behavior is involved.

When Studio is added to the fork, the original root `nospeaker.swift`, `build.sh` and CLI can remain untouched. The recommended fork layout places this project in `studio/`.

## Safety

Studio does not intentionally exceed the original project's normal actuator level ceiling.

- Level is clamped to `0...1`.
- Default frequency range is `98...3951 Hz`.
- Per-frame tone count and duration are bounded.
- All playback modes share the same safety policy.
- **PANIC STOP** cancels Studio playback, stops live modes and closes the actuator.
- Playback only returns after an explicit reconnect.

`MultitouchSupport` is private and undocumented. A future macOS update can break it.

## Speaker Mode clarification

The live Speaker Mode captures system audio with ScreenCaptureKit and converts it to haptic output. It does **not** install a virtual audio driver and therefore does not appear as a normal selectable output device in macOS Sound Settings. See [docs/SPEAKER_MODE.md](docs/SPEAKER_MODE.md).

## One-line install

After Studio is merged to the fork default branch:

```sh
curl -fsSL https://raw.githubusercontent.com/Tihulu/nospeaker/main/install-studio.sh | sh
```

The installer prefers a signed/notarized `NoSpeaker-Studio-macOS.zip` release. Until a packaged release exists, it automatically falls back to a local source build using Apple Command Line Tools or Xcode. It installs the app to `~/Applications/NoSpeaker Studio.app` and a launcher to `~/.local/bin/nospeaker-studio`, without requiring `sudo`.

Uninstall with:

```sh
curl -fsSL https://raw.githubusercontent.com/Tihulu/nospeaker/main/uninstall-studio.sh | sh
```

## Requirements

- macOS 13 or later for the Studio app.
- A Force Touch trackpad: supported MacBook hardware or a compatible external Magic Trackpad.
- Xcode or Apple Command Line Tools for source builds.
- Screen Recording permission for live system-audio capture.

The original upstream project supports a broader CLI matrix. Studio's first hardware release must be validated independently using the acceptance checklist.

## Verify shared logic

```sh
./scripts/verify.sh
```

This runs the cross-platform core test suite, builds available targets, parses macOS-only Swift sources for syntax, checks attribution, and enforces the English-only repository rule.

## Build the macOS app

```sh
./scripts/build-app.sh
open "dist/NoSpeaker Studio.app"
```

For a public signed release, set a Developer ID identity and a saved `notarytool` profile, then run:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
NOTARY_PROFILE="nospeaker-studio" \
./scripts/release-sign.sh
```

## Current verification status

The shared Swift implementation and testable DSP/MIDI core are complete in this package. The environment used to prepare this package is not macOS and does not expose a Force Touch actuator, so hardware claims remain gated on [docs/MAC_HARDWARE_ACCEPTANCE.md](docs/MAC_HARDWARE_ACCEPTANCE.md).

A fork-level GitHub Actions workflow is included in the overlay package so macOS compilation can be checked automatically after the fork exists.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Implementation status](docs/ROADMAP.md)
- [Logic Pro / MIDI](docs/LOGIC_PRO.md)
- [Speaker Mode](docs/SPEAKER_MODE.md)
- [Mac hardware acceptance](docs/MAC_HARDWARE_ACCEPTANCE.md)
- [Attribution](ATTRIBUTION.md)
