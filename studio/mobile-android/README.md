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
release/rearm and authenticated host lane admission. No musical engine or
network sender yet. Do not retain camera frames. Callback is worker-thread;
consumer must remain bounded and reject stale events.

DEPTH16 inventory and confidence decoder do not constitute a running depth
camera pipeline. Camera2 hardware depth must be aligned with RGB, capture
timestamp and calibration before use. ARCore Depth is estimated or fused,
not necessarily hardware ToF. Never silently substitute it for measured depth.
ARCore integration, live depth acquisition, native UI, signing and hardware
acceptance remain pending.
