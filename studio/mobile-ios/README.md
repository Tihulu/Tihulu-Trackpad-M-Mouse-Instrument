# TIHULU Air for iPhone and iPad

The experimental iOS 17+ companion starts in **Local preview**. Choose a hand, camera or supported rear LiDAR sensor and instrument, then start the sensor to see its logical output.

## Play through a Mac

1. In the Mac group controller panel, assign the phone or tablet one piano family or one continuous pedal family. Start the private TLS listener with the identity for its numeric LAN address. Keep optional labels off.
2. Select **Paired Mac** in the companion. Scan the address QR or type the exact HTTPS controller address shown by the Mac. Enter the separate one-time invitation. For a helper, select the pedal assigned on the Mac.
3. Tap **Connect to Mac**. Allow camera and local network access when requested. If a system prompt interrupts the connection, return to the foreground and connect explicitly with a fresh invitation.
4. Check the assigned keys or pedal shown after neutral acknowledgement. Tap **Start playing**. Pinch keys and beam notes span the assigned keys. Air Strings needs three keys and two-hand chords needs a supported triad and a left or right performing hand.
5. **Stop / release** or **Disconnect and release** closes this device’s session. For a same-family mode change, use Pause / change instrument, wait for the neutral ACK and sensor retirement, select a compatible mode and restart. Pair again to change its assigned family. The camera and depth images stay on the device.

TLS uses the device trust store. The Mac’s certificate must cover the selected private IP address as an IP subject alternative name. For a private CA, verify its public root fingerprint with the Mac owner before provisioning it with Apple Configurator or an organization’s MDM. Apple also documents how to enable SSL trust for a manually installed root. The address QR carries no certificate or invitation. [Apple certificate deployment and trust](https://support.apple.com/en-us/102390)

Open TihuluAirPreview.xcodeproj in Xcode for a locally signed run on an iPhone or iPad. CI builds and archives an unsigned development app with a SHA-256 digest and checkout provenance. Camera permissions, reading the QR in different lighting, first-use local network access, TLS with a device-provisioned root, measured LiDAR depth and gesture-to-Logic latency require physical acceptance.

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
