# Multi-surface performance, Touch Bar and screen tilt

This experimental development branch extends **Tihulu Trackpad & M. Mouse Instrument** with independently running surfaces.

## Independent performances

- **Trackpad instrument + Magic Mouse helper:** in **Touch Instrument** choose Trackpad as the selected surface, configure the MIDI destination or haptic output, then Start. Go to **MIDI Helper**, select Magic Mouse and Start. The Instrument is intentionally preserved on navigation, and the shared native multitouch monitoring callback distributes Trackpad and Mouse frames independently.
- **Magic Mouse instrument + Trackpad helper:** reverse the surface selections and repeat.
- Touch Instrument and MIDI Helper have their own Stop buttons; both are also available in the top transport bar while active. Switching between Voice/Sequencer/MIDI/Diagnostics screens does not implicitly stop a performance.
- The shared native listener owns the single hardware callback; no competing callbacks are registered on the same device. Device sampling/pressure comes from private MultitouchSupport APIs and must be validated on the user's actual Mac.
- The output destination, MPE base channel and helper target channel are configurable. For a Touch Bar to modify the same Logic instrument, set the Touch Bar's MIDI channel to the active target channel. Beware standard per-channel pitch bend affects all notes on that channel; for per-note pitch bend use an MPE instrument and compatible channel routing.

## Magic Mouse orientation

Use the global **Mouse Axis** picker to select **Horizontal** or **Vertical**. Vertical rotates gesture coordinates 90° (X becomes Y; Y becomes 1−X). This is applied across instrument, fretless and helper mappings; Trackpad coordinates do not change. The choice is stored locally.

## Physical Touch Bar

On Macs that actually have an Apple Touch Bar, the optional native AppKit bar exposes a configurable set of zones:
- 8 fretted note pads
- Fretless Glide / pitch-bend slider
- Vibrato CC1
- Expression CC11
- Sustain CC64 (Hold or Toggle)
- Filter Cutoff CC74

Use **Touch Bar & Tilt** to select zones, reorder them, choose MIDI channel and set sustain mode. A functional **on-screen equivalent** is always available, including on Macs without a physical Touch Bar. Native controls are subject to AppKit/focus behavior; Mac hardware acceptance is required before claiming fully simultaneous polyphony and hold/release fidelity.

## Lid angle / hinge mapping

The **Screen hinge as an instrument** panel has both a *manual angle simulator* and an opt-in **Live Hinge Angle Sensor (Experimental)** switch. When explicitly enabled, the app looks only for the Apple HID sensor signature reported by the open-source LidAngleSensor project, validates the feature report, and samples angle updates while active. It maps a calibrated 5°–175° reading to CC74, CC11, CC1 or pitch bend. If the sensor is absent or unsupported, no device is retained, monitoring stays OFF, and the manual simulator remains available. No Apple-supported public API provides a reliable lid angle on every Mac; a true-hardware PASS requires real-device validation.

Ideas for future expressive presets (not yet implemented):
- Open the screen gently to swell filter cutoff or expression, with a 50°–135° calibrated range
- Slow incline for crescendo / tempo nudge
- Short hinge motion for vibrato depth, with dead zone and smoothing
- Hold a Touch Bar sustain pad while moving the hinge for aftertouch-style modulation

Never operate a lid near closed positions where macOS may sleep. Do not automate mechanical lid motion or override power-management safeguards.

## Hardware acceptance

1. Trackpad Instrument started, Mouse Helper started, Logic receives both MIDI notes and CC messages concurrently; switch to Voice and back without either stopping.
2. Reverse Trackpad/Mouse roles and repeat. Stop one mode and verify the other still produces output.
3. Rotate Mouse Axis while touching and confirm vertical controls change in the specified direction; restore Horizontal.
4. On a Touch Bar-equipped Mac, reorder three zones (Vibrato, Sustain, Pitch Bend) and verify all appear and affect the intended Logic channel. Confirm hold and toggle both release CC64.
5. On a Touch Bar-less Mac, use the on-screen strip and validate note-on/note-off and slider control.
6. Test hinge simulator in all mappings, then explicitly enable Live Hinge Angle Sensor. If the Mac exposes a usable sensor, confirm actual angle updates and MIDI targets. On unsupported Macs confirm an explicit unavailability message, no automatic polling, and continued simulator operation. Do not claim hardware compatibility without a reproduced test.
7. Confirm Global Capture's emergency release remains available throughout the tests, even when another app is in front.
8. Log any CoreMIDI OSStatus -2, macOS event-tap timeout, or physical touch preview interruption and block stability claims until tested.

## Rollback

The stable v0.2.2 DMG remains available from Releases. This feature is developed in an unmerged branch until macOS Swift CI and hands-on hardware QA establish a compatible build.

## Hinge sensor attribution

The optional HID probe uses the sensor identification and feature-report mapping documented by [LidAngleSensor by Sam Gold](https://github.com/samhenrigold/LidAngleSensor), Apache-2.0. The adapter is an independently simplified, read-only implementation and does not copy the upstream application's UI or audio engine. Device-specific compatibility claims are not inherited from that project. Review its license and research before redistribution of derived code.

## Hold / Slide to Lock sustain contract
For rectangular on-screen performance sustain controls, momentary press activates, ordinary release deactivates, deliberate rightward drag from the main button into the lock area followed by release latches, and pressing again unlocks. A tap on the lock area alone does not latch. Use distinct accessible state, scoped cancellation, no stale gesture after Stop/Panic/profile replacement. New Touch Bar profiles default to this mode; saved Hold and Toggle profiles remain compatible. First increment: shared owner-aware core and Mac on-screen Touch Bar; physical native Touch Bar remains momentary in this mode pending native drag acceptance, without releasing the screen latch. Physical Trackpad/Magic Mouse helper gesture modes, external pedals, configuration enable switches and existing CC64 ownership are unchanged. Future native mobile piano, dedicated pedalboard, web and Builder button controls use the same semantic contract after platform-specific ownership and cancellation verification. No automatic live mobile sustain or new shared-channel output.
