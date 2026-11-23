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

## Troubleshooting unexpected stops and global capture

**Version 0.2.1** separates macOS input-monitor interruptions from the haptic engine. If a CGEvent monitor times out, the app releases the desktop pointer and attempts to restore the monitor. If macOS explicitly disables monitoring or recovery fails, Global Capture is safely turned OFF; the Force Touch motor and other instrument modes remain available. A deliberate **PANIC STOP** still closes the driver and shows **Stopped — press Reconnect to reopen the trackpad**.

If a recorded shortcut does not work outside the application:

1. Install the DMG to Applications (or use the documented one-line installer); avoid switching repeatedly between differently signed copies.
2. In **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**, grant the installed **Tihulu Trackpad & M. Mouse Instrument** access when requested. Quit and reopen the app after changing permissions.
3. In the top bar, select **Shortcut**, press the desired key with optional Command/Option/Control/Shift modifiers (like a push-to-talk shortcut recorder), then enable **Global Capture**. Escape is reserved and cannot be recorded.
4. Test the shortcut while a different app is in focus. Press the same shortcut again to release the cursor. When captured, Escape releases the pointer and triggers the emergency stop.
5. If macOS disables the monitor, check the status text and re-enable the capture toggle after reviewing permissions. The haptic engine should not require Reconnect for a monitor-only interruption.

**Important:** Global Capture suppresses desktop pointer input from *all* mice/trackpads while active; the system event stream cannot safely distinguish Magic Mouse from other pointers. Keep the shortcut and emergency release accessible. On-screen Stop stops playback without closing the driver; Panic Stop intentionally requires Reconnect. If the driver still stops unexpectedly, note the mode, macOS version, which input surface was in use, and whether the input-monitor status changed. This behavior still needs physical-device acceptance testing.

## Global Capture diagnostics (v0.2.2)

If the recorded performance shortcut has no effect in another application, open **Diagnostics → Global Capture → Refresh Snapshot**. This is a read-only check: it never turns on capture or requests permissions, and it does not record raw keys, typed text, private recordings, user file paths or hardware IDs.

1. Record a shortcut in the top bar (avoid a key combination already reserved by macOS), then enable **Global Capture**.
2. Go to **Diagnostics** and **Refresh Snapshot**. Check Accessibility, Input Monitoring preflight, Event Tap Created/Enabled, and the active shortcut.
3. Switch to another application (for example TextEdit), press the recorded shortcut **twice**, and move the pointer between presses. If capture is working, desktop pointer movement should be suppressed after the first press and restored after the second.
4. Return to Diagnostics and **Refresh Snapshot** again. Check whether the key-down, shortcut-match and pointer-event counters increased, and whether macOS reported a tap timeout or disable.
5. Click **Copy Report** and share the sanitized text in the GitHub issue for troubleshooting. Counters are per process lifetime; quit and reopen the app to reset them.

**How to interpret the report:** If the event tap cannot be created, check the macOS permission and code-signing state. If key-down events increment but shortcut matches do not, try recording a different combination. If matches increment but the pointer still moves while captured, examine pointer counts and event-tap timeouts. If the pointer is successfully captured but Touch Instrument makes no notes, confirm Touch Instrument is **started** and the appropriate trackpad/Mouse surface and MIDI/haptic routes are selected: global capture only suppresses desktop cursor events, it does not automatically start musical playback.

The **Input Monitoring preflight** flag is an operating-system permission hint, not conclusive proof that an event tap can filter events. The **Event Tap Enabled** and observed counters are more useful when testing. While captured, the shortcut toggles release and **Escape** triggers Panic Stop. If you lose pointer control, the ordinary keyboard emergency release is available while the event tap is running.

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
