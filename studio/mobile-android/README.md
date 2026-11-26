# Experimental Android camera sensor library

Not an APK, MIDI client, or full mobile instrument. Android API 26+, local
CameraX/MediaPipe RGB hand acquisition, Camera2 capability inventory and pure
depth/zoom validation. No Internet permission. Supply a vetted local Hand
Landmarker task asset (not bundled; model provenance/license and hash must be
reviewed before distribution). CameraX can expose front/rear/logical cameras;
physical IDs reported in inventory are not necessarily separately openable.

Call start on main thread after CAMERA permission and RESUMED lifecycle.
Use one source per session; stop before switching camera/lens/zoom. Actual
CameraX zoom state and successful zoom ACK control admission. RGB frames yield
normalized hand samples; handedness and geometry must be physically validated.
Caller must enforce exclusive capture ownership, consumer timeout <150 ms,
release/rearm and authenticated host lane admission. A local 11-mode logical projection is included; no network sender yet. Do not retain camera frames. Drain the bounded 16-frame mailbox independently. The timestamp is local analyzer receipt, not verified sensor exposure time; camera-to-MIDI latency is not yet measured.

DEPTH16 inventory and confidence decoder do not constitute a running depth
camera pipeline. Camera2 hardware depth must be aligned with RGB, capture
timestamp and calibration before use. ARCore Depth is estimated or fused,
not necessarily hardware ToF. Never silently substitute it for measured depth.
ARCore integration, live depth acquisition, native UI, signing and hardware
acceptance remain pending.

AirProjection is an initial Kotlin counterpart of the Swift projection, not a certified parity claim. Strings use a basic crossing detector; physical hand identity, confidence, and calibration need device validation. Depth modes require separately aligned observations with explicit provenance, role and matching timestamps. They cannot yet run from RgbHandSource alone.

The non-exported AirPreviewActivity is an embedding-app diagnostic view with camera inventory, front/rear switch, zoom slider and buttons, role, orientation, mirror, RGB mode and independent expiry. It requires a local reviewed model asset. It deliberately offers no live depth or MIDI, and is not a launcher APK. Wait for source teardown before reconfiguring.

## Depth reader integration (experimental)

`ArCoreDepthReader` reads a current, externally-owned ARCore raw depth/confidence image, transforms the unrotated CPU-image palm pixel to texture/depth coordinates, and rejects older/reprojected frames. It is optional (compile-only ARCore SDK); the embedding app must provide the matching runtime, AR Optional setup, a session, permission, camera image inference, and verified clock domain. Raw ARCore depth is estimated/fused, not claimed as ToF. `Camera2DepthReader` accepts only already calibrated depth-plane pixels and same-acquisition DEPTH16 images. Both use stride-aware local 3x3 majority consensus and reject invalid/low-confidence data. Neither opens a depth session or exposes Beam modes in the diagnostic Activity yet. Camera2 alignment and ARCore current-frame availability need physical validation. RGB-only clients remain independent. Android CameraX timestamp is compared to elapsedRealtimeNanos only for REALTIME camera clocks; other devices use analyzer receipt with a separate monotonic sensor watermark. No end-to-end latency guarantee for UNKNOWN clocks.

`ArCoreAirFrameProcessor` now connects CPU YUV hand inference and the depth reader on one current ARCore Frame. It requires an existing GL/session owner thread, an approved local model, and explicit rotation. It distinguishes acquisition IDs from local consumer receipt time, suppresses repeated frames, and does not replay late inference. This is not yet a session launcher or an installable depth preview. Device testing must validate YUV color interpretation, hand orientation, current raw-depth availability and actual end-to-end latency.

`ArCoreAirStage` adds single-use start/configure/resume/tick/close for a transferred paused ARCore session on the GL owner thread. It requests raw depth, uses explicit display geometry and texture, closes on permission loss or exception, and accepts only Beam modes. The embedding app still owns ARCore installation, GL texture/surface, foreground lifecycle, external watchdog and exclusive access. Its current output is diagnostic only; it is not wired into AirPreviewActivity. No automatic fallback to RGB or direct MIDI output. Projection rejects repeated acquisition IDs even with newly minted receipt timestamps.

`AirWireLane` serializes only existing v5/v6 logical snapshots using a caller-provided authorized mask, bounded sequence and finite levels. Swift host parser fixtures mirror the Android expected bytes. No socket or authentication is implemented; no live output before full lane ownership and neutral ACK gating are wired and independently tested.

## Debug preview application

`:preview:assembleDebug` builds a debug-signed RGB diagnostic launcher. It is not a production release, ARCore UI or live MIDI client. The user may explicitly select a trusted local hand-landmarker model with Android document picker; file contents are bounded to 16 MiB, loaded in memory, and SHA-256 displayed for manual provenance comparison. No model is bundled or automatically downloaded; hash display alone is not authenticity verification. Import never starts capture. The app has no Internet permission. CI packages the debug APK and its checkout/hash/permission evidence, not a public release.
