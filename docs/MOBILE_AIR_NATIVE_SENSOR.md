# Mobile Air — native sensor preview (experimental)

The iOS/iPadOS 17+ library NoSpeakerMobileCapture is isolated from Studio's
release app. It is not an installable companion and does not open a network
connection or emit MIDI. A later companion must supply NSCameraUsageDescription
and explicit user permission, local-network permission and the existing
authenticated host handshake before musical transmission. Never bypass TLS.

## Sensor paths

- Rear/front RGB: AVCaptureSession + Vision hand pose, at most 15 inferences/s.
- Rear camera + real LiDAR: ARWorldTrackingConfiguration with sceneDepth only
  if supportsFrameSemantics returns true. One ARFrame supplies both image
  and depth; no separate simultaneous camera session, fake depth or front LiDAR.
- Use an explicit EXIF orientation for the unmirrored camera image; independently
  rotate/mirror musical XY coordinates. Test all four physical orientations.
- Palm depth: 3x3 samples at midpoint of reliable wrist and middle MCP.
  At least five medium/high confidence samples in a consistent depth cluster.
  Reject invalid depth, incomplete neighbourhoods, limited tracking and stale data.
- Distinct left/right hand identities; missing/ambiguous role releases output.
  No automatic switch from LiDAR to RGB or from two-hand to one-hand chords.
- Native source is single use; stop on permission loss, scene inactive,
  background, interruption, disconnect or requested mode change. Never retain
  raw images, transmit them or save them. Mailbox cap 16; overflow is terminal.
  Consumer must poll independently and call projection.expire(now:) even when
  frames cease; use MobileAirSensorSource.now clock. Stop/rearm explicitly.

## Musical projection

Pinch keys, two-hand chords, three air strings, X/Y/aperture/speed helpers,
pinch/toggle helper, beam notes and continuous depth helper. Defaults 0.25–0.85 m,
adjustable from 0.10 to 3 m with at least 0.10 m span. Actual sensor operating range
and hand accuracy must be measured on hardware; no calibrated 3D mesh claim.
Helper levels use existing continuous logical pedal lane; binary CC64 ownership
and full independent multi-axis/dual-hand parity require additional host work.
Existing Mac camera chord selection and helper gate semantics reused.
MobileAirWireLane encodes existing v5 key and v6 pedalboard snapshots only,
not an authenticated sender. It must have exclusive lane ownership and
explicit neutral ACK handshake, bounded transport and host cleanup.

## Acceptance

CI compiles the iOS library for generic iOS without signing; no camera test
on CI. Required device gates: iPhone/iPad RGB-only and LiDAR-supported hardware,
rear-camera-up stand, all orientations, swapped roles, empty scene, two hands
with ambiguity, foreground/background, permission denial, near/far calibration,
occlusion/reflective surfaces/low confidence, physical note release, no old
event after rearm, measured p50/p95/p99 gesture-to-MIDI/audio latency.
Native QR/TLS transport, actual mobile app packaging and physical tests remain
HOLD. Do not claim the browser has access to ARKit scene depth.
