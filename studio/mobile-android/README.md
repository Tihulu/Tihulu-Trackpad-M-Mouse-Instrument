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

`AirSendGate` is a pure single-exclusive-lane client policy, not a transport. The future authenticated session must negotiate all assigned neutral families first, transfer exclusive sequence ownership, dispatch Send immediately, route only current-socket ACKs, independently poll, and close on Close/abort. Gate adds its own neutral fence, 13ms send spacing, 50ms active refresh, 150ms input/release deadline, 220ms ACK limit and idle-only heartbeat. It never queues multiple discrete attacks; unsafe pending edge changes fail closed. Continuous samples coalesce. No sender is connected to the preview APK.

## Optional ARCore depth diagnostic in preview

The preview APK now includes optional ARCore runtime and an explicit rear raw-depth selector (estimated/fused, not guaranteed ToF). It can request Play Services for AR installation only after the user chooses depth and presses Start. After the install flow the user must press Start again. A single-use offscreen EGL worker owns camera texture, session and local hand model. No raw frames are drawn. The UI polls a bounded latest derived reading, neutralizes stale readings, invalidates on stop/pause, and waits for teardown; a process-local capture lease prevents RGB/ARCore overlap. Beam notes/helper, three near/far presets and explicit raw image orientation are exposed. ARCore zoom/lens are locked for alignment. Camera2 DEPTH16 live acquisition, actual device validation, signed production packaging and MIDI transport remain open. The preview APK still has no Internet permission; Play Services is a separate system component.

## Native LAN policy (not enabled in the APK)

The experimental OkHttp adapter can negotiate the single-family host protocol,
with normal TLS verification, private numeric LAN endpoints, one-time invitation,
neutral ACK, per-session watchdog and no automatic retry. The camera Activity
is still offline and the manifest explicitly removes INTERNET. The socket's
ready assignment and paired projection factory are available only after neutral
ACK; they reject incompatible instrument families and never substitute the full
diagnostic keyboard. The ARCore diagnostic source now requires an explicit
key mask. Android Air Strings supplies per-key monotonic pulse deadlines via
projection, session and socket; the sender independently expires them and
closes when a timely release is blocked by ACK or pacing. The local preview
is unchanged. Before live pairing: bound incoming WebSocket message assembly,
provision trust for a verified local CA without weakening TLS, connect the
camera UI to the admitted lane, and validate on physical Android devices.

### Private-root provisioning policy (offline, experimental)

A new in-memory helper accepts exactly one bounded DER self-signed CA after
matching a separately authenticated SHA-256 fingerprint. It checks validity,
CA constraints and signature, builds a private trust store containing only
that root, and binds use to the chosen numeric LAN host. The socket keeps
OkHttp's standard IP hostname/SAN verification. No root is installed globally,
no secret or CA is stored, and no trust-all fallback exists. The phone UI
must obtain the expected fingerprint independently (e.g. verified on the Mac
screen), never derive it from the selected file as implicit consent. The APK
still has no network permission; bounded inbound WebSocket reassembly and
physical TLS tests remain prerequisites for pairing UI activation.

### Bounded inbound frame reader (transport candidate)

The isolated Kotlin reader rejects oversized lengths before payload allocation,
limits assembled ASCII messages to 256 bytes and at most 16 fragments,
rejects unexpected binary, masked server and extension frames, handles control
frames without growing the message buffer, and permanently retires on parse
error or close. It is deliberately not wired into OkHttp: its callbacks already
receive materialized messages. A replacement transport must bind this reader to
an exact authenticated TLS upgrade, bound HTTP headers, implement masked writes,
validate control semantics, and independently interrupt blocking reads at the
existing deadlines. No Android network permission or live MIDI is enabled.

### Bounded native transport candidate (not enabled in the preview)

