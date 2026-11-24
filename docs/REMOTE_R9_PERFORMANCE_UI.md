# R9-UX — unified mobile performance interface (proposal)

Status: DRAFT, documentation only; frozen PR #80 `287560d4e522cf46b585e7212c4413ecce3c3d1b`. Companion: REMOTE_R9_MAPPING_CONTRACT.md. No production changes or acceptance claim.

## 1. Design goal: one instrument, not a catalogue of toggles

Use the existing browser controller and scheduler; do not create a second engine or parallel socket. The Mac patch determines available controls and all musical destinations. The mobile performer chooses what to display, arms only intended instruments, and can release their own outputs quickly. Touch, drums, piano, pedals and motion may operate together when validated scheduling permits; no claim of unlimited concurrency. No feature that has no mapped route, no fake instrument sounds, no implied hardware haptics, no permissions on page load.

Frozen reference: RemoteLoopbackPageServer.swift:198–216 parses v7 and hides sections; :218–331 owns drum/piano/pedal snapshots; :332–405 owns motion arm/release; :417–491 handles close, 220ms ACK and single lane scheduling; :505–529 handles admission/ACK; :544–607 handles pointer lifecycle, explicit enables and lifecycle close. PhysicalPatchRuntime.swift owns source isolation, release and stream freshness. SensorRouter owns final destination arbitration; same MIDI target may have more than one contributor.

## 2. Information architecture

Three destinations in a single responsive page; navigation is view state, never implicit authorization:

- **Play** (default after negotiation): selected instrument surfaces, pinned accessory strip, persistent status and release. First mapped surface selected but disabled until explicit enable. On phones use one main surface (Touch XY, Pads, Piano, Pedals or Motion) and optional pinned controls. On tablet use two visible surfaces when each meets touch minimum; no extra transport or sessions for layout alone.
- **Setup**: choose main surface order, optional pinned sustain/expression/motion status, left/right orientation, size and text size, high-contrast/reduced motion, session-only aliases, mapped note/CC details; all available controls have a reset-layout action. Setup is unavailable while any output is armed/held/pending; release first, then edit. Changes are local view preferences, not routing changes. Non-sensitive visual preferences may persist locally; never persist labels, mapping, identifiers, secrets, or armed state. Default all unarmed.
- **Connection**: pair with invitation, show negotiated capability/metadata status, disconnect, troubleshooting with concrete next steps. No automatic reconnect, no background capture. Show mapping hidden/unavailable explicitly without disabling ordinary logical play. Host route changes require fresh invitation.

Phone portrait concept (example mapped controls; not all visible by default):

```text
┌─────────────────────────────────┐
│ Connected · Ready     RELEASE   │  persistent, always reachable
│ Play       Setup     Connection │
│ Piano  |  Pads  |  XY  | Motion │  only available surfaces
│ Piano · octave 1   [Enable]     │
│ [<]  12 semitones + endpoint [>]│
│     ▪ ▪   ▪ ▪ ▪                 │
│   [ ][ ][ ][ ][ ][ ][ ]         │  actual mapped labels
│                                 │
│ Sustain [off] · Expression 72%  │  optional pins, one owner per ID
│ Tilt OFF · Drums OFF            │  no phantom activity
└─────────────────────────────────┘
```

The sketch is illustrative; disconnected status, small viewports, landscape and large text need real layout tests. Avoid scrolling on performance gestures, not globally. A scrollable non-play region remains reachable. No landscape lock, mandatory fullscreen, always-awake permission or dependency on install/PWA.

## 3. Surface rules and customization

| Surface | Useful behavior | Customization and safeguards |
|---|---|---|
| Touch XY | Bounded normalized pad, position cursor, mapped x/y/contact chips | left/right layout and size; label only mapped axes, no arbitrary MIDI. If only contact mapped show simple hold surface; if one axis mapped show one-axis rail with fixed unused axis. Keep v1 coordinates and explicit release. |
| Pads | Up to 8 mapped momentary pads, stable logical numbers, multi-touch | reorder visible pads only while idle; compact/large grid; disclose fan-out. Do not assume kick/snare or velocity sensitivity. |
| Piano | 25 logical keys through two overlapping 13-key windows, fixed semitone geometry, disabled unmapped keys | octave only when no piano held/pending; select mapped window by default; actual note names and channels where known. Standard scale overlay only when each enabled key has exactly one distinct destination note matching default 48+i (duplicate route to same note allowed); otherwise disable overlay with reason. No automatic transposition or remote remapping. If only sustain mapped, show sustain standalone and no empty keyboard. |
| Pedals | Expression/Volume/Wah logical continuous controls, sustain/switches | display actual MIDI mapping, not implied FX; preview level before activation; slider 0..100% input, not DAW value. Binary latch only explicit, conspicuous and released on exit/disable. Momentary option only if lifecycle and snapshot semantics pass tests. |
| Motion | Tilt, acceleration, rotation independently armable; Air Drums indicator if mapped | explicit permission and calibration, per-stream stop; motion feedback indicates input magnitude, not sound or strike delivered. Air Drums shares acceleration stream, no independent duplicate arm. If only strike mapped, call it Air Drums and do not suggest acceleration CC. |

