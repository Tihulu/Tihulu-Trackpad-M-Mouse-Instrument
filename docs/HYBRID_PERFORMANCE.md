# Hybrid Performance — first native/synthetic checkpoint

Select Native inputs and explicitly choose one mapped source to substitute with on-screen controls. Supported synthetic source kinds: Trackpad, Magic Mouse, Touch Bar, lid, external (generic scalar signals only). At least one other native source is required. Remote transport is supported through the existing TLS panel with an explicitly selected synthetic source. Synthetic dual-hand and named-helper camera frames use the native runtime. Standalone Simulation and Native modes remain available.

All sources share the same SensorRouter and dedicated Builder MIDI ledger. The substituted native adapter is not started or fed into the router. MIDI output remains opt-in; use a separate DAW instrument/channel. The visible UI renews a 350 ms lease every 100 ms, without generating MIDI or rearming an expired session. Leaving the page releases the synthetic source; actual hardware continues. Stop/Panic releases all. No new session reservation beyond five local source kinds; up to eleven remote stream sessions remain reserved separately. An external synthetic source counts against the five local slots. A sixth local kind is rejected before starting. Actual macOS and DAW acceptance remains pending.

Selecting a different synthetic source resets the UI MIDI toggle to off. A run-scoped UI heartbeat cannot renew a replacement run. The explicit Release all synthetic controls button does not stop native inputs. Substituted surface callbacks are ignored before consuming mailbox capacity. Tests cover shared notes, atomic timeout, clock rollback and native ownership isolation.

Explicit synthetic camera substitution is supported for dual-hand chord/strum and named-hand helper modes. Native camera frames are rejected for this source and no camera permission is requested. Synthetic frames use the native gesture runtime and 250 ms frame watchdog, not the scalar UI lease. Standalone trace replay remains simulation-only. Legacy single-hand camera mappings cannot be substituted by this mode.

Camera debug streams are bound to a Builder run token. The camera panel owns its Stop/Release action; the scalar release button is hidden for camera substitution so an ongoing frame producer cannot immediately rearm it. Native source status excludes the synthetic camera.

Hybrid Remote projection and loopback diagnostic validate the explicitly selected substitution using the same full-patch admission contract. Remote metadata remains restricted to the paired phone/tablet source; synthetic and other local targets are never included.