The experimental alternative to OkHttp now includes direct numeric-IP TLS
(standard trust-chain and HTTPS verification, exact IP SAN, TLS 1.2/1.3),
bounded HTTP Upgrade, fixed-size masked client frames, bounded server reader,
and a one-shot socket owner. Separate reader, writer and 25 ms watchdog
workers do not hold the policy monitor across I/O. A single write lease has
an independent conservative 50 ms deadline; there is no queue of attacks.
One racing bounded response can be deferred until the exact write completes;
it cannot refresh the write deadline. Socket retirement clears queued data,
interrupts the raw connection first and prevents reconnection. All existing
session deadlines remain unchanged. JVM fixtures cover blocked setup/write,
late response, admission, ownership, and explicit stop; actual TLS/provider
behavior, scheduling and physical Mac/Android MIDI still need validation.
The existing preview deliberately has no INTERNET permission; neither the
alternative transport nor the old OkHttp adapter is activated in the camera UI.

## Separate experimental paired companion

The original `:preview:assembleDebug` APK stays network-disabled.
`:paired:assembleDebug` builds a separate debug app with ID
`com.tihulu.mobile.paired`, explicit INTERNET permission and the paired
Air opt-in manifest flag. Both default to local preview; only the latter
can display the pairing controls. The experimental debug artifact is not
a production release. No credentials or CA are bundled.

1. Choose a reviewed local hand-landmarker model before pairing.
2. On the Mac group host, assign one piano family or a supported continuous
   pedal lane. Start the authenticated private TLS listener for its numeric IP.
3. On Android select **Play through paired Mac**, choose an instrument and
   hand, enter the exact controller address and separate one-time invitation.
   Import the verified root DER certificate and independently compare its
   SHA-256 on the Mac; type the expected fingerprint. No automatic trust.
4. Connect explicitly, allow camera permission if needed (press Connect again),
   and check the host assignment after neutral ACK. Start playing. Only
   assigned derived keys/helper levels are sent, not camera or depth images.
5. Stop/release, backgrounding, permission loss, capture failure or connection
   failure retires the session. A new invitation is required to reconnect.
   ARCore installation can interrupt the session; finish setup before pairing.

Current limitations: address QR via explicit system camera thumbnail (continuous in-app scanning remains pending),
single-family assignment, explicit pause/neutral ACK/restart within the same family, no signed production
release, no physical Android/ARCore/Mac/Logic acceptance. JVM loopback TLS tests
exercise the same upgrade path but do not certify Android TLS provider behavior.

The paired screen can optionally scan the Mac address using an explicit system
camera photo. ZXing decodes the bounded thumbnail locally; only the exact
canonical private HTTPS controller address is accepted. The image is not
saved by TIHULU, no connection opens from the QR, and invitation/root trust
must still be entered separately. System camera behavior and QR quality
require physical device validation; manual address entry remains available.

## Touch piano (local native preview)

Open **Touch piano · local preview** from the idle Air stage, with no Mac
connection or camera capture. Tap **Arm piano**, then play up to ten
simultaneous direct finger contacts on 13 numbered logical key zones.
The surface shows a note mask, not audio or MIDI; the numbers are logical
zones, not guaranteed musical pitches. Two contacts in the same zone
retain that key until the last contact leaves. Move to another zone to
change the logical note. Release all, cancellation, malformed pointer
ownership, focus/background loss, view detachment or layout resize clears
the mask and requires a fresh explicit Arm. Back returns to the Air stage.

The native preview does not require camera permissions or a hand model,
does not open a socket, and never reuses a paired camera session. The
separate touch owner liveness contract is covered by pure state-machine
and sender integration fixtures: it may sustain a stationary contact only
while the current foreground view explicitly proves ownership/liveness;
a 150 ms owner gap retires the lease and the independent transport
must release/close. It is not yet connected to the live UI or Mac. Real
touch cancellation, multi-finger ergonomics, accessibility and latency
remain physical acceptance work. No new host wire family or trust bypass.
