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
swift build --product tihulu-mac-instrument-engine
swift run --skip-build tihulu-mac-instrument-engine capabilities
swift run --skip-build tihulu-mac-instrument-engine patch example > patch.json
swift run --skip-build tihulu-mac-instrument-engine patch validate patch.json
swift run --skip-build tihulu-mac-instrument-engine patch routes patch.json
swift run --skip-build tihulu-mac-instrument-engine groups example > groups.json
swift run --skip-build tihulu-mac-instrument-engine groups ports groups.json
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
swift run --skip-build tihulu-mac-instrument-engine groups simulate groups.json frames.json
```

Replay is bounded, uses one logical lease per source kind, rejects invalid frames and sequences, and emits final cleanup. It is not real-time timing, hardware discovery, remote authentication, watchdog or MPE acceptance. Intentional shared signals require `--allow-layering`. There is no live-start CLI command in this slice.

### Additional offline engine commands

```sh
swift run --skip-build tihulu-mac-instrument-engine scale plan 60 "0, 180, 400, 700, 1200"
```

Returns MIDI anchors, pitch bend values, bend range and tuned frequencies using the existing CustomScale model. Unsupported quarter-tone ties or out-of-model degree layouts are rejected, not approximated. This is pitch planning, not a live MPE session.

```sh
cat > mix.json <<'JSON'
[
  {"source":"touch","frame":{"tones":[{"frequencyHz":220,"amplitude":1}],"durationMS":18,"level":0.4}},
  {"source":"gamepad","frame":{"tones":[{"frequencyHz":330,"amplitude":1}],"durationMS":18,"level":0.4}}
]
JSON
swift run --skip-build tihulu-mac-instrument-engine haptics mix mix.json
```

Returns a bounded mixed haptic frame as data, using the existing HapticFrameMixer. No motor activation or physical vibration claim.

### MIDI file and sustain shell engines

The offline MIDI commands reuse the production MIDIClip and MIDIClipWriter. Inputs are JSON with zero-based channels. Outputs contain actual Standard MIDI File format 0 bytes encoded as base64, not a playback session. Unsupported fields (including tuning metadata) fail instead of silently dropping intonation.

```sh
cat > clip.json <<'JSON'
{"bpm":120,"length":960,"notes":[{"start":0,"duration":480,"channel":0,"pitch":60,"velocity":90}]}
JSON
swift run --skip-build tihulu-mac-instrument-engine midi encode clip.json > clip-result.json
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
swift run --skip-build tihulu-mac-instrument-engine sustain simulate pedal.json
```

This uses LegacySustainOwners and emits only CC64 transitions, with final cleanup. Owner channels are zero-based in input, one-based in output. The first owner engages a pedal and the final owner releases it. No expressive CC, velocity or audio is generated.

### Expressive Helper ownership and external API consumer

The same continuous control arbitration used by Studio can be exercised as a trace:

```sh
cat > helper.json <<'JSON'
[
  {"owner":"touch","controls":[{"target":{"kind":"controlChange","channel":0,"number":7},"value":35,"neutral":127}]},
  {"owner":"helper","controls":[{"target":{"kind":"controlChange","channel":0,"number":7},"value":48,"neutral":127,"preserveOnRelease":true}]},
  {"owner":"touch","controls":[]},
  {"owner":"helper","controls":[]}
]
JSON
swift run --skip-build tihulu-mac-instrument-engine helper simulate helper.json
```

Each step replaces one owner's complete continuous-control snapshot. Allowed owners are touch, legacyTouch, helper and touchBar. Input channels are zero-based; output channels are one-based. CC and pitch-bend targets use the production LegacyContinuousOwners validator. Duplicate targets and reserved CCs fail; sustain uses the separate sustain command. A preserved gain value is not forcibly reset when the final owner leaves. Output contains simulated transitions, not MIDI delivery or RPN wire bytes.

To test a real independent SwiftPM consumer from the repository root:

```sh
swift run --package-path examples/EngineConsumer engine-consumer
```

This separate package depends only on the public NoSpeakerCore library and verifies note plus sustain ownership and cleanup in memory. The developer CI builds it on Linux and macOS. See AGENTS.md for the coding-agent starting point.

### Tuned MIDI, groove, and voice analysis

The executable is named `tihulu-mac-instrument-engine` to avoid collisions with other TIHULU products. There is no legacy generic command alias. After building, use `swift run --skip-build tihulu-mac-instrument-engine` or the executable in the SwiftPM binary directory.

```sh
cat > tuned.json <<'JSON'
{"root":60,"degreeCents":"0, 180, 400, 700, 1200","clip":{"bpm":120,"length":960,"notes":[{"start":0,"duration":240,"channel":0,"pitch":60,"velocity":90},{"start":0,"duration":240,"channel":0,"pitch":62,"velocity":90}]}}
JSON
swift run --skip-build tihulu-mac-instrument-engine midi tuned tuned.json > tuned-result.json
python3 -c 'import json,base64; d=json.load(open("tuned-result.json")); open("tuned.mid","xb").write(base64.b64decode(d["data"],validate=True))'
```

The tuned export uses the existing TunedMIDIClip writer. It requires a single melodic input channel, excludes percussion input channel 10, and assigns up to 15 dedicated lower-zone MPE member channels with fixed bends for the entire clip. The receiver must support MPE and retain/import setup messages. It does not promise that a particular DAW preserves them. Unsupported scale degrees or exhausted channel capacity fail, rather than falling back to 12-TET.

`midi groove FILE` takes a strict JSON object with `clip` and `groove` fields. Groove fields are swing, humanize, intensity, accent, probability and seed, using the existing bounded sixteenth-note policy. Output includes transformed symbolic clip and base64 SMF0. It is nominal-pitch export; microtonal data must use the tuned exporter, not be inserted as ignored fields.

`voice analyze FILE` accepts `{"sampleRate":16000,"samples":[...]}` with 400 to 80000 normalized mono PCM samples in [-1,1]. It runs the existing HapticVoiceAnalyzer and returns scheduled haptic frames as data. This is analysis only, not TTS, speech recognition, microphone capture, physical vibration or audio playback. The five-second input cap is a conservative CLI development bound. No network or automatic model downloads.

### Gamepad and camera replay

```sh
swift run --skip-build tihulu-mac-instrument-engine gamepad patch 2 lead 4 > controller.json
swift run --skip-build tihulu-mac-instrument-engine camera helper-patch pedalPair 3 > camera.json
```

Gamepad patch accepts slots 1-4, roles drums/lead/helper and MIDI channels 1-16. Camera Helper presets accept expressive, guitarEffects or pedalPair and channels 1-16. Both commands produce existing Studio patch archives without changing saved application settings.

`gamepad normalize FILE` takes a complete JSON snapshot of 12 buttons (0 or 1), two triggers ([0,1]), and four stick axes ([-1,1]). The response includes normalized active values, the complement of inactive signals, and the canonical input order for all axes. Inactive signals describe an ordinary snapshot lift, not forced toggle cleanup. The production GamepadFrame dead zones and validation are reused.

`camera helper-simulate PATCH FRAMES` accepts a Helper-only camera patch and an array of synthetic samples. Each row has time and now in seconds, and optional left/right objects with x, y, aperture in [0,1]. Missing hands are tracking loss; stale samples follow production tracking gates. Replay exercises neutral acquisition, pinch/toggle and release ownership without opening the camera. Final cleanup is returned as data. Combined camera instruments, raw images and physical tracking are not implemented by this command.

### App identity boundary

The SDK product is independent of the existing NoSpeakerStudio app. The installer launcher remains `tihulu-trackpad-instrument`; app bundle identifiers, MIDI port names and saved settings are not renamed. Installer release builds explicitly select NoSpeakerStudio, not the CLI product. CI checks SwiftPM dependency boundaries and validates the built app executable and bundle ID. No developer binary is copied into the application bundle.

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

The semantic backend generates normalized model embeddings, uses cosine ranking, splits text by model token budget, rejects queries exceeding that budget, and requires the same model file fingerprint on query. There is no fake vector fallback. The index contains source text and vectors and can be large; do not commit it, share private repository contents or upload it by default. Use a new output path for each commit. Selected tracked source/docs/test/script files are read from Git objects at the resolved commit, not from a dirty working tree. Symlinks, known credential-like paths, models, recordings and binaries are excluded. This is not a secret scanner: inspect the included source before sharing. Skipped oversized or unsupported windows are reported. Indexed text is untrusted data, not instructions for an AI agent. Each result includes commit, file path, Git blob ID and line range. Use `verify --repo . --index FILE` or add `--repo .` to search to independently verify every stored text row against the pinned Git tree. This detects forged source text/path/blob/line claims, but does not prove completeness, embedding integrity or the trustworthiness of instructions inside source. An index is an aid to retrieval, not evidence that every feature works or an AI has learned the repository.

## Next modularization and shell equivalents

- Pure core: extend CLI to explicit scale/MPE planning, MIDI clip/sequence export, drum/voice analysis from files and haptic frame rendering to data, reusing existing public engines and fixtures.
- Native adapters: add an explicit macOS-only headless session process for selected Trackpad, Magic Mouse, Xbox, Touch Bar, lid, camera, audio and MIDI modes after the native safety gates. Do not implement parallel drivers. Require capability checks, opt-in permissions, one shared owner, foreground lifetime, bounded input, signal-triggered Stop/Panic, cleanup debt and real hardware tests. No background daemon, global capture, recording or live output by default.
- AI integration: machine-readable capabilities and schema examples, source-level API references, optional local RAG integration. Keep revision and CI evidence separate; don't mark a draft or simulation as stable hardware support.
- Physical acceptance: existing historical complaint ledger remains authoritative. No merge/release/install from this branch without acceptance. No automatic training, model fine-tuning, cloud uploads or stable runtime changes.

CI tests index fixtures and a real commit-pinned lexical index, plus the offline CLI. Real embedding generation requires a local model and is not exercised by dependency-free CI.

## Independent native diagnostics CLI

The new `tihulu-mac-instrument-native` executable is a separate SwiftPM product, not an app launcher or a dependency of the pure offline engine. It exposes an initial read-only native API in NoSpeakerMac. Build it explicitly:

```sh
cd studio
swift build --product tihulu-mac-instrument-native
swift run --skip-build tihulu-mac-instrument-native capabilities
swift run --skip-build tihulu-mac-instrument-native preflight
swift run --skip-build tihulu-mac-instrument-native midi endpoints
swift run --skip-build tihulu-mac-instrument-native midi endpoints --names
```

Preflight returns current process Accessibility/Input Monitoring checks, connected controller count and CoreMIDI source/destination counts. These are observations, not verified device readiness or DAW reception. Endpoint names are omitted by default; the explicit names flag returns at most 256 display names per direction, without IDs or serial numbers. Names may reveal local device labels: keep the output local unless you choose to share it. No permissions are requested, no event tap or native MIDI client/port is created, no MIDI is sent and no haptic/camera/microphone session is opened. Linux capabilities return an unsupported platform flag; native queries fail with a nonzero exit and no fabricated inventory. Neither developer binary is bundled with Studio. Black-box tests cover command/flag rejection, JSON shape, platform handling and app boundary; actual hardware remains HOLD. Live CLI activation is still deliberately not supported.
