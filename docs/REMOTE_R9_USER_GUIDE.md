# TIHULU Remote — experimental preview user guide

This guide describes the candidate through PR #106, not the published v0.2.3 stable application. Features are implemented in the draft chain; the newest native CI and physical gates remain open. Remote does not turn a phone into an independent synthesizer: it sends mapped control input to the Mac, which can route commands to CoreMIDI when MIDI output is explicitly enabled.

## Start safely
1. Follow [isolated preview package verification](REMOTE_R9_PREVIEW_ACCEPTANCE.md). Do not replace stable or run both apps concurrently. Keep Global Capture and MIDI output off at first.
2. Open Instrument Builder, configure phone or tablet source routes. Choose the desired destination channel/note/CC, pitch bend or sustain where allowed. Use a disposable DAW session later. Confirm the patch is valid before starting the physical runtime.
3. In Remote TLS controller, load a dedicated trusted Keychain identity. Start loopback and run **Run TLS + source diagnostic**. The diagnostic uses real source capabilities and verifies withheld mapping metadata. If XY is mapped it also checks touch/release ACKs, otherwise an idle heartbeat; neither proves audible output.
4. Stop the loopback runtime, enable experimental LAN, refresh/select the currently available private IPv4 interface, and confirm the network and matching certificate trust. Start LAN with the selected identity. The phone must already trust the corresponding certificate; never ignore browser certificate warnings, forward ports, or use a public network.
5. Select phone/tablet source, choose whether to share destinations and optionally custom labels. Create the one-time invitation. Scan the page QR or open the shown HTTPS address and enter the separate invitation. The QR contains no secret. Do not share an invitation or private label in support logs.
6. Wait until synchronization completes. Unmapped controls stay unavailable. Play is the default ready view; Setup shows mapping destinations and optional custom labels, and mode selection; Connection contains pairing information. Change views only after releasing/disabling controls and receiving outstanding acknowledgments.

## Choose an instrument
| Surface | Input | What can be mapped |
|---|---|---|
| XY | Touch position and contact | X/Y/contact to configured valid MIDI destinations |
| Drum pads | Eight logical pads | Note targets, including custom kit/channel |
| Piano | 25 logical keys in two overlapping ranges, sustain | Notes and sustain; default pitch scale guide only when verified |
| Pedalboard | Expression, volume, wah, sustain, two switches | Continuous CC/bend or compatible binary controls |
| Pocket Wah | Relative orientation | Tilt axes to CC/bend |
| Acceleration / Air Drums | Gravity-free motion magnitude/onset | CC/bend and configured percussive notes |
| Gyroscope | Rotation magnitude | CC/bend |

Labels are descriptive, not evidence of actual output. The host's patch decides MIDI targets; the client cannot set arbitrary destinations. Without disclosure, use logical control IDs. Sensor permissions are requested explicitly when enabling the relevant surface. Unsupported or stale sensors fail closed, not fabricated.

## Play and release
Conservative mode permits one of XY/drums/piano/pedals plus up to two sensor streams, or up to three sensor streams alone. The simulated 35 combinations passed six profiles and two workloads; real devices may still fail. Experimental mode is opt-in from Setup while idle, and can fail-close when overloaded. Never rely on the displayed Mac ACK round trip as MIDI or audio latency.

Use Release my controls to cancel unsent inputs and release sent owners. Wait for required acknowledgments, then re-enable controls explicitly. If release cannot be confirmed, the connection closes; Mac cleanup still needs verification in a MIDI monitor. Disconnect revokes only the peer's ownership. Panic Stop is the separate Mac emergency action; do not use concurrent stable/preview processes on shared hardware.

## Troubleshooting
- No LAN option: first complete trusted loopback diagnostic for a configured source.
- Pairing rejected: check source mapping, listener, trust, expiration and capacity. Request a fresh invitation; do not reuse refused or expired invitations.
- No mapped controls: check the Mac patch and source; do not bypass manifest validation.
- Sensor unavailable: check browser secure context and explicit permission, then choose a supported control.
- Input delayed: reduce enabled surfaces, use conservative mode and a reliable local network; reconnect explicitly after a fail-close.
- MIDI absent: ACK only proves host protocol acceptance. Verify MIDI ON, the selected virtual source and actual MIDI monitor/DAW routing. Never infer output from UI alone.

## Report acceptance
Use P01-P14 in [acceptance matrix](REMOTE_R9_ACCEPTANCE_MATRIX.md). Record exact artifact head/checkout, system/browser versions, control modes and observed MIDI commands. Redact secrets, addresses and private mapping text. No public release or stable replacement is authorized.

### Local performance layout (experimental)

In Setup, choose a mapped panel, move it earlier/later, toggle tablet full width, or select compact/normal/large playing surfaces. Release and disable controls before editing. Save stores only a versioned fixed-panel presentation preference in this browser; Reset restores the default and removes it. It never stores pairing codes, host mappings, device labels or active state. Unsupported/malformed stored data falls back to default. A different browser has its own layout. This is panel arrangement, not arbitrary new MIDI mapping or a freeform pixel editor.

Panel handles also accept touch/pointer drag to reorder mapped sections; move buttons remain a keyboard-accessible alternative. Reordering happens only on a completed idle drag. Cancellation, disconnect or leaving Setup discards the gesture. This does not create new controls or change their host assignments.

In Setup, panel-specific size and drum/pedal grid column preferences can override the overall size. Existing saved panel arrangements remain compatible. These are presentation-only; narrow screens retain a two-column fallback. Save/Reset includes the additional preferences. No new MIDI mappings, controls or wire messages are created.

