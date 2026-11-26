# MUSIC-UX finding register

Draft PR #172 handoff `c427b1356084ff5d81de0e8550e2aa9edea5b8f5`, tree `f5f405a3ff1786850eb2de0571bea192d3d09d7a`. The original auditor inspected native revisions `a90a7fb` and `c6c8417` and Pages revision `3895be7`. The linked passes retain the original source locations, reproduction proposals, dependencies and limitations.

The audit contains **53 findings, 15 P1 and 38 P2**. The coordinator recorded **11 remediation candidates, 0 independently closed**. A commit in the candidate column marks implementation work that still requires review. An open row can have related work. UX-020, for example, has offline scale mapping and injected-sink tests while live USB input/DAW acceptance remains open. UX-045 and UX-052 have offline custom layout editing and storage. Their physical map legibility and independent live profiles still need verification.

Each check below is pending independent acceptance at this handoff. For closure, record the reviewer, exact commit, exercised surface, test or recording, and any hardware/OS/DAW versions used. Preserve the original ID and link failed runs when revising a candidate. The source audits and build results do not establish physical acceptance.

| Finding | Priority | Workflow | Implementation entry point | Candidate | Outstanding acceptance check |
| --- | --- | --- | --- | --- | --- |
| [UX-001][7200573662] | P1 | Both mobile piano layouts | MobileTouchKeys / TouchPianoPreviewActivity | Open | Exercise black-key precedence, sparse slots, two fingers and rotation using common draw/hit geometry. |
| [UX-002][7200573662] | P1 | iPhone live piano stage | MobileTouchPianoPreview | Open | Fit the whole armed playing area on a compact landscape screen and retire safely when it resizes. |
| [UX-003][7200573662] | P1 | Android live piano stage | AirPreviewActivity / TouchPianoPreviewActivity | Open | Reach a full-window stage with release visible at compact and expanded sizes. |
| [UX-004][7200573662] | P1 | Mobile pitch and route disclosure | MobileLANCapabilities | Open | Verify authorized labels, withheld metadata, transposition and assignment revocation with old clients. |
| [UX-005][7200573662] | P1 | Mac compact window | StudioApp / ContentView | Open | Reach scoped Stop and Panic with a narrow window and enlarged text. |
| [UX-006][7200573662] | P2 | Duplicate capture configuration | ContentView / CaptureSettingsPanel | Open | Record a shortcut in one place and verify its state, cancellation and Escape from each play mode. |
| [UX-007][7200573662] | P1 | Mac session overview | ContentView / StudioController | Open | Start each supported source and verify its visible status and independently scoped stop. |
| [UX-008][7200573662] | P2 | Builder navigation | InstrumentBuilderView | Open | Complete preparation, routing and testing by keyboard while retaining edits and seeing faults. |
| [UX-009][7200573662] | P2 | Tuning discoverability | CustomScalePanel / WorldTuningLibrary | Open | Discover a compatible tuning, inspect legacy copy semantics and reject unsupported output. |
| [UX-010][7200573662] | P1 | Classic web piano slides | RemoteLoopbackPageServer / moveStrip | Open | Slide two fingers across white and black keys and verify edge order, cancellation and release. |
| [UX-011][7200573662] | P2 | Web mode selectors | RemoteLoopbackPageServer / choosePianoTool | Open | Verify one selected mode and the same release and neutral acknowledgment on each access path. |
| [UX-012][7200573662] | P2 | Web phrase readiness | RemoteLoopbackPageServer / startPhrase | Open | An all-rest or unavailable sequence explains its disabled state. Metadata changes preserve edits. |
| [UX-013][7200591447] | P1 | Camera-independent pairing | MobileAirPreviewView / AirPreviewActivity | `f20c7f4` | Exercise manual touch pairing with denied camera access and a valid host. Verify QR and sensor gates. |
| [UX-014][7200591447] | P1 | Accessible mobile piano keys | MobileTouchPianoPreview / TouchPianoPreviewActivity | Open | Operate individual authorized keys with VoiceOver and TalkBack, then lose focus while held. |
| [UX-015][7200591447] | P2 | Accessible Android setup | AirPreviewActivity | Open | Inspect TalkBack names, focus order, zoom value, field labels and layout at 200% font size. |
| [UX-016][7200591447] | P2 | Mobile arm and rearm reasons | MobileTouchPianoPreview / TouchPianoPreviewActivity | `10c8f6f` | Distinguish visibility, inactive window, invalid assignment, stale contact and transport refusal. |
| [UX-017][7200591447] | P2 | Mobile release and connection state | MobileAirPreviewView / AirPreviewActivity | Open | Hold, then release with and without an ACK. Confirm the displayed stop/disconnect scope. |
| [UX-018][7200591447] | P1 | Native selection by capability | MobileLANCapabilities / MobileAirMode | Open | Exercise each negotiated family, older clients, explicit rearm and rejection of another family. |
| [UX-019][7200591447] | P2 | MIDI bridge stop dependencies | StudioController / stopMIDI | Open | Show active dependencies and verify stopping one source preserves other users of the bridge. |
| [UX-020][7200591447] | P1 | Physical MIDI scale adaptation | PhysicalKeyboardScaleMap / PhysicalKeyboardScalePreview | Open | Use real MIDI input and an isolated destination. Check mapped and original keys, note-off and sustain. |
| [UX-021][7200591447] | P2 | Interface localization | ContentView / MobileAirPreviewView / AirPreviewActivity | Open | Verify EN, TR and DE controls, accessibility labels, errors and longer text on all stages. |
| [UX-022][7200591447] | P2 | Pages playable surface duplication | gh-pages docs/index.html | Open | Inspect the simulated physical monitor and playable keyboard independently, then cancel a held key. |
| [UX-023][7200591447] | P2 | Pages capability and translation labels | gh-pages docs/index.html | Open | Verify displayed revision, simulation labels, and translated screen bodies at mobile size. |
| [UX-024][7200591447] | P2 | Mac accessible held notes | PerformanceControlsView / HeldNoteControl | Open | Exercise bounded pulses and a documented variable-duration path with focus loss and key repeat. |
| [UX-025][7200872427] | P1 | USB Scale Assistant discovery | PhysicalKeyboardScalePreview / NativeMIDIMonitor | Open | Reach the workflow from device selection. Disambiguate identical names and remove a source. |
| [UX-026][7200872427] | P2 | Input anchor and output tonic | PhysicalKeyboardScalePreview | Open | Verify D-major membership, C-input to D-output remap and explicit inherited or independent root. |
| [UX-027][7200872427] | P1 | USB Guide, Lock and Remap policy | PhysicalKeyboardScaleMap | Open | Compare every policy on the same physical keys and preserve original or tuned output as configured. |
| [UX-028][7200872427] | P2 | Physical keyboard range | PhysicalKeyboardScalePreview | Open | Set a device range and inspect or calibrate keys beyond the displayed C4 octave. |
| [UX-029][7200872427] | P2 | Per-key pitch explanation | PhysicalKeyboardScalePreview / MicrotonalKeyboardTuning | Open | Inspect mapped anchor, bend, cents and Hz and distinguish muted from out-of-range keys. |
| [UX-030][7200872427] | P2 | Tuning edit and import controls | CustomScalePanel / MicrotonalKeyboardTuning | Open | Exercise arbitrary supported EDO, ratio data, reference frequency and invalid tuning input. |
| [UX-031][7200872427] | P2 | Persistent accessible keyboard profiles | PhysicalKeyboardScalePreview | Open | Reopen the device profile and announce selected key, tonic, pitch and assignment using assistive input. |
| [UX-032][7200872427] | P1 | USB input activation and DAW isolation | PhysicalKeyboardScaleLock / NativeMIDIMonitor | Open | Verify source identity, neutral arm, destination isolation, unplug and held-note cleanup with a DAW. |
| [UX-033][7200872427] | P2 | USB controller expression policy | PhysicalKeyboardScaleLock | Open | Check binary sustain and document or validate half-pedal, aftertouch, modulation and bend routing. |
| [UX-034][7200872427] | P2 | Signed MIDI note names | MusicTheory / ChordPads | `1a4c25f` | Round-trip every MIDI note, including C-1 and bounds, through the parser and both entry points. |
| [UX-035][7200894851] | P2 | Adaptive iPad performance stage | TihuluAirPreviewApp / MobileAirPreviewView | Open | Exercise portrait, landscape, Split View and Stage Manager with visible release and safe resize. |
| [UX-036][7200894851] | P2 | Adaptive Android tablet stage | AirPreviewActivity / TouchPianoPreviewActivity | Open | Test expanded and compact windows, large controls, rotation and focus loss while holding notes. |
| [UX-037][7200963030] | P1 | Touch Bar pitch labels | TouchBarProfile / ContentView | `a7fa47d` | Compare each label and played note across base pitches in native and on-screen controls. |
| [UX-038][7200963030] | P2 | Touch Bar press duration | TouchBarProfile / ContentView | `a7fa47d` | Measure native tap and on-screen held duration independently. Verify release on cancellation. |
| [UX-039][7200963030] | P2 | Note sequencer playhead | ContentView / NoteSequencerView | Open | Compare actual playing step to visual feedback during rests, looping, edits and stop. |
| [UX-040][7200963030] | P2 | Drum sequencer playhead | ContentView / DrumSequencerView | Open | Confirm the visible playhead and triggered drum lane at the active tempo, including rests. |
| [UX-041][7200963030] | P2 | Sequencer draft versus active take | ContentView / SequencerOutputPanel | Open | Edit while playing, verify the frozen take, and explicitly select the next take. |
| [UX-042][7200963030] | P2 | Smart Compose replacement | PatternComposerPanel / ComposerDraft | `e897db3` | Preview, replace, undo and check intervening manual edits and invalid input for notes and drums. |
| [UX-043][7200963030] | P2 | XY pad behavior and routing | PerformanceControlsView | `578074b` | Check both destinations, held and released values, latch labels and scoped cleanup. |
| [UX-044][7200963030] | P2 | Unavailable Builder widgets | PerformanceControlsView | `578074b` | Exercise incompatible keys and endpoints. Verify a reason is visible and unrelated widgets still work. |
| [UX-045][7200963030] | P2 | Dense physical surface map | ContentView / CustomSurfacePadEditor | `0102024` | At high note density, check selected pitch/degree and read the monitor on both physical surfaces. |
| [UX-046][7200963030] | P2 | Mac camera calibration scope | AirInstrumentPanels / InstrumentBuilderView | Open | Change device, mirror and hand. Verify captured endpoints match the affected routes and tracking loss releases. |
| [UX-047][7200963030] | P2 | Web Air Stick kit overlap | RemoteLoopbackPageServer / syncKit | Open | Create overlapping or hidden targets. Confirm visible selection, deterministic priority and no unintended strike. |
| [UX-048][7200963030] | P2 | Scale catalog consistency | ContentView / ChordPads / RemoteLoopbackPageServer | Open | Compare shared scale IDs and allowed pitches across compatible independent and linked surfaces. |
| [UX-049][7200977982] | P2 | iOS Air mode eligibility | MobileAirPreviewView / MobileAirMode | Open | Inspect unavailable reasons for RGB-only, depth, key-only, helper-only and sparse assignments. |
| [UX-050][7200977982] | P2 | Mode-specific Air feedback | MobileAirPreviewView / AirPreviewActivity | Open | Exercise pinch, chord, strings, beam and helper gestures. Inspect loss, confidence and the actual logical slot. |
| [UX-051][7200977982] | P2 | Android depth calibration parity | AirPreviewActivity / MobileAirPreviewView | Open | Validate custom near/far limits and presets on supported devices, with invalid ranges and active edits. |
| [UX-052][7200977982] | P2 | Independent physical playing profiles | SurfaceMusicRouting / CustomSurfacePadEditor | `0102024`, `100c0d7` | Set distinct scale, tonic, width and kit on two physical inputs. Verify reconfiguration releases only its owner. |
| [UX-053][7200977982] | P2 | Touch Bar velocity and last control | TouchBarProfile / ContentView | `a7fa47d` | Round-trip velocity and verify the last-zone guard, profile epoch and explicit arm on each surface. |

The expanded instrument checklist covers each instrument and device across output, orientation, activation, expression, lifecycle and accessibility. The subsequent XYZ requirement adds measured depth, device calibration and owner-scoped loss checks to the Air and depth work. Retain UX-046 and UX-049 through UX-051 when recording XYZ candidates. [Instrument checklist][7200977982] · [XYZ handoff][7202968660] · [Coordinator candidate count][7202637354]

[7200573662]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7200573662
[7200591447]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7200591447
[7200872427]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7200872427
[7200894851]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7200894851
[7200963030]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7200963030
[7200977982]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7200977982
[7202968660]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7202968660
[7202637354]: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/172#issuecomment-7202637354
