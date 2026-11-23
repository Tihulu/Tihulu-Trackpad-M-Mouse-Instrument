# Tihulu Trackpad & M. Mouse Instrument

**Turn a Force Touch trackpad and a Magic Mouse into expressive musical controllers for macOS and Logic Pro.**

![TIHULU Trackpad & M. Mouse Instrument icon](studio/Resources/TihuluTrackpadMouseIcon.svg)

A native SwiftUI haptic music workstation with live surface maps, multi-touch MIDI/MPE, a drum-pad controller, Voice, sequencers and optional system-audio-to-trackpad playback. The app name and macOS icon are **Tihulu Trackpad & M. Mouse Instrument**.

> Based on [os6/nospeaker](https://github.com/os6/nospeaker) by **Cody Collier** under the MIT license. We retain the original attribution and upstream source. TIHULU additions are downstream work, not an endorsement by the upstream author.

## Install

**Download a macOS DMG** from [Releases](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/releases/latest) and drag **Tihulu Trackpad & M. Mouse Instrument.app** into Applications.

**One-line install** (latest published DMG, with source-build fallback if unavailable):

```bash
curl -fsSL https://raw.githubusercontent.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/main/install-studio.sh | sh
```

Open after installation:

```bash
open "$HOME/Applications/Tihulu Trackpad & M. Mouse Instrument.app"
```

To build the current `main` revision instead of installing a release:

```bash
TIHULU_INSTRUMENT_CHANNEL=source sh -c 'curl -fsSL https://raw.githubusercontent.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/main/install-studio.sh | sh'
```

The source-build fallback requires Xcode or Apple Command Line Tools. The local icon renderer additionally uses `librsvg` (`brew install librsvg`); published DMGs already contain the rendered icon. The installer never requires `sudo` and installs into `~/Applications`.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/main/uninstall-studio.sh | sh
```

## Features

| Mode | What it does |
| --- | --- |
| **Voice** | English, Turkish and German speech sent to the Force Touch haptic motor. Lists installed macOS `say` and additional Apple Speech enhanced/premium voices when available. Local voice generation. |
| **Touch Instrument** | Fretted (scale-quantized) or Fretless (continuous pitch) controller, live finger map even before starting, configurable scale/root/zone width. **Fretted and Fretless size use the same 0.50×–2.00× range**. Touch or press triggers, fixed/size-derived velocity, multi-touch and optional local haptic sound. |
| **Independent surfaces** | Trackpad and Magic Mouse can each play **Melodic** or **GM Drums** and route output to the trackpad haptic motor, Logic MIDI, or both. |
| **Expressive MIDI** | CoreMIDI in/out, held notes, MIDI sustain CC64, pitch bend, mod wheel CC1, expression CC11, channel volume CC7, aftertouch, MPE finger channels, and GM drum pads on **MIDI channel 10**. |
| **MIDI Helper** | Independently combine Vibrato, Pitch Bend, Expression and Sustain checkboxes; use Trackpad/Magic Mouse/Both while playing chords on a separate keyboard; route CC64 on a chosen MIDI channel. |
| **Sustain** | Switchable Trackpad Touch Hold, Tap Toggle, Click Hold, Click Toggle, or Contact Threshold (Contact Size vs experimental Click Pressure). Magic Mouse Touch/Click Hold or Toggle. Local haptic and MIDI sustain in Touch Instrument. |
| **Global Capture** | Record a user-defined key or key combination. Opt-in keyboard shortcut captures/releases the system pointer **in every mode**; Esc is an emergency release/Panic Stop. |
| **Sequencers** | Note and drum step sequencers with adjustable tempo. |
| **Audio File** | Drag/drop audio, locally analyze melody/rhythm/voice/full mix for haptic playback. |
| **Trackpad Speaker** | Audio-file haptics and optional ScreenCaptureKit system audio conversion; **not** a virtual audio output driver. |
| **Diagnostics** | Frequency test, sweep, device reconnect, hard stop. |

## Logic Pro setup

1. Open **Touch Instrument**; select **Trackpad**, **Magic Mouse** or **Both** and choose `MIDI Instrument` or `Both` output.
2. In Logic Pro, enable the NoSpeaker virtual CoreMIDI source as input to a Software Instrument track.
3. For fretless independent multi-finger pitch, choose **MPE** and an MPE-compatible instrument.
4. For percussion, select the **Drums** surface map and a General MIDI-compatible drum kit. GM notes (Kick 36, Snare 38, Closed Hat 42, etc.) are sent on channel 10. Channel 10 alone does not select a drum kit.
5. For live expression alongside an external keyboard, open **MIDI Helper**, enable your desired CC mappings and set its target MIDI channel to your Logic instrument.

See [Logic & Magic Mouse guide](studio/LOGIC_DRUMS_MAGIC_MOUSE.md) and [Expressive Controls guide](studio/EXPRESSIVE_CONTROLS.md).

## Global capture and permissions

All modes share the same top-bar control. Press **Record Shortcut**, then any key or modifier combination (except reserved Esc), and enable **Global Performance Capture**. The shortcut toggles pointer interception while the app is running; **Esc** stops all outputs and releases the pointer. Your shortcut is stored locally; capture is OFF on launch.

macOS may require Accessibility and Input Monitoring grants. Pointer interception is **session-wide**, not limited to Magic Mouse; an event tap may be disabled by macOS and should release the pointer automatically. Contact Size is *not* calibrated Force Touch pressure; experimental Click Pressure may be unavailable. System audio capture separately requires Screen Recording permission.

## Requirements and safety

- macOS 13 or newer; SwiftUI native app.
- A Force Touch trackpad for local haptic output; Magic Mouse gesture support depends on macOS private multitouch support.
- Logic Pro or another DAW is optional, only required for software-instrument audio.
- Haptic output stays within the source project's conservative motor bounds. Emergency Panic Stop is available.
- Private `MultitouchSupport` APIs can change across macOS versions; Mac hardware acceptance is **not** implied by a passing CI build.
- The first public DMG may be **ad-hoc signed and not notarized** until Developer ID and Apple notarization credentials are configured. Gatekeeper may require a manual review/open; do not bypass security warnings blindly.

## Build / verify

```bash
git clone https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument.git
cd Tihulu-Trackpad-M-Mouse-Instrument/studio
./scripts/verify.sh
./scripts/build-app.sh
open "dist/Tihulu Trackpad & M. Mouse Instrument.app"
```

On macOS with Homebrew, `brew install librsvg` enables icon rendering from the supplied **true path-based SVG**. GitHub Actions builds the macOS DMG on an Apple runner; code signing/notarization requires your own Apple developer credentials.

## Upstream credit

Original `nospeaker` v1.0, Cody Collier · [MIT license](LICENSE), upstream [os6/nospeaker](https://github.com/os6/nospeaker). See [studio/ATTRIBUTION.md](studio/ATTRIBUTION.md), [studio/NOTICE](studio/NOTICE) and [studio/LICENSE](studio/LICENSE).
