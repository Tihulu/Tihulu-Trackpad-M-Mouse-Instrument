# Native companion standalone regression checks

These Swift sources are pure state/preflight helpers in the mobile capture target. The checks are standalone executables, not iOS UI tests or part of the shared core test target. Run from repository root on a trusted Swift toolchain. Use fresh temporary paths to avoid stale binaries.

```sh
work=$(mktemp -d)
swiftc -swift-version 6 studio/Sources/NoSpeakerMobileCapture/MobileObservationDisplayFence.swift studio/mobile-ios/tests/ObservationDisplayFenceChecks.swift -o "$work/observation-check"
"$work/observation-check"
swiftc -swift-version 6 studio/Sources/NoSpeakerMobileCapture/MobileXYZSetupAdmission.swift studio/mobile-ios/tests/XYZSetupAdmissionChecks.swift -o "$work/xyz-check"
"$work/xyz-check"
```

The first fixture uses the documented production freshness constant (150 ms); the native caller passes MobileAirSendGate.freshNS. The second exercises setup combinations and permission-request retirement; a callback cannot initiate camera capture or connect a socket. None of these fixtures uses hardware, opens a network connection, validates SwiftUI rendering, verifies actual MIDI ownership, or exercises the OS permission prompt. Preserve source/commit provenance and require native build and physical acceptance separately.

For the mode-specific effective range and strict boundary characterization:

```sh
swiftc -swift-version 6 studio/Sources/NoSpeakerMobileCapture/MobileAirEffectiveRange.swift studio/mobile-ios/tests/AirEffectiveRangeChecks.swift -o "$work/range-check"
"$work/range-check"
```

The fixture deliberately preserves the current depth predicate; nominal decimal pairs that subtract to less than 0.1 remain refused. It does not compile the SwiftUI call sites or establish sensor/host acceptance.
