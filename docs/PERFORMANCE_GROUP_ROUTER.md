# Performance group routing - offline core candidate

Base: draft #162, 6e181b57be78b1247115cec0d3e3c546fd021383. Parent #161 exact CI 45588845995 success (460 core tests). #162 CI pending at creation.

This slice composes existing SensorRouter values behind one logical source-lease coordinator. It does not add a hardware engine or duplicate device polling. Group UUID is part of each command address, so identical channel/note addresses on different planned endpoints never alias. Existing per-group note gates, sustain, continuous priorities and toggle rules remain authoritative. One input frame can fan out only to mapped groups; shared signals require explicit layering consent. Connection admission stages all inner leases before publishing. Frame validation precedes mutation; sequence and time are monotonic per outer lease; deterministic inner event ordering; overflow is rejected. Batch disconnect/expiry reconciles all departing owners together. Group stop retires only that group and its bindings; global panic is terminal. No dynamic rearm or profile change while running. No endpoints, real MIDI, local haptics, network, new timer or automatic activation.

Limits: eight configured groups, 64 total mappings, 16 outer source leases. These are initial conservative development limits, not measured physical capacity. A trusted adapter must enforce existing source-specific deadlines, authentication, frame completeness and neutral rearm; the core's explicit expire method does not replace watchdogs. A source lease is not a real device identity. This candidate does not promise MPE transformation, per-note pitch or hardware scheduling.

Six regression scenarios: same note/channel separate groups, consent and scoped group stop, multiple sustain owners, invalid/stale/overflow frames, atomic expiry, session budget. Tests authored; CI and physical acceptance pending.

Next gates:
- Endpoint and delivery transaction: stable CoreMIDI unique IDs, collision handling, cleanup debt per group/target, scoped retry, failed open rollback, no port reuse while outstanding.
- Adapter integration: single host device registry, strict source-specific release deadlines, readiness and fresh neutral frames, bounded scheduling and frame coalescing without losing note edges.
- MPE: explicit isolated zones, tuning/member allocation, master-vs-member Helper policy. Do not reuse standard channel addresses or silently approximate.
- UI/DAW assistant: distinguish planned vs registered vs confirmed receiving port; group-specific mappings and physical confirmation. No test sends on opening.
- Physical matrix from docs/REPORTED_PERFORMANCE_REGRESSIONS.md, including external keyboard gain, Continuity microphone route changes, capture, short taps, multi-touch, controller unplug/rearm, three DAW tracks. Stable untouched.
