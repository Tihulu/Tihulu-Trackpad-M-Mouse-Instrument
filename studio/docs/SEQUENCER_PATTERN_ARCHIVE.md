# Offline sequencer pattern archive (v1)

This is draft editor data, not a live playback session, preset activation,
hardware permission, DAW import, or application file-picker implementation.

`SequencerPatternArchive` validates note and drum grids with the same bounded
validation as `FrozenSequencerPattern`. Note cells store index, optional MIDI
pitch (rest when absent), velocity and gate; drum cells store index, voice and
velocity. Tempo, subdivision, length, loop and optional complete seeded groove
are retained. Note channels are zero-based; drum playback remains channel 10.
Cell order and transient UI UUIDs are not part of the archive identity.
Signed zero velocity is normalized to positive zero during validated archive
construction, including import. Both forms remain muted; equal musical
cells have the same encoded representation and do not consume an undo
entry. Nonzero velocity precision and the v1 schema are unchanged.
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

## Transactional next-pattern editing

`SequencerDraftEditor` owns an offline next draft only. It reuses the
canonical archive and the existing 16-entry `ComposerDraft` undo bound.
A caller explicitly requests a same-kind replacement, import, note/drum
batch edit or options edit. The entire candidate must validate and fit
the archive byte limit before the current draft or undo history changes.
A throwing callback or invalid candidate cannot partially change the
editor. No-op musical changes do not consume history even when restored
cell UUIDs differ. An explicit clear is undoable, but an empty draft
still cannot be frozen for playback.

Tempo, subdivision, per-cell velocity and note gate remain editable.
Shortening a grid with cells outside the new length is rejected until
the caller explicitly deletes those cells in the same batch. Changing
away from sixteenth-note subdivision requires clearing incompatible
groove settings. Drum channel remains fixed; note channel is zero-based.
Options changes are explicit and undoable. Use `editNotesAndOptions` or
`editDrumsAndOptions` to change grid and dependent options in one transaction
and one undo entry (for example, change subdivision while clearing groove).
The original single-argument edit methods and `setOptions` use the same
transaction path. A note draft requires a channel; a drum draft forbids
a channel override. An invalid combined change or a thrown callback leaves
both document and history unchanged. The editor may hold up to
16 previous validated documents, so keep this work off the real-time path.
It encodes a changed candidate once to enforce the byte bound; no real-time
or UI latency acceptance is implied.

A previously frozen take remains an immutable value. The editor cannot
stop or start an active take, assert playback state, release a MIDI route
or provide a scheduler playhead. The host must wire these independently.

## REL-SEQ: offline continuous automation compatibility audit

Reviewed sequencer predecessor `ef8ee9b7a52c4f98800d940bdd6d85807f2301db`
and coordinator relative-control candidate
`7e85ad90f5e63b66d088553ff6d53cbddf2667fe` (REL-02). No recorded
continuous automation lane was found in the sequencer archive or nominal
clip model at those inspected boundaries.

| Existing boundary | Current representation | Relative automation readiness |
|---|---|---|
| SequencerPatternArchive v1 | Note cells, drum hits, tempo, loop and seeded groove | Unsupported automation/reference/endpoint fields rejected |
| FrozenSequencerPattern / MIDIClip | Nominal note on/off timing, pitch, channel, velocity | No CC/pitch-bend lane; no gesture replay |
| MIDIFileParser | Note projection and tempo-derived timing | CC and pitch bend discarded; cannot round-trip recorded automation |
| BoundedMIDIPlanInput | Strict bounded nominal clip JSON | Unsupported continuous fields rejected |
| TunedMIDIClip | Fixed MPE member setup and note events | Tuning setup is not expressive recorded automation |

No live relative transform, receiver reference, endpoint mapping, or
automation schema has been added by this slot. Ordinary SMF note projection
must not be advertised as preserving a complete MIDI performance. In
particular, importing a relative recording through the note-only parser
would lose its automation; this limitation must remain explicit.

If a future coordinator-approved automation format is needed, distinguish
absolute output events from raw gesture samples and reference provenance.
Do not apply relative displacement twice to already resolved output events.
Receiver-confirmed values require an authorized adapter with matching
endpoint/channel/parameter, freshness and ownership; no outgoing intent or
remote ACK may be promoted to feedback. Preserve per-lane identity,
ordering, range, cancellation and cleanup, and never overwrite MPE member
base bends. A recorded reference is historical data, not fresh authorization
for a new clutch. A new schema, host integration and actual DAW tests are
separate future work; no physical or real-time acceptance is claimed.

### Timing verification scope

The regression matrix covers 52 tempo/subdivision combinations (including
20 and 300 BPM, subdivisions 1 and 960), 18 seeded groove combinations
with repeat-note nonoverlap, and the maximum tick/step boundaries.
An exportable long frozen clip is not automatically eligible for bounded
one-shot playback; the existing scheduler admission remains authoritative.
These are deterministic offline invariants, not live timing or jitter
measurements. No runtime timing limits were changed.
