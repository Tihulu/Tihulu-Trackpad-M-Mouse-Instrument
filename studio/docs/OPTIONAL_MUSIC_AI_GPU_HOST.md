# Optional music AI and remote GPU — research and implementation plan

Status: research/design only. No models installed, service enabled, network connection made or performance certified by this document. Keep the native Swift app, offline rule-based Smart Compose and stable release independent of every optional AI backend.

## Candidate engines
- Magenta MusicVAE/GrooVAE: melody, drums, humanization, trio and chord-conditioned symbolic music. https://github.com/magenta/magenta/tree/main/magenta/models/music_vae ; https://github.com/magenta/magenta-js/tree/master/music . Original Python repository archived January 2026; isolate its legacy runtime and audit checkpoint licenses. Avoid adopting the archived dependency stack into the app.
- Anticipatory Music Transformer, Apache-2.0 code and 128M small model card: https://github.com/jthickstun/anticipation ; https://huggingface.co/stanford-crfm/music-small-800k . Candidate for completion and accompaniment, evaluate constraints and model/data provenance.
- SkyTNT MIDI event transformer, Apache-2.0 repository/model card: https://github.com/SkyTNT/midi-model ; https://huggingface.co/skytnt/midi-model . Candidate for multi-instrument symbolic MIDI; inspect exact checkpoint, tokenizer, runtime and license.
- MIDI-GPT: https://github.com/Metacreation-Lab/MIDI-GPT . Controllable multitrack candidate; verify access conditions, specific checkpoint terms and training provenance.
- Basic Pitch: https://github.com/spotify/basic-pitch . Lightweight transcription (audio to MIDI, not a composition engine), Apache-2.0 code.
- ACE-Step 1.5: https://github.com/ace-step/ACE-Step-1.5 ; https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/INSTALL.md ; https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/API.md . Audio generation/repainting/cover tasks, Linux REST API. Not a source of editable MIDI by default. On a 16 GB GPU begin with 2B turbo/SFT and 0.6B or 1.7B planner according to available VRAM; XL may need CPU offload. Validate exact runtime and model licenses; no claim of measured RTX performance.
- Demucs: https://github.com/adefossez/demucs . Optional audio stem separation. Evaluate maintained alternatives, weights and data terms.

Code license does not automatically cover checkpoints, training datasets or outputs. Pin versions and hashes, review redistribution and commercial conditions before shipping. Never silently download, install, train or replace models.

## Compute routing
Modes: Native Smart (default, no model), Local AI (optional lightweight runtime), Home GPU (explicit paired LAN host), Cloud (explicit provider/key/cost cap), Auto (only user-approved backends, never cloud without approval). Support manual per-job model selection. Keep real-time touch, MIDI, haptics, tempo and panic local. Remote inference is an asynchronous composition or analysis job, never on the real-time note path.

Target Mac: Apple M2 8 GB. Target optional host: Linux NVIDIA RTX 5080 16 GB. Reuse shared TIHULU AI Tools GPU-host protocol if independently available; standalone authenticated adapter must work without that project. No Jan/Ollama API assumption for non-LLM music models. Use model-specific workers (isolated envs or containers) behind one typed broker; reuse existing compatible model files, optional explicit download. GPU capability/driver/CUDA/PyTorch probes, free VRAM and job limits; no blanket guarantee all models fit. Avoid altering the user's existing Jan/Ollama/model environment. Local compute and existing app work without network.

Pair via user-initiated authenticated session, trusted encrypted transport (HTTPS or private SSH tunnel); default bind loopback. No public port forwarding, persistent address logging, raw microphone uploads, arbitrary shell access or untrusted executable model code. Cloud credentials in Keychain, scoped auth and revocation, user-approved payload, quotas/budget, no automatic paid retry or external failover. For external access use a private VPN/tunnel. Stop/cancel jobs, queue bounds, leases with other apps, health/status, retry policy, max input/output size, deterministic metadata, no autoplay; validate result before import. Cloud can be self-hosted GPU service or compatible commercial provider after terms, privacy and cost review.

## Shared composition workflow
Typed requests include requested part, BPM, meter, bars, scale/chords, intensity, density, groove, swing, fills, seed, optional selected MIDI notes and locked steps. Output validated symbolic notes (pitch/onset/duration/velocity/channel) or explicitly audio/stems. Review/undo/import into editable sequencers; export MIDI to DAW and WAV/stems when audio; haptic playback uses existing safety gates. Separate AI-generated preview from live instrument state. No pretending waveform output is MIDI. Support Turkish aksak meters and microtonal constraints only where a backend can represent them; postprocess with explicit user choice.

## Stages
1. Existing Smart Compose #41 and shared editable phrase model, MIDI export, validated import; prove offline generation.
2. Isolated small symbolic model prototype, compare with rules on chord fit, rhythmic validity, useful variation, user preference and resource footprint.
3. Authenticated Home GPU broker and model-specific adapter; local mock tests then paired M2/Linux real job; cancel, malformed output, unavailable host, reconnect, memory pressure and simultaneous DAW tests.
4. Optional ACE-Step audio and Basic Pitch/stem workflow; explicit download and format distinctions.
5. Cloud opt-in with per-provider adapters, estimates, hard limits and privacy confirmation.
6. Shared AI Tools interoperability and model registry; no dependency on unfinished projects. Measure idle overhead, generation time, peak RAM/VRAM, result quality and MIDI latency while Logic runs. No real hardware PASS until measured.
