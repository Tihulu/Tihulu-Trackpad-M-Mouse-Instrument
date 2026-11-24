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
