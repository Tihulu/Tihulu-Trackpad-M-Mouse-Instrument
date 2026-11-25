# Physical capture recovery, first increment

Capture monitor creation is no longer conditional on successful Force Touch driver open. The controller creates it lazily on explicit capture/physical monitoring request or a read-only diagnostic, with no automatic event tap start. Retiring a monitor fences queued UI callbacks and disarms the hotkey. Panic releases pointer before audio/MIDI cleanup. A missing or disabled tap must not silently report ready. Existing permission checks and Escape semantics while captured remain unchanged.

Acceptance on real Mac: start without a usable haptic driver; arm capture and verify actual tap creation, shortcut matches, pointer suppression, second shortcut release; permission denial remains off; repeat after Panic without reconnecting motor; verify stale callbacks from retired monitor cannot rearm; test other apps, all modes, lost permissions, sleep/quit, click sustain and independent Stop. No physical PASS until these checks. Diagnostic counts now refer to monitor lifetime, not whole process. Native CI pending. This does not establish the cause of all prior timeouts or fix lid/Touch Bar/shared routing.

## Follow-up recovery
A Capture Now button separates shortcut diagnosis from pointer suppression. It requires the same explicitly armed, authorized active filtering tap. Key edges are paired by keycode even if modifiers change; unowned repeats pass through. A 500 ms health check disarms a missing or disabled tap, releases click state and never re-captures automatically. Physical macOS acceptance remains required: test direct capture, shortcut twice, release modifiers before the key, and permission revocation. Do not treat synthetic local events as proof of global capture.

## Physical click sustain recovery
Tap failure invalidates physical-click Hold/Toggle and experimental click-pressure sustain without clearing independently held touch/tap sustain. Invalid size/pressure/threshold values fail closed. This remains subject to real device acceptance; CGEvent does not reliably identify the clicked surface.
