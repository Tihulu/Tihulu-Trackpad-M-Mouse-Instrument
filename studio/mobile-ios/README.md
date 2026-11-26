# TIHULU Air for iPhone and iPad

The experimental iOS 17+ companion starts in **Local preview**. Choose a hand, camera or supported rear LiDAR sensor and instrument, then start the sensor to see its logical output.

## Play through a Mac

1. In the Mac group controller panel, assign the phone or tablet one piano family or one continuous pedal family. Start the private TLS listener with the identity for its numeric LAN address. Keep optional labels off.
2. Select **Paired Mac** in the companion. Scan the address QR or type the exact HTTPS controller address shown by the Mac. Enter the separate one-time invitation. For a helper, select the pedal assigned on the Mac.
3. Tap **Connect to Mac**. Allow camera and local network access when requested. If a system prompt interrupts the connection, return to the foreground and connect explicitly with a fresh invitation.
4. Check the assigned keys or pedal shown after neutral acknowledgement. Tap **Start playing**. Pinch keys and beam notes span the assigned keys. Air Strings needs three keys and two-hand chords needs a supported triad and a left or right performing hand.
5. **Stop / release** or **Disconnect and release** closes this device’s session. Pair again to change its role. The camera and depth images stay on the device.

TLS uses the device trust store. The Mac’s certificate must cover the selected private IP address as an IP subject alternative name. For a private CA, verify its public root fingerprint with the Mac owner before provisioning it with Apple Configurator or an organization’s MDM. Apple also documents how to enable SSL trust for a manually installed root. The address QR carries no certificate or invitation. [Apple certificate deployment and trust](https://support.apple.com/en-us/102390)

Open TihuluAirPreview.xcodeproj in Xcode for a locally signed run on an iPhone or iPad. CI builds and archives an unsigned development app with a SHA-256 digest and checkout provenance. Camera permissions, reading the QR in different lighting, first-use local network access, TLS with a device-provisioned root, measured LiDAR depth and gesture-to-Logic latency require physical acceptance.