Sustain and the two FX switches now have separate Hold/Toggle preferences in Setup (only mapped switches may be edited). Hold supports pointer and keyboard release, including cancellation and multiple fingers on one switch. Release All and disconnection clear local hold ownership. This is input behavior, not a change to the Mac mapping. The existing pedal snapshot protocol and safety deadlines are unchanged. Default remains Toggle.

Mapped drum pads and pedal controls can now be individually reordered within their existing panel. Dormant/unmapped identities keep their stored positions; unmapped pedal cells are hidden. Reordering actual control nodes does not create aliases or change the host bit positions, labels or assignments. Preferences persist locally alongside panel geometry and Hold/Toggle.

### Custom performance panel

Combine up to eight already mapped drum/pedal controls, including the existing expression/volume/wah sliders, into a personal mixed panel. Setup supports add, remove and reordering. The actual control node is moved, never cloned; original stream ownership, MIDI bit identity, enable/release rules and conservative workload limits remain unchanged. Unavailable saved selections stay dormant and never activate automatically. Layout editing requires an idle session. This is composition of existing host-mapped controls, not arbitrary new MIDI endpoints or freely assigned CCs.

Mapped expression, volume and wah sliders support horizontal or vertical native range controls and independent initial levels from 0–100%. Settings only change the local presentation and inactive value; the host receives nothing until the user explicitly enables and activates the mapped pedal. Custom panel placement follows the actual DOM/keyboard order. Moved controls are omitted from their original panel's individual reorder editor.

## App-free browser access (phone / tablet)

Native Android/iOS diagnostic apps are optional. The Mac serves the local Remote web page at `https://<selected-private-ip>:9444/` and its authenticated WSS controller at port 9443. The numeric address must be the Mac-selected RFC1918 interface, not a public address or arbitrary bind. Complete the Builder loopback diagnostic, select a trusted certificate matching that address and enable private LAN explicitly. Copy the web address or scan the address QR; enter the separate 64-hex-character invitation within 60 seconds. No public server, forwarding, certificate warning bypass, external CDN or installation of a mobile TIHULU app is needed. Trust provisioning on the client is still necessary. Loopback is Mac-only. Browser capabilities differ; use a current browser supporting secure WebSocket and the needed input APIs.

The unpaired Connection screen offers an optional local camera diagnostic. Choose front/rear preference or an available lens after permission, and zoom only if the active track advertises and confirms a valid range. Video stays in the browser; no audio, recording, network camera upload, hand recognition, depth or MIDI is performed by this check. Stop before pairing; pairing, hidden page and active-window focus loss stop capture. A cancelled permission request must settle before another starts. Native LiDAR/ToF APIs and browser hand inference are distinct future work. Existing mapped touch, piano, drum, pedal, arpeggio and motion controls remain available without an app.

### Experimental web camera motion helper

When the paired slot has an assigned continuous pedal, Play offers Camera motion helper. Select the mapped expression/volume/wah lane, keep the camera stationary, explicitly start the local camera, and move within its view. A small 16×12 luminance frame difference measures image change (including lighting or camera movement), not hand pose, distance, or direction. It sends only the existing pedalboard snapshot through the one-ACK scheduler, never video. The mode is exclusive, manual pedal controls are disabled, zoom is locked while playing, and unsupported video-frame callbacks cannot start. Quiet frames release the helper; stale/invalid frames, overdue release, focus loss, or camera end close the connection. Stop or switch modes to release. No hand-recognition model or native depth API is included; browser/physical latency and accuracy remain acceptance tasks.

Camera motion helper calibration options: choose motion amount, horizontal or vertical motion centroid (not hand position); sensitivity (low/normal/sensitive), full/center/left/right region, optional common brightness shift subtraction and inverted active output. The default startup calibration needs three consecutive quiet frame comparisons before any active output. Direct is an explicit experimental bypass of baseline calibration, not a bypass of permission, deadlines or ownership. Stop before changing settings. Inversion preserves neutral release; an active zero is a valid mapped helper level. Region values are full-frame normalized; lighting compensation is approximate, not a guarantee against false positives.

For paired camera performance, a stopped user can also request a numerical zoom factor. The selected camera must advertise that factor and report the same applied value before the video processing loop begins. Unsupported or unconfirmed zoom stops capture; blank means device default. The running helper never changes zoom, and late zoom completion after Stop cannot arm a sensor. Browser/device physical acceptance remains open.

The paired camera helper can explicitly assign up to three distinct mapped continuous pedal lanes to amount, X or Y metrics. All chosen values are delivered atomically in the existing v6 pedal snapshot (one ACK lane), with shared quiet baseline, inversion and release. Duplicate/unassigned lanes are refused before permission. These are image-motion metrics, not physical XYZ position. Existing single-target mode remains the default. No new wire schema or extra connection.

Camera settings can be explicitly saved, loaded or reset while idle. The versioned, bounded browser-local record contains only primary metric, sensitivity, region, facing preference, zoom request, baseline and light/inversion preferences. It excludes invitations, physical lens IDs, assigned MIDI lanes and all sensor data. Loading does not arm capture. Any saved zoom remains subject to the live track verification. The first quiet frame cancels an unsent camera activation rather than replaying a stale onset after another ACK.

Each selected camera helper now has an independent bounded gain (50%, 100%, 150%, 200%) and inversion. Gain clamps to 0–100 before inversion; the released state always has zero mask and zero levels. Sensor profile v2 adds gain, extra metric and extra inversion preferences without storing assignments. Version 1 profiles load with neutral gain and extra inversion defaults. No stored preference can enable capture or bypass live lane authorization.

The helper stops on display rotation even while neutral, rejects changes to reported frame geometry and initially reported track identity/facing/zoom, and rejects stale capture timestamps when the browser supplies them. Where captureTime is absent, only local callback/receipt freshness is established, not exposure age. A changed sensor/view requires an explicit fresh start and calibration; there is no live camera switch during an active helper.
