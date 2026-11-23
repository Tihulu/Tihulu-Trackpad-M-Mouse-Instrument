# Logic Pro and MIDI Integration

NoSpeaker Studio exposes a CoreMIDI virtual destination named **NoSpeaker Haptic MIDI**.

## Live Logic Pro workflow

1. Open NoSpeaker Studio and select **MIDI / Logic Pro**.
2. Press **Enable MIDI Bridge**.
3. In Logic Pro, route MIDI output from the desired track to **NoSpeaker Haptic MIDI**.
4. Play the project or a MIDI controller.
5. Notes arriving on channels 1–9 and 11–16 are converted to haptic pitches.
6. MIDI channel 10 uses General MIDI drum mapping for kick, snare, hats, clap and toms.
7. Use **PANIC STOP** in NoSpeaker Studio to close all active Studio playback paths immediately.

The virtual destination uses CoreMIDI's protocol-aware API and declares MIDI 1.0 UMP compatibility. CoreMIDI handles protocol conversion when necessary.

## Standard MIDI Files

The **MIDI / Logic Pro** page can load `.mid` / `.midi` files. NoSpeakerCore includes its own Standard MIDI File parser for format 0 and format 1 files with PPQN timing. Tempo meta events are respected. SMPTE time division is intentionally rejected rather than guessed.

## Drum mapping

| MIDI notes | Studio voice |
|---|---|
| 35, 36 | Kick |
| 38, 40 | Snare |
| 42, 44 | Closed Hat |
| 46 | Open Hat |
| 39 | Clap |
| 41, 43, 45, 47, 48, 50 | Tom |

## Timing note

The trackpad motor is not a conventional synthesizer. Studio converts MIDI events into short haptic actuations rather than holding an electrical audio waveform for the entire MIDI note duration.
