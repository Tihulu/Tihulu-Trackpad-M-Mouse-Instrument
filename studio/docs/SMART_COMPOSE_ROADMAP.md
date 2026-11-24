# Smart Compose and AI-assisted music roadmap

User goal: lightweight local music generation on an Apple M2 with 8 GB unified memory, alongside a DAW. Inspired by the editable performance workflow of Logic Pro Session Players, not an implementation of Apple's proprietary algorithms.

References:
- Apple Session Player overview: https://support.apple.com/en-qa/guide/logicpro/lgcpbf624405/mac
- Performance controls (complexity, intensity, fill, swing, regeneration): https://support.apple.com/en-asia/guide/logicpro/lgcp74b34026/mac
- Apple Creator Studio and Synth Player: https://www.apple.com/uk/newsroom/2026/01/introducing-apple-creator-studio-an-inspiring-collection-of-creative-apps/
- Step Sequencer: https://support.apple.com/en-mt/guide/logicpro/lgcp39acefc9/mac

## First increment
Actual rule-based symbolic composer integrated into the existing 16-step drum and note editors. Rock, House, Hip-Hop, Funk, seeded groove variation, complexity and end fills. Melody, Bass and Arpeggio, current chord-bank slot, nominal scale/chord tones, density and seeded variation. Generate writes editable steps, one-level undo restores the previous draft, no autoplay, no downloads, no new runtime dependencies. Existing Play and workspace data paths are reused. Not trained ML or natural language AI; UI identifies it as rule-based. Current sequencer playback remains haptic; note gate/velocity are existing controls and drum velocity remains existing fixed value. Custom tuning is nominal MIDI in this editor. No claim of DAW export or chord progression following yet.

## Next useful increments
1. Shared symbolic phrase/arrangement model with per-step velocity, gate, probability, swing, accent and groove; variable phrase lengths, drums, melody, bass, arpeggio, chord voicing. Chord progression follow across measures. Generate selected steps only, lock/edit notes, variation and undo; never overwrite an arrangement without a deliberate action.
2. Standard MIDI file export/import and live MIDI output with scoped note ownership, DAW tempo/transport integration, optional Trackpad/Both. Export generated parts on dedicated tracks/channels so Logic and other DAWs can edit them.
3. Optional lightweight trained symbolic model (Core ML or small native inference), conditioned on style, tempo, scale/chord, rhythmic controls and partial sequence; investigate permissively licensed model/training data, verify provenance and use measurable quality benchmarks. No compulsory model or LLM; no cloud, account, or background generation. Compare against rule-based baseline. If ML fails quality or resource targets, keep the working baseline and label it accurately.
4. Optional natural-language instruction parsing only if useful; do not require it to generate music. Broader instruments, rhythmic subdivisions including aksak, accompaniment, continuation and constrained variation.
5. Native M2 8 GB target: measure idle CPU/RAM, generation time, live MIDI jitter, thermal behavior and simultaneous Logic playback. No performance claim without actual measurement. Apple Vision and voice models remain separate optional capabilities.

Three core tests cover style anchors, valid editable drum cells, reproducibility, density, nominal scale/chord and custom voicings. Native UI, audible output and DAW acceptance remain pending. Stable release unchanged.
