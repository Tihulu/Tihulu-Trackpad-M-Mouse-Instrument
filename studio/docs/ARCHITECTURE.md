# NoSpeaker Studio Architecture

## High-level flow

```text
SwiftUI Studio
   |
   +-- Voice
   +-- Touch Instrument
   +-- Note Sequencer
   +-- Drum Sequencer
   +-- MIDI / Logic Pro
   +-- Audio File
   +-- Trackpad Speaker
   +-- Diagnostics
          |
          v
   NoSpeakerCore
   +-- Music theory
   +-- Note/drum pattern renderer
   +-- Standard MIDI File parser
   +-- LPC/formant voice analyzer
   +-- Audio-to-haptic spectral converter
   +-- Haptic safety policy
          |
          v
   NoSpeakerMac
   +-- MultitouchSupport Force Touch driver
   +-- Touch callback bridge
   +-- Haptic playback scheduler
   +-- macOS `say` voice renderer
   +-- AVFoundation audio-file reader
   +-- CoreMIDI virtual destination/input
   +-- ScreenCaptureKit system-audio capture
          |
          v
   Force Touch trackpad motor
```

## Private-framework boundary

Only `NoSpeakerMac/HapticTrackpadDriver.swift` talks directly to Apple's private `MultitouchSupport` framework. The symbol names, actuator creation path, actuation dictionary shape and touch record offsets intentionally remain close to os6/nospeaker v1.0.

Everything above that boundary uses typed Studio models. This makes the private API replaceable if Apple changes it and keeps safety policy centralized.

## Voice pipeline

```text
Typed text
   -> /usr/bin/say renders local 16 kHz float WAV
   -> 25 ms analysis windows / 10 ms hop
   -> pitch autocorrelation + LPC roots
   -> F1/F2 resonance selection
   -> two weighted haptic tones for voiced frames
   -> deterministic high-frequency consonant frames
   -> safety clamp
   -> Force Touch actuator
```

The LPC/formant strategy is adapted from the original MIT-licensed nospeaker implementation.

## Touch Instrument

The physical touch callback returns normalized X/Y and contact size. Studio maps X to a selected scale, Y to vibrato depth, and contact size to level. The selected note is rendered through the same safe haptic output path.

## Sequencers

Note and drum sequences are represented by cross-platform `NoSpeakerCore` types. Timing is rendered into `ScheduledHapticEvent` values and executed by `HapticPlaybackEngine`.

## MIDI / Logic Pro

CoreMIDI exposes a virtual destination named `NoSpeaker Haptic MIDI` and an input port connected to current system MIDI sources. MIDI 1.0 UMP channel-voice messages are decoded locally. Channel 10 follows the built-in General MIDI drum map.

Standard MIDI Files are parsed in `NoSpeakerCore` without an external dependency. Formats 0 and 1 with PPQN timing are supported; tempo meta events are respected.

## Audio and Speaker Mode

AVFoundation provides decoded PCM for dropped audio files. ScreenCaptureKit provides live system PCM for Speaker Mode. Both feed the same `HapticSignalProcessor`, which offers Melody, Rhythm, Voice and Full Mix conversion profiles.

The live system-audio path is a capture-and-convert feature. It is deliberately separate from a true CoreAudio virtual output device.

## Safety and cancellation

`HapticSafetyPolicy` clamps frequencies, amplitudes, frame duration, tone count and overall level. The UI's Panic Stop cancels playback tasks, stops touch/MIDI/system-audio modes, and closes the actuator. Reconnect is explicit.
