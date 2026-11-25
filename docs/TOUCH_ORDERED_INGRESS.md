# Ordered Touch ingress performance candidate

Base: PR #139 head 9b6b4f857cadabb010b34426d9e9454f6b89b4b4. Native Swift only.

Committed mapped snapshots previously scheduled independent MainActor tasks after leaving the publication lock. The cursor rejects out-of-order revisions/sequences, so scheduling reorder could lose a short edge. This is a source-level risk, not a confirmed cause of the user's DAW dropout.

New path enqueues under the existing publication lock and signals a single scheduled consumer outside that lock. FIFO capacity 64 pending snapshots, at most 16 per actor turn, no musical snapshot coalescing. Current generation, monitor identity and revision fences retained. If the pending queue overflows or a current live snapshot is at least 150 ms old, stop Touch and Helper through their existing scoped cleanup paths and require explicit restart. Other independent patch paths retain their existing mailbox and watchdog. Stale preview-only frames can be discarded. This is a fault boundary, not a musical latency target. MainActor scheduling and CoreMIDI serialization remain unchanged. Native callbacks that complete mapping out of raw frame order can still be rejected by the existing per-surface frame fence; this candidate does not claim to fix prepublication reordering.

Isolated Swift 6.2.1 Linux probe compiled the exact OrderedTouchInbox.swift blob 9ce921c9ebb78afd80cb06ac22f3cc4f6084d6fd. PASS: 10,000 ordered synthetic edges, wake ownership, overflow recovery, close fence and 64 concurrent submissions without loss or duplication. Five Swift Testing scenarios added for repository CI. This is a functional test, not a hardware speed benchmark.

Required: native CI, independent review of stop/restart and overflow while a batch is in flight, physical rapid tap / roll / glissando / MPE / sustain / combined surface test with DAW MIDI monitor. Verify no queued attacks from retired sessions, no orphaned notes, unchanged separate patch output. Compare timing diagnostics, audio overload indicators and CPU before/after at equal DAW settings. Preserve stable application until acceptance.
