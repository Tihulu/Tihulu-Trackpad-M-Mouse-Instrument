# R9b — adaptive Remote browser

After legacy admission the browser sends one v7 capabilities query. All controls remain locked/hidden until a bounded exact-schema manifest is validated. No fallback to unrestricted controls. Invalid responses close the connection. Host authorization and ownership checks are unchanged.

Unmapped entire sections and individual drum pads/sensor panels are hidden. Unmapped piano keys and pedals are disabled; retaining piano geometry avoids misleading note positions. Sustain hides when absent. If only upper-octave keys are available, select that view; switching requires mapped keys in the target view and no held or pending piano notes. Input handlers also guard capabilities, rather than relying only on disabled DOM elements. Air Drums notice follows the manifest. No automatic activation or new permissions. Reset clears manifest on disconnect. Default labels still assume standard MIDI mappings; custom destination labels and host diagnostic refinement follow separately.

Five new Node VM scenarios cover admission lock, partial controls, high-octave-only mapping, invalid manifest, and partial pedals. Existing browser tests now negotiate a full synthetic manifest before exercising inputs. Real browser/TLS/DAW acceptance HOLD. Stable untouched.
