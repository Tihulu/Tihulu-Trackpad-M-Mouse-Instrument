# Independent Swift engine consumer

Run from the repository root:

```sh
swift run --package-path examples/EngineConsumer engine-consumer
```

This is a separate SwiftPM package using only the public NoSpeakerCore library.
It constructs an instrument, combines note and sustain sources, sends the
resulting commands into an in-memory sink, and verifies scoped cleanup.
No Studio UI, native device access or real MIDI is used. The path dependency
assumes the repository layout is unchanged. Forks can point to their own
checkout of the studio package; a remote package-at-repository-root is not
advertised. API stability is experimental. Preserve MIT attribution.
