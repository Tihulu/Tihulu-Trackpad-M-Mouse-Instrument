# Hybrid Performance — first native/synthetic checkpoint

Select Native inputs and explicitly choose one mapped source to substitute with on-screen controls. Supported synthetic source kinds: Trackpad, Magic Mouse, Touch Bar, lid, external (generic scalar signals only). At least one other native source is required. Remote transport and synthetic camera frames are deliberately excluded from this first mode. Standalone Simulation and Native modes remain available.

All sources share the same SensorRouter and dedicated Builder MIDI ledger. The substituted native adapter is not started or fed into the router. MIDI output remains opt-in; use a separate DAW instrument/channel. The visible UI renews a 350 ms lease every 100 ms, without generating MIDI or rearming an expired session. Leaving the page releases the synthetic source; actual hardware continues. Stop/Panic releases all. No new session reservation beyond five local source kinds. Actual macOS and DAW acceptance remains pending.

Selecting a different synthetic source resets the UI MIDI toggle to off. A run-scoped UI heartbeat cannot renew a replacement run. The explicit Release all synthetic controls button does not stop native inputs. Substituted surface callbacks are ignored before consuming mailbox capacity. Tests cover shared notes, atomic timeout, clock rollback and native ownership isolation.
