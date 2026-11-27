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
