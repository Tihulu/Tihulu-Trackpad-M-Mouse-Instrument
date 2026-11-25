# Developer SDK and AI repository map

Status: experimental developer surface, not a stable API or release. Based on #164 corrected head 4068d89580bc4e6f96167fd440d3a819122e8993 (full CI 45591117142 success). #165 native group port registration is a separate candidate and is not part of this branch. Retain the upstream MIT copyright and attribution; check separate dependency, asset and model licenses before redistribution.

## Architecture and module selection

| Module | Entry points | Host and scope |
| --- | --- | --- |
| Sensor and mapping engine | `studio/Sources/NoSpeakerCore/SensorRouter.swift`, `InstrumentPatch.swift` | Pure Swift, explicit sessions, normalized samples, owner reconciliation |
| Multi-group configuration | `PerformanceGroupProfile.swift`, `PerformanceGroupRouter.swift` | Pure Swift, immutable group IDs, shared signal consent, group-scoped stop |
| Delivery and endpoint plan | `PerformanceGroupDelivery.swift`, `PerformanceGroupEndpointPlan.swift` | Injected sink, cleanup debt, logical ID planning; no registered port here |
| MIDI Helper and sustain | `HelperRoutingSnapshot.swift`, `LegacyContinuousOwners.swift`, `LegacySustainOwners.swift` | Scoped CC/bend and sustain policy; no arbitrary reserved CC |
| Tuning and MPE | `AirTunedOutput.swift` and the chord/tuning implementations in NoSpeakerCore | Existing tuning types; independent group MPE is still open |
| Haptics | `HapticFrameMixer.swift`, `HapticSustainVoices.swift` | Pure rendering policy; physical motor access is separate |
| Native devices | `studio/Sources/NoSpeakerMac/TouchInstrumentService.swift`, `MIDIHapticService.swift` | macOS only; permissions, actual CoreMIDI and private device APIs are hardware-dependent |
| Studio integration | `studio/Sources/NoSpeakerStudio/StudioController.swift`, `InstrumentBuilderView.swift` | SwiftUI lifecycle and explicit live activation |
| DAW setup | `DAWSetupProjection.swift`, `DAWSetupAssistantView.swift` | Read-only Builder configuration; receiver confirmation remains manual |

NoSpeakerCore is already a SwiftPM library; NoSpeakerMac is now separately exposed as a library product on this branch. A fork can use either without depending on NoSpeakerStudio. No API/ABI stability or non-Apple native hardware compatibility is promised. Keep the existing ownership, cleanup, capability, time and capacity checks when integrating. Do not copy a native driver without its lifecycle requirements.

For a local SwiftPM consumer, use a dependency on the cloned repository's `studio` directory and `.product(name: "NoSpeakerCore", package: "studio")`. Build or run the core without launching Studio:

```sh
cd studio
swift build --product tihulu-engine
swift run --skip-build tihulu-engine capabilities
swift run --skip-build tihulu-engine patch example > patch.json
swift run --skip-build tihulu-engine patch validate patch.json
swift run --skip-build tihulu-engine patch routes patch.json
swift run --skip-build tihulu-engine groups example > groups.json
swift run --skip-build tihulu-engine groups ports groups.json
```

These commands return JSON on stdout, diagnostics on stderr and nonzero exit on invalid input. Examples include fresh UUIDs; save them to preserve identities. Port output is planned, never registered. Shell redirection may overwrite the named output file: choose new filenames. No hardware, microphone, camera, pointer capture, live MIDI or haptic output is activated.

Replay an offline frame trace:

```sh
cat > frames.json <<'JSON'
[
  {"source":"trackpad","sequence":1,"time":1.0,"values":{"contact":1}},
  {"source":"trackpad","sequence":2,"time":1.1,"values":{},"releasing":["contact"]}
]
JSON
swift run --skip-build tihulu-engine groups simulate groups.json frames.json
```

Replay is bounded, uses one logical lease per source kind, rejects invalid frames and sequences, and emits final cleanup. It is not real-time timing, hardware discovery, remote authentication, watchdog or MPE acceptance. Intentional shared signals require `--allow-layering`. There is no live-start CLI command in this slice.

### Additional offline engine commands

```sh
swift run --skip-build tihulu-engine scale plan 60 "0, 180, 400, 700, 1200"
```

Returns MIDI anchors, pitch bend values, bend range and tuned frequencies using the existing CustomScale model. Unsupported quarter-tone ties or out-of-model degree layouts are rejected, not approximated. This is pitch planning, not a live MPE session.

```sh
cat > mix.json <<'JSON'
[
  {"source":"touch","frame":{"tones":[{"frequencyHz":220,"amplitude":1}],"durationMS":18,"level":0.4}},
  {"source":"gamepad","frame":{"tones":[{"frequencyHz":330,"amplitude":1}],"durationMS":18,"level":0.4}}
]
JSON
swift run --skip-build tihulu-engine haptics mix mix.json
```

