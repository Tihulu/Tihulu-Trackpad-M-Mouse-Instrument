# TIHULU Multi-device Party Jam

## First gamepad slice
Native Mac GameController extended profile, two explicit slots. Compatible Xbox controllers are connected to the Mac using OS pairing; this is not an Xbox console app. Map A/B/X/Y, bumpers, D-pad, stick clicks, analog triggers and both stick axes. Initial presets: drums, lead, helper. Existing Builder route calibration, ownership, release policy and explicit MIDI output apply. Buttons are binary, not pressure-sensitive. Stick center dead zone and trigger rest release; require neutral at start and after stale input. Poll on the existing 20 ms watchdog; short taps may be lost. No automatic replacement or player-index rebinding. Hardware acceptance still needed.

## Capacity and combinations
Current router has 16 sessions. Keep five existing local reservations; each mapped gamepad slot reserves one additional session, leaving 11/10/9 remote stream sessions with 0/1/2 slots. At most four authenticated remote peers, subject to reserved stream costs. A phone with all streams costs seven sessions, not one. Current multiple phones of the same source kind share routes, not independent player mappings. Phone/tablet roles are independently routed. No protocol change or larger limit without measured stress evidence.

| Combination | Assignment |
| --- | --- |
| Solo keyboard helper | RT sustain, LT wah, stick bend/modulation; external keyboard direct to DAW; use separate input filtering; no note or gain defaults |
| Duo controller jam | Controller 1 lead ch 4, controller 2 drums ch 10 |
| Mobile groove | Phone drum pads ch 10, tablet piano ch 2, gamepad lead ch 4 |
| Hybrid studio | Phone XY/motion, gamepad effects, Trackpad note/bass, Magic Mouse sustain, lid wah, Touch Bar ribbon |
| Party band | Two gamepads + up to four phones subject to actual session cost, local surface/camera controls; explicit host assignments |

## Next stages
1. Per-peer player identity/role mapping for multiple phones with different instruments; bounded host-chosen player slots, atomic role edits only while idle, source-scoped consent and metadata. Never let clients claim another player's role.
2. Mobile custom surface editor using existing XY, piano, drum and pedal transports: sliders, knobs, XY/trackpad, ribbon, pads, hold/toggle controls, layout presets and label editing. Additional simultaneous independent XY surfaces need a versioned stream protocol and budget accounting. No arbitrary client MIDI messages.
3. Gamepad edge-preserving mailbox, disconnection notification, timestamped capture and bounded coalescing of analog axes. Verify short taps, reconnect, two-controller simultaneous load and latency before acceptance. Browser gamepad on phone is separate future work.
4. Party coordinator: named player slots, roles, channel conflict warnings, per-player mute/revoke, explicit shared pedal policy, global Panic, common tempo, per-player take export. Keep external MIDI keyboard and Helper channels separate where needed. Avoid MIDI feedback and CC7/11 jumps; do not assign two independent volume/bend owners accidentally.
5. Stress tests for 4 phones/2 controllers/local inputs, admission denial, overload, neutral rearm, shared note/pedal and transport failure. No promise that every instrument can run full capability concurrently.