Mapping chips use companion contract, no invented labels if undisclosed. Show one short alias and destination summary in performance view, full target list on idle details panel. No truncation that hides target count; accessible full text. Alias or layout cannot change target or create new controls. Avoid analog fakes: no pressure, touch force, velocity, sensor or haptic claims unless separately verified and protocol-supported.

## 4. State model and ownership language

Connection: Disconnected -> Pairing -> Checking controls -> Synchronizing mapping (optional) -> Ready -> Releasing/Disconnected. Invalid manifest/mapping, stale input or ACK, overload or loss -> Disconnected. Permission substates per motion stream: Off -> Permission requested -> Waiting for sample -> Arming -> Active -> Releasing -> Off, or explicit error. Navigation/permissions never automatically arm anything.

Per surface states: Off / Enabled (no contribution) / Input held or latch active (local desired) / Sending (pending) / Accepted by host (last ACK) / Releasing (pending zero or release) / Released (host ACK) / Connection lost (release requested by disconnect; host output not independently verified).

Track desired, sent and accepted snapshots separately (candidate's sent state is assigned before ACK); accepted means host processed frame, not audible output, exclusive ownership, or DAW receipt. A local hold can be accepted while another source wins arbitration. Use text, shape and icon, not color alone. Do not show "MIDI sounding", "owns channel", "all notes off" or "safe" solely based on ACK. Other peers' identities/status unavailable in this protocol; do not invent a host-wide owner indicator. If a later host status extension is needed, it requires separate reviewed contract, not polling during performance.

Multiple pointers on one pad/key aggregate into one logical owner bit; releasing one pointer must not release another. Distinct controls mapped to same destination remain distinct logical owners; host router decides contributions. Pinning a sustain/pedal does not create another independent control: all visual instances share one canonical ID/state and one input controller. Prefer moving the instance instead of duplicating it; if repeated status is needed, make it read-only. Local keyboard/pointer events share ownership accounting, and no event can act on stale DOM or an unmapped signal.

## 5. Navigation and release contract

- Global **Release** is persistent above every surface, reachable without scroll or modal confirmation. It releases this connection's owners only. Normal path: freeze input, cancel permission epochs/listeners, clear queued non-release snapshots, send per-stream release/zero via existing ACK lane with release priority (pedal, piano, pads, touch, tilt, inertial; no unarmed motion release). Wait for ACKs; if pending arm is accepted, immediately release that stream. Remain unarmed after success; no stale event reactivation. A release requested during a pending press must queue release even if desired is already zero.
- If any release cannot be delivered/acknowledged within existing safety budget, or all owners cannot be tracked reliably, close socket immediately; host revocation/watchdog handles cleanup. Explicit emergency **Disconnect** closes immediately (no wait on browser timers). No global raw CC123 or host panic, which would disturb unrelated contributors. Proposed normal release aggregate deadline <=350ms from initiation; if multi-release cannot meet it, disconnect, never loosen timeouts. This is a target for PERF, not a measured result. UI status distinguishes ACKed release vs unverified host cleanup.
- Switch main surface while idle freely. If held, armed or pending, do not unmount controls silently. Default release affected surface, wait for ACK, then switch; if a performer explicitly pins an active motion/latched pedal, it may remain active only with visible status and stop control. A held key/pad/contact cannot be hidden or pinned away. Setup requires all surfaces off; orientation/layout changes that would relocate active hitboxes release first or close. Do not rely on DOM removal to trigger release. No confirmation dialog blocks emergency release.
- Pointerup/cancel/lost capture, keyup/blur, tab/window blur, pagehide, hidden document, connection loss, sensor stop, permissions revocation, invalid data, stale queue, rate/fault: apply existing fail-closed lifecycle. On background/lock/orientation disruption where release cannot be guaranteed, close. Never restore previous latches or arm state. Keyboard focus loss releases its owner; page loss closes all. On foreground, fresh invitation required.
- No continuous metadata requests during performance. One outstanding frame, current 25ms tick, 50ms held refresh, 150ms discrete queue age, 220ms ACK deadline, host 90/s cap, 100ms receipt freshness, 350ms independent active-stream watchdog, 2s idle expiry remain unchanged. Seven simultaneously active streams at 20Hz would demand 140/s, over host cap even before transitions; scheduler must be measured, not advertised as unlimited. Do not increase refresh intervals merely to pass stress tests. Coordinator and PERF must set supported concurrency from observed service gaps, preserve release priority, and gate unvalidated combinations with an explicit reason before arming. No silent deactivation of another stream to make room.

## 6. Accessibility and interaction

Use semantic buttons, native range inputs and labelled regions, visible focus, persistent release, aria-pressed only for appropriate toggles/desired local state, polite live region for connection/permission/release transitions, not every sensor tick. Minimum 44x44 CSS px primary hit targets, 48 preferred with spacing; piano black keys may need landscape or horizontally scrollable idle keyboard with explicit controls; never compress to unusable sizes. Screen reader and keyboard access for key/pad presses, sliders and stop; key repeat ignored, no global keyboard capture, no focus traps. For virtual screen-reader activation that lacks keyup/pointerup, offer explicit bounded press/release mode only after implementation safety tests; never pretend click is a valid sustained gesture. Motion is optional, provide playable mapped manual alternatives where available, and state when none exist. High contrast >=4.5:1 for normal text, 3:1 control boundaries/large text; support zoom/large text and reduced motion. Use short accessible labels with full destination details when disclosed. No color-only indicators, decorative meters or vibration claims. Use safe-area insets, no fixed overlays covering controls; preserve global release at 320px width and 200% zoom.

## 7. Acceptance vectors (not executed runtime tests)

| ID | Scenario | Required result |
|---|---|---|
| U01 | phone connects, partial manifest, detail hidden | only mapped controls; logical names, no phantom MIDI destinations; no arm |
| U02 | pad fan-out to Ch10 note36 and Ch1 note60 | both actual labels visible in details, summary 2 targets |
| U03 | piano custom swapped notes, fan-out, upper-only and sustain-only variants | no misleading scale highlights; available octave; sustain-only standalone |
| U04 | two fingers same pad, then one releases | one logical hold remains; final finger releases |
| U05 | two peers share MIDI note and one releases | UI claims only own release; other peer not silenced by this action |
| U06 | press pending ACK then global release, arm pending ACK then release | no queued press replay; zero/release after ACK or close |
| U07 | lost ACK/ACK delay or aggregate release exceeds deadline | socket close, unverified cleanup status; fresh invitation |
| U08 | swipe tabs with held piano, pin active pedal, rotate phone | no hidden held note; pinned owner visible or released; no automatic re-arm |
| U09 | permission denied, invalid sample, late permission resolution after release | no arm; stale callbacks ignored |
| U10 | page hidden, blur, pointercancel, capture loss, key blur | releases per ownership or closes; no latches restored |
| U11 | custom aliases with HTML-like text, long labels, zoom/RTL | literal text, complete accessible detail, no input interference |
| U12 | tablet side-by-side with pins, phone 320px/200% zoom, screen reader | release accessible, no accidental controls; physical tests separate |
| U13 | concurrent all streams, delayed ACK, flood | gate unsupported combinations; preserve deadlines; report actual supported load |
| U14 | patch change and revoke/reinvite | old mapping and ownership cleared; no cached private label |
| U15 | disabled/unmapped handler invoked directly | no wire event; server independently enforces capability |
| U16 | slider releases custom neutral value, shared target arbitration | UI says input released, never assumes 0 or DAW delivery |

Review gates: Node VM event/state vectors and browser layout automation; Swift host ownership and protocol negative tests; PERF service-gap and release testing; real Safari iOS and Chromium Android plus Mac/DAW physical acceptance (multi-touch, permissions, safe areas, rotation, loss, sustain/CC release, shared ownership). Record browser/device versions and exact commit. No actual performance measurements or physical PASS in this document.

## 8. Staged handoff / Anti-Slop

A: mapping destinations and privacy (M vectors) plus honest labels; B: responsive surface navigation and global release (U01–U10/U15–U16); C: custom labels and safe local layout/accessibility; D: validated multi-surface concurrency after PERF/QA. Ship only independently verified features. No generic widget editor, cloud sync, extra protocol transport, DAW feedback, arbitrary MIDI, remote patch mutation, sensor fusion, live remap or background mode in this gate. Those are deferred until a concrete musical need and acceptance case exists. Coordinator retains integration; no implementation or merge authorized by this draft.