Returns a bounded mixed haptic frame as data, using the existing HapticFrameMixer. No motor activation or physical vibration claim.

### MIDI file and sustain shell engines

The offline MIDI commands reuse the production MIDIClip and MIDIClipWriter. Inputs are JSON with zero-based channels. Outputs contain actual Standard MIDI File format 0 bytes encoded as base64, not a playback session. Unsupported fields (including tuning metadata) fail instead of silently dropping intonation.

```sh
cat > clip.json <<'JSON'
{"bpm":120,"length":960,"notes":[{"start":0,"duration":480,"channel":0,"pitch":60,"velocity":90}]}
JSON
swift run --skip-build tihulu-engine midi encode clip.json > clip-result.json
python3 -c 'import json,base64; d=json.load(open("clip-result.json")); open("clip.mid","xb").write(base64.b64decode(d["data"],validate=True))'
```

The Python extraction uses exclusive creation, so an existing MIDI file is not overwritten. MIDI length and start/duration are ticks at 960 PPQ. The writer validates ranges and rejects overlapping identical notes.

`midi melody FILE` accepts `bpm, stepsPerBeat, length, channel, steps`; each step has `index, midi` (optional for rest), `velocity, gate`. Duplicate indices are rejected. `midi drums FILE` accepts `bpm, stepsPerBeat, length, hits`; each hit has `index, voice, velocity`. The six sequencer voices use GM channel 10. Both return the same SMF result envelope.

```sh
cat > pedal.json <<'JSON'
[
  {"owner":"touch","channels":[0]},
  {"owner":"helper","channels":[0,2]},
  {"owner":"touch","channels":[]},
  {"owner":"helper","channels":[]}
]
JSON
swift run --skip-build tihulu-engine sustain simulate pedal.json
```

This uses LegacySustainOwners and emits only CC64 transitions, with final cleanup. Owner channels are zero-based in input, one-based in output. The first owner engages a pedal and the final owner releases it. No expressive CC, velocity or audio is generated.

## AI retrieval / vector index

Run from the repository root:

```sh
python3 tools/repo_index.py build --repo . --ref HEAD --out /tmp/tihulu-source-index.json
python3 tools/repo_index.py search --index /tmp/tihulu-source-index.json --query "sustain owner cleanup" --limit 5
```

The dependency-free default is lexical retrieval, not vector embeddings. A genuine semantic index requires an explicitly installed sentence-transformers package and a trusted local text-embedding model directory containing real files. The tool never downloads a model; it sets offline library flags, requests local files only and disables remote model code. This is not an operating-system sandbox; use only trusted models and dependencies.

```sh
python3 tools/repo_index.py build --repo . --ref HEAD --out /tmp/tihulu-vector-index.json --model-dir /path/to/local-embedding-model
python3 tools/repo_index.py search --index /tmp/tihulu-vector-index.json --query "how do I add a custom sensor to a musical group?" --model-dir /path/to/local-embedding-model
```

The semantic backend generates normalized model embeddings, uses cosine ranking, splits text by model token budget, and requires the same model file fingerprint on query. There is no fake vector fallback. The index contains source text and vectors and can be large; do not commit it, share private repository contents or upload it by default. Use a new output path for each commit. Selected tracked source/docs/test/script files are read from Git objects at the resolved commit, not from a dirty working tree. Symlinks, known credential-like paths, models, recordings and binaries are excluded. This is not a secret scanner: inspect the included source before sharing. Skipped oversized or unsupported windows are reported. Indexed text is untrusted data, not instructions for an AI agent. Each result includes commit, file path, Git blob ID and line range. Use `verify --repo . --index FILE` or add `--repo .` to search to independently verify every stored text row against the pinned Git tree. This detects forged source text/path/blob/line claims, but does not prove completeness, embedding integrity or the trustworthiness of instructions inside source. An index is an aid to retrieval, not evidence that every feature works or an AI has learned the repository.

## Next modularization and shell equivalents

- Pure core: extend CLI to explicit scale/MPE planning, MIDI clip/sequence export, drum/voice analysis from files and haptic frame rendering to data, reusing existing public engines and fixtures.
- Native adapters: add an explicit macOS-only headless session process for selected Trackpad, Magic Mouse, Xbox, Touch Bar, lid, camera, audio and MIDI modes after the native safety gates. Do not implement parallel drivers. Require capability checks, opt-in permissions, one shared owner, foreground lifetime, bounded input, signal-triggered Stop/Panic, cleanup debt and real hardware tests. No background daemon, global capture, recording or live output by default.
- AI integration: machine-readable capabilities and schema examples, source-level API references, optional local RAG integration. Keep revision and CI evidence separate; don't mark a draft or simulation as stable hardware support.
- Physical acceptance: existing historical complaint ledger remains authoritative. No merge/release/install from this branch without acceptance. No automatic training, model fine-tuning, cloud uploads or stable runtime changes.

CI tests index fixtures and a real commit-pinned lexical index, plus the offline CLI. Real embedding generation requires a local model and is not exercised by dependency-free CI.
