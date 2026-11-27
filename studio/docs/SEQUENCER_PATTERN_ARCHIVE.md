# Offline sequencer pattern archive (v1)

This is draft editor data, not a live playback session, preset activation,
hardware permission, DAW import, or application file-picker implementation.

`SequencerPatternArchive` validates note and drum grids with the same bounded
validation as `FrozenSequencerPattern`. Note cells store index, optional MIDI
pitch (rest when absent), velocity and gate; drum cells store index, voice and
velocity. Tempo, subdivision, length, loop and optional complete seeded groove
are retained. Note channels are zero-based; drum playback remains channel 10.
Cell order and transient UI UUIDs are not part of the archive identity.
The encoder emits sorted JSON keys, canonical cell ordering, and a 1 MiB
limit. Unknown fields, mixed note/drum payloads, unsupported versions,
malformed grids and duplicate cells are rejected. The preflight requires
UTF-8 JSON, rejects duplicate decoded object keys (including escaped key
aliases), bounds nesting to three containers and object fields to nine,
and then uses Foundation for JSON grammar and typed value validation.
Identical keys in separate cells remain valid. This is not a security or
authorization parser; do not use it as a remote wire format.

Empty, all-rest and muted patterns are valid drafts. Explicit `frozen()`
still invokes the existing MIDI clip validation and rejects silent playback.
Freezing is offline and does not arm an output or replace an active take.
The existing bounded scheduler remains responsible for cancellation, timing
and cleanup debt; no timing gate or live allocator was changed.

Example (offline only):

```swift
let draft = NoteSequence(bpm: 120, steps: [
    NoteStep(index: 0, midi: 60, gate: 0.75),
    NoteStep(index: 4, midi: 64, gate: 1)
])
let archive = try SequencerPatternArchive(notes: draft, loop: true)
let restored = try SequencerPatternArchive.decode(archive.encoded())
let take = try restored.frozen()
let schedule = try take.schedule()
```

Future coordinator integration: explicit import/replace-next-pattern action,
clear active-versus-draft labeling, user-visible validation feedback, actual
scheduler-confirmed playhead, scoped Stop, and native/physical acceptance.
The archive deliberately does not store tuning, output endpoint, capture,
permission, or hardware settings. Unknown tuning metadata fails rather than
silently degrading microtonal intent.

## Composer preview and undo acceptance

A generated preview is scoped to the current grid and the generation
settings that produced it. The note panel captures the entire chord bank,
slot, style, complexity and seed. The drum panel captures style, complexity,
end-fill and seed. Changing the captured settings discards the preview,
not the replacement undo history. Applying also checks the current context
synchronously, so a delayed UI observation cannot apply a stale candidate.
A variation captures the new seed before generation; the delayed observation
of that same seed must not discard the new preview. Empty drum generation
is reported as unavailable, not offered as a destructive replacement.

The full-bank comparison is intentionally conservative: even a bank change
that does not affect nominal composition invalidates the preview. Changing
the bank does not rewrite existing cells or previously generated notes.
Generation remains local symbolic data only, not playback or tuning activation.

Native acceptance (not established by portable tests):

1. Generate a preview, change each relevant control independently, and
   verify that Replace cannot apply the old preview.
2. Generate variation at seed 9999; the new seed 1 preview remains usable.
3. Apply a pattern, change generation settings, then Undo restores the
   preceding grid. No new MIDI or haptic output occurs on editor actions.
4. Manually edit and revert a cell, then confirm earlier preview and undo
   are invalidated. SwiftUI onChange is value observation and can coalesce
   a mutation and reversal entirely between render passes. For a complete
   guarantee, the root editor must deliver every external mutation at its
   binding setter, including clear/import and manual per-cell editing.
5. During playback, preview/apply/undo must edit only the next draft; the
   actual running snapshot, output owner and cleanup remain host-controlled.
   Neither preview status nor this archive can substitute for a real playhead
   or scoped Stop. Those integration checks require coordinator-owned code.

No independent acceptance of UX-039 through UX-042 is implied by these
portable engine checks or the isolated panel changes.
